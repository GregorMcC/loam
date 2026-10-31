package run

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// hookInput is the part of the hook JSON that a run reads.
type hookInput struct {
	Event          string `json:"hook_event_name"`
	SessionID      string `json:"session_id"`
	Source         string `json:"source"`
	Cwd            string `json:"cwd"`
	StopHookActive bool   `json:"stop_hook_active"`
	Error          string `json:"error"`
	ErrorDetails   string `json:"error_details"`
}

// Hook answers one hook call of a run session and returns the exit code for
// Claude Code. It reads the hook JSON from in. A failed Stop gate writes the
// reason to errOut and returns 2, which blocks the stop: Claude Code sends
// the reason to the session as its next prompt. Every other path returns 0,
// so a broken store never traps a session: the hook logs the error to
// hook.log in the Loam home folder.
func Hook(s *store.Store, runID string, in io.Reader, out, errOut io.Writer) int {
	logf := hookLog(s.Home())
	raw, err := io.ReadAll(io.LimitReader(in, 1<<20))
	if err != nil {
		logf("run %s: read stdin: %v", runID, err)
		return 0
	}
	var h hookInput
	if err := json.Unmarshal(raw, &h); err != nil {
		logf("run %s: bad hook JSON: %v", runID, err)
		return 0
	}
	switch h.Event {
	case "SessionStart":
		sessionStarted(s, runID, h, out, logf)
	case "Stop":
		return stopped(s, runID, errOut, logf)
	case "StopFailure":
		stopFailed(s, runID, h, logf)
	}
	return 0
}

// stopped is the gate. Each Stop counts a turn of the run. It runs the
// checks of a running run. When they pass, the run goes to Ship when its repo
// is on GitHub, else to Ready. When Loam cannot sandbox them, they do not
// run: the run is Stopped with the reason, and no try counts. When they
// fail, and the run has used the turns that the run limits allow since Loam
// last resumed its session, the run is Stopped, and no try counts. When the
// gate ran out of time (see [gateResult.outOfTime]), no try counts: the stop
// is blocked with a short note that tells the session to end its turn with
// no change. The second check timeout in a row stops the run, but a gate
// that ran out of time because it waited for the gate lock never does. Else
// the try
// counts: the stop is blocked with the failures as the reason, or the run is
// Stopped when it has no tries left. A run that is not running lets the
// session stop: you may have typed in it after it was Ready.
func stopped(s *store.Store, runID string, errOut io.Writer, logf func(string, ...any)) int {
	r, err := s.GetRun(runID)
	if err != nil {
		logf("run %s: %v", runID, err)
		return 0
	}
	if r.State != store.RunRunning && r.State != store.RunStarting && r.State != store.RunStartUnknown {
		if _, err := s.UpdateRun(runID, func(r *store.Run) error { r.Turns++; return nil }); err != nil {
			logf("run %s: count the turn: %v", runID, err)
		}
		return 0
	}
	limits, err := s.GetRunLimits()
	if err != nil {
		logf("run %s: read the run limits: %v", runID, err)
		limits.MaxTurns = 0 // a broken store does not stop the run
	}
	ctx, cancel := context.WithTimeout(context.Background(), gateBudget)
	g := gate(ctx, s, r, logf)
	cancel()
	why, outOfTime := g.outOfTime()
	ships := !outOfTime && len(g.failed) == 0 && onGitHub(s, r)
	block := ""
	r, err = s.UpdateRun(runID, func(r *store.Run) error {
		block = ""
		r.Turns++
		if r.State != store.RunRunning && r.State != store.RunStarting && r.State != store.RunStartUnknown {
			return nil // stopped while the checks ran
		}
		if !outOfTime {
			r.GateTimeouts = 0
		}
		if !outOfTime && len(g.failed) == 0 {
			r.State, r.Note = store.RunShipping, "All "+count(len(g.results), "check")+" passed"
			if !ships {
				r.State, r.Note = store.RunReady, r.Note+". The repo has no GitHub origin, so Loam opens no PR"
			}
			return nil
		}
		if g.unsandboxed != nil {
			// The session cannot fix the sandbox, so no try counts.
			r.State, r.Note = store.RunStopped, "Loam did not run the checks, because it could not sandbox them: "+g.unsandboxed.Error()
			return nil
		}
		if turns := r.Turns - r.TurnBase; limits.MaxTurns > 0 && turns >= limits.MaxTurns {
			r.State, r.Note = store.RunStopped, "Stopped after "+count(turns, "turn")+", the limit for each run"
			return nil
		}
		if outOfTime {
			// A wait for the lock comes from the gates of other runs, and the
			// lock gives no turn order, so it never stops the run (see
			// [gateResult.waitCaused]). It leaves the count of check timeouts
			// as it is.
			waited := g.waitCaused()
			if !waited {
				r.GateTimeouts++
			}
			if !waited && r.GateTimeouts >= 2 {
				r.State, r.Note = store.RunStopped, why+", 2 gates in a row. No try counted"
				return nil
			}
			r.State, r.Note = store.RunRunning, why+". No try counted, and Loam runs the checks again"
			block = timeoutReason(why)
			return nil
		}
		r.Tries++
		if r.Tries >= r.MaxTries {
			r.State, r.Note = store.RunStopped, "Checks failed after "+count(r.Tries, "try")+": "+failedNames(g)
			return nil
		}
		r.State, r.Note = store.RunRunning, fmt.Sprintf("Try %d failed: %s", r.Tries, failedNames(g))
		block = reason(*r, g)
		return nil
	})
	if err != nil {
		logf("run %s: record the gate: %v", runID, err)
		return 0
	}
	if block == "" {
		return 0
	}
	fmt.Fprint(errOut, block)
	return 2
}

// onGitHub reports whether Loam can ship the run: it works in a worktree of
// a repo whose origin is on GitHub. A store that cannot read the worktree
// now sends the run to Ship anyway: Ship reads the worktree again, and moves
// a run whose repo is not on GitHub to Ready.
func onGitHub(s *store.Store, r store.Run) bool {
	if r.WorktreeID == "" {
		return false
	}
	w, err := s.GetWorktree(r.WorktreeID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return false
	case err != nil:
		return true
	}
	_, ok := worktree.GitHubRepo(w.Repo)
	return ok
}

// limitErrors are the StopFailure errors of a usage limit.
var limitErrors = []string{"rate_limit", "billing_error"}

// stopFailed records a turn of a running run that ended on an API error. A
// usage limit makes the run Stopped by a limit. Any other error stops it.
// Neither counts a try. As at the Stop gate, a run that is not running keeps
// its state: you may have typed in it after it was Ready.
func stopFailed(s *store.Store, runID string, h hookInput, logf func(string, ...any)) {
	note := strings.TrimSpace("Claude Code stopped: " + h.Error + " " + h.ErrorDetails)
	_, err := s.UpdateRun(runID, func(r *store.Run) error {
		if r.State != store.RunRunning && r.State != store.RunStarting && r.State != store.RunStartUnknown {
			return nil
		}
		r.State, r.Note = store.RunStopped, note
		if slices.Contains(limitErrors, h.Error) {
			r.State = store.RunLimited
		}
		return nil
	})
	if err != nil {
		logf("run %s: record the stop failure: %v", runID, err)
	}
}

// sessionStarted records the session of the run, and adds a session record
// so that loam sessions and loam resume know it. After a compact it prints
// the seed again, as for a seeded session, and the sandbox note of the run.
func sessionStarted(s *store.Store, runID string, h hookInput, out io.Writer, logf func(string, ...any)) {
	if h.SessionID == "" {
		return
	}
	r, err := s.UpdateRun(runID, func(r *store.Run) error {
		r.SessionID = h.SessionID
		if r.State == store.RunStarting || r.State == store.RunStartUnknown {
			r.State, r.Note = store.RunRunning, ""
		}
		return nil
	})
	if err != nil {
		logf("run %s: record session %s: %v", runID, h.SessionID, err)
		return
	}
	if err := s.AddSession(store.SessionRecord{SessionID: h.SessionID, PlotID: r.PlotID, StartFolder: r.Folder}); err != nil {
		logf("run %s: add session record %s: %v", runID, h.SessionID, err)
	}
	if h.Source == "compact" {
		session.PrintSeed(s.Home(), r.PlotID, out, logf)
		switch note, err := session.RunSandboxNote(s, r); {
		case err != nil:
			logf("run %s: the sandbox note: %v", runID, err)
		case note != "":
			fmt.Fprintln(out, "\n"+note)
		}
	}
}

// hookLog returns a logger that appends to hook.log in home.
func hookLog(home string) func(string, ...any) {
	return func(format string, a ...any) {
		f, err := os.OpenFile(filepath.Join(home, "hook.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return
		}
		defer f.Close()
		fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, a...))
	}
}

// count gives n and the noun, such as "1 try" or "3 tries".
func count(n int, noun string) string {
	switch {
	case n == 1:
	case strings.HasSuffix(noun, "y"):
		noun = strings.TrimSuffix(noun, "y") + "ies"
	default:
		noun += "s"
	}
	return fmt.Sprintf("%d %s", n, noun)
}
