package run

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
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
	}
	return 0
}

// sessionStarted records the session of the run, and adds a session record
// so that loam sessions and loam resume know it. After a compact it prints
// the seed again, as for a seeded session.
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
