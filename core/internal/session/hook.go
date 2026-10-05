package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

type hookInput struct {
	Event            string `json:"hook_event_name"`
	SessionID        string `json:"session_id"`
	Source           string `json:"source"`
	NotificationType string `json:"notification_type"`
	Cwd              string `json:"cwd"`
}

// RunHook handles one hook call. It reads the hook JSON from in and may print
// JSON to out. It never fails and never blocks: it logs each error to hook.log
// in the Loam home folder and returns.
//
// When LOAM_PANE_SOCKET names a socket, it first sends each event of the
// event table to it. Then, on every SessionStart, it records the session ID
// for CLAUDE_PID. On source "clear" or "resume" it adds a session record for
// a new ID of a seeded session. On source "compact" it prints the seed as
// additional context.
func RunHook(in io.Reader, out io.Writer, getenv func(string) string) {
	home, err := store.Home()
	if err != nil {
		return
	}
	logf := func(format string, a ...any) {
		if err := os.MkdirAll(home, 0o700); err != nil {
			return
		}
		f, err := os.OpenFile(filepath.Join(home, "hook.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return
		}
		defer f.Close()
		fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, a...))
	}
	defer func() {
		if r := recover(); r != nil {
			logf("hook panic: %v", r)
		}
	}()

	raw, err := io.ReadAll(io.LimitReader(in, 1<<20))
	if err != nil {
		logf("read stdin: %v", err)
		return
	}
	var h hookInput
	if err := json.Unmarshal(raw, &h); err != nil {
		logf("bad hook JSON: %v", err)
		return
	}

	sendPane(h, getenv, logf)

	// A call without an event name counts as SessionStart.
	if h.Event != "" && h.Event != "SessionStart" {
		return
	}
	if h.SessionID != "" {
		recordSession(home, getenv("CLAUDE_PID"), getenv("LOAM_PLOT"), h, logf)
	}
	if h.Source == "compact" {
		printSeed(home, getenv("LOAM_PLOT"), out, logf)
	}
}

// recordSession stores the session ID for the claude process. On source
// "clear" or "resume" it also adds a session record for a new ID when the
// earlier session of the process was seeded. The earlier session is the one
// that the PID record held before this call. It does not create a store: a
// missing store means Loam has not run here.
func recordSession(home, pidText, plotID string, h hookInput, logf func(string, ...any)) {
	if pidText == "" {
		return
	}
	pid, err := strconv.Atoi(pidText)
	if err != nil || pid <= 0 {
		logf("bad CLAUDE_PID %q", pidText)
		return
	}
	if _, err := os.Stat(filepath.Join(home, "loam.db")); err != nil {
		logf("no store to record the session: %v", err)
		return
	}
	s, err := store.Open(home)
	if err != nil {
		logf("open store: %v", err)
		return
	}
	defer s.Close()
	if h.Source == "clear" || h.Source == "resume" {
		addSessionRecord(s, pid, plotID, h, logf)
	}
	if err := s.SetPIDSession(pid, h.SessionID); err != nil {
		logf("record session for pid %d: %v", pid, err)
	}
}

// addSessionRecord adds a record for the new session ID of a seeded process.
// The plot comes from LOAM_PLOT, or from the earlier record when the variable
// is empty.
func addSessionRecord(s *store.Store, pid int, plotID string, h hookInput, logf func(string, ...any)) {
	known, err := s.IsSeeded(h.SessionID)
	if err != nil {
		logf("look up session %s: %v", h.SessionID, err)
		return
	}
	if known {
		return
	}
	earlier, ok, err := s.SessionForPID(pid)
	if err != nil || !ok {
		if err != nil {
			logf("look up pid %d: %v", pid, err)
		}
		return
	}
	prev, err := s.GetSession(earlier)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			logf("look up session %s: %v", earlier, err)
		}
		return
	}
	if plotID == "" {
		plotID = prev.PlotID
	}
	folder := h.Cwd
	if folder == "" {
		folder = prev.StartFolder
	}
	if err := s.AddSession(store.SessionRecord{SessionID: h.SessionID, PlotID: plotID, StartFolder: folder}); err != nil {
		logf("add session record %s: %v", h.SessionID, err)
	}
}

// printSeed prints the seed of the plot as SessionStart additional context.
func printSeed(home, plotID string, out io.Writer, logf func(string, ...any)) {
	if plotID == "" {
		return
	}
	if plotID != filepath.Base(plotID) || plotID == "." || plotID == ".." {
		logf("bad LOAM_PLOT %q", plotID)
		return
	}
	b, err := os.ReadFile(filepath.Join(home, "plots", plotID, "CLAUDE.md"))
	if err != nil {
		logf("read seed: %v", err)
		return
	}
	msg := map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName":     "SessionStart",
		"additionalContext": string(b),
	}}
	if err := json.NewEncoder(out).Encode(msg); err != nil {
		logf("write output: %v", err)
	}
}
