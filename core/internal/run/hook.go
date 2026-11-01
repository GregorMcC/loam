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
	// LastMessage is the last message of the session in a Stop hook, when
	// Claude Code gives it.
	LastMessage string `json:"last_assistant_message"`
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
		exportBashEnv(s, runID, logf)
		sessionStarted(s, runID, h, out, logf)
	case "Stop":
		return stopped(s, runID, h.LastMessage, errOut, logf)
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
// the try counts: the stop is blocked with the failures as the reason, or the
// run is Stopped when it has no tries left. The gate blocks at most
// [maxBlockedStops] stops in a row, and stops the run at the next one. A run
// that is not running lets the session stop: you may have typed in it after
// it was Ready. A run that a tick stopped as idle just now gets the gate too
// (see [endsATurn]). Before the checks, the gate rebuilds the git metadata
// of the worktree when a session pruned it (see [keepGit]). When Loam does
// not rebuild it, the run is Stopped, and no check runs. When the metadata
// is not ready for another reason, such as a rebuild in another Loam process
// that did not end in time, no check runs and no try counts, as when the
// gate waits out the gate lock: the stop is blocked, and the gate runs again
// at the next stop. The hook holds the
// gate lock of the run (see [holdGate]) from the first read of the run to the
// record of the gate. A stop that the gate lets end keeps reply, the last
// message of the session, as the reply to a code review round (see
// [keepReply]).
func stopped(s *store.Store, runID, reply string, errOut io.Writer, logf func(string, ...any)) int {
	// While the gate runs, a tick does not take the run as idle.
	defer holdGate(s, runID, logf)()
	r, err := s.GetRun(runID)
	if err != nil {
		logf("run %s: %v", runID, err)
		return 0
	}
	// The hook holds the gate lock, so no tick stops the run again before the
	// record of the gate, and recent holds until then.
	recent := idleStopRecent(s, r)
	if !endsATurn(r, recent) {
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
	var g gateResult
	switch err := keepGit(ctx, s, r); {
	case gitRefused(err):
		cancel()
		logf("run %s: %v", runID, stopAfter(s, runID, err))
		return 0
	case err != nil:
		// Git may not work in the worktree yet, so a check could fail for
		// no fault of the session. The gate runs at the next stop.
		logf("run %s: check the git metadata: %v", runID, err)
		g = gateResult{noGit: err}
	default:
		g = gate(ctx, s, r, logf)
	}
	cancel()
	_, outOfTime := g.outOfTime()
	ships := !outOfTime && len(g.failed) == 0 && onGitHub(s, r)
	block := ""
	_, err = s.UpdateRun(runID, func(r *store.Run) error {
		block = gateOutcome(r, g, limits, ships, recent)
		switch {
		case block == "":
			r.BlockedStops = 0
		case r.BlockedStops+1 > maxBlockedStops:
			last := strings.TrimSuffix(r.Note, ", and Loam runs the checks again")
			block, r.BlockedStops = "", 0
			r.State, r.Note = store.RunStopped, fmt.Sprintf("Stopped after %d blocked stops in a row, the most that Claude Code allows. The last gate: %s", maxBlockedStops, last)
		default:
			r.BlockedStops++
			return nil // the session works on, so its reply comes at a later stop
		}
		keepReply(r, reply) // the session stops
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

// keepReply keeps msg, the last message of the session at a stop that ends
// its work, as the reply to the code review round that Loam waits for (see
// [store.RunCodeReview.ReplyRound]). The next review of the run shows it
// after the findings of that round (see [writeEarlier]). A stop with no
// message ends the wait too, so a later stop, such as after a CI failure, is
// not taken as the reply.
func keepReply(r *store.Run, msg string) {
	c := r.CodeReview
	if c == nil || c.ReplyRound == 0 {
		return
	}
	if msg = strings.TrimSpace(msg); msg != "" {
		if c.Replies == nil {
			c.Replies = map[int]string{}
		}
		c.Replies[c.ReplyRound] = cutText(msg, store.CodeReviewReplyMax)
	}
	c.ReplyRound = 0
}

// maxBlockedStops is the most stops in a row that the gate blocks. Claude
// Code lets a session stop after 8 blocked stops in a row (see
// [store.MaxTriesLimit]), and the run then waits in Running with no session
// at work. So the gate blocks at most 7 in a row, as for a run with 8 tries,
// and stops the run at the next one that it would block.
const maxBlockedStops = store.MaxTriesLimit - 1

// gateOutcome moves the run r on from the gate g, and returns the reason
// that blocks the stop, or "" when the session can stop. See [stopped].
// recent is whether a tick stopped the run as idle just now (see
// [endsATurn]).
func gateOutcome(r *store.Run, g gateResult, limits store.RunLimits, ships, recent bool) string {
	why, outOfTime := g.outOfTime()
	r.Turns++
	if !endsATurn(*r, recent) {
		return "" // stopped while the checks ran
	}
	if !outOfTime {
		r.GateTimeouts = 0
	}
	if !outOfTime && len(g.failed) == 0 {
		r.State, r.Note = store.RunShipping, "All "+count(len(g.results), "check")+" passed"
		if !ships {
			r.State, r.Note = store.RunReady, r.Note+". The repo has no GitHub origin, so Loam opens no PR"
		}
		return ""
	}
	if g.unsandboxed != nil {
		// The session cannot fix the sandbox, so no try counts.
		r.State, r.Note = store.RunStopped, "Loam did not run the checks, because it could not sandbox them: "+g.unsandboxed.Error()
		return ""
	}
	if turns := r.Turns - r.TurnBase; limits.MaxTurns > 0 && turns >= limits.MaxTurns {
		r.State, r.Note = store.RunStopped, "Stopped after "+count(turns, "turn")+", the limit for each run"
		return ""
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
			return ""
		}
		r.State, r.Note = store.RunRunning, why+". No try counted, and Loam runs the checks again"
		return timeoutReason(why)
	}
	r.Tries++
	if r.Tries >= r.MaxTries {
		r.State, r.Note = store.RunStopped, "Checks failed after "+count(r.Tries, "try")+": "+failedNames(g)
		return ""
	}
	r.State, r.Note = store.RunRunning, fmt.Sprintf("Try %d failed: %s", r.Tries, failedNames(g))
	return reason(*r, g)
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

// IdleGrace is how long after a tick stopped a run as idle a hook still
// takes the run as running (see [endsATurn]).
var IdleGrace = 2 * time.Minute

// endsATurn reports whether the end of a turn moves the run: it is running,
// or a tick stopped it as idle in the last [IdleGrace] (recent, see
// [idleStopRecent]). claude agents can show the session as done before the
// Stop hook starts and takes the gate lock, so a tick can stop the run in
// that window. The hook then records the turn as usual. Later, the run is
// not running: you may type in its session, and the session stops with no
// gate.
func endsATurn(r store.Run, recent bool) bool {
	switch r.State {
	case store.RunRunning, store.RunStarting, store.RunStartUnknown:
		return true
	case store.RunStopped:
		return recent && r.Note == IdleNote
	}
	return false
}

// idleStopRecent reports whether a tick stopped the run as idle less than
// [IdleGrace] ago: the run is Stopped with [IdleNote], and its last state
// event, the stop, is that recent. It reads the event, not UpdatedAt,
// because each turn of a stopped run changes UpdatedAt. A store that cannot
// read the events gives false, so the session stops with no gate.
func idleStopRecent(s *store.Store, r store.Run) bool {
	if r.State != store.RunStopped || r.Note != IdleNote {
		return false
	}
	events, err := s.RunEvents(r.ID)
	if err != nil {
		return false
	}
	for i := len(events) - 1; i >= 0; i-- {
		if e := events[i]; e.Kind == "state" {
			return e.Detail == string(store.RunStopped) && time.Since(e.At) < IdleGrace
		}
	}
	return false
}

// limitErrors are the StopFailure errors of a usage limit.
var limitErrors = []string{"rate_limit", "billing_error"}

// stopFailed records a turn of a running run that ended on an API error. A
// usage limit makes the run Stopped by a limit. Any other error stops it.
// Neither counts a try. As at the Stop gate, a run that is not running keeps
// its state: you may have typed in it after it was Ready. A run that a tick
// stopped as idle just now gets the note of the error.
func stopFailed(s *store.Store, runID string, h hookInput, logf func(string, ...any)) {
	// A tick stops a run as idle only while it holds the gate lock, so with
	// the lock, recent and the update see the same run.
	defer holdGate(s, runID, logf)()
	note := strings.TrimSpace("Claude Code stopped: " + h.Error + " " + h.ErrorDetails)
	recent := false
	if r, err := s.GetRun(runID); err == nil {
		recent = idleStopRecent(s, r)
	}
	_, err := s.UpdateRun(runID, func(r *store.Run) error {
		if !endsATurn(*r, recent) {
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

// exportBashEnv appends the Bash env of the run (see [session.RunBashEnv]) to
// CLAUDE_ENV_FILE, which Claude Code gives to SessionStart hooks only. Claude
// Code applies the file to each later Bash command of the session, on each
// source: a resume and a compact run the hook again. It writes nothing for
// a run that Loam does not know.
func exportBashEnv(s *store.Store, runID string, logf func(string, ...any)) {
	file := os.Getenv("CLAUDE_ENV_FILE")
	if file == "" {
		return
	}
	r, err := s.GetRun(runID)
	if err != nil {
		logf("run %s: the Bash env: %v", runID, err)
		return
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		logf("run %s: the Bash env: %v", runID, err)
		return
	}
	_, werr := f.WriteString(session.RunBashEnv(s, r.ID))
	if err := errors.Join(werr, f.Close()); err != nil {
		logf("run %s: the Bash env: %v", runID, err)
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
