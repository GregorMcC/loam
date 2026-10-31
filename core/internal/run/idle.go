package run

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/store"
)

// IdleWait is how long a Running run can have no change and no event, while
// its session is not in a turn, before a tick stops it (see [stopIdle]).
var IdleWait = 10 * time.Minute

// agentsTimeout limits one claude agents call.
const agentsTimeout = 30 * time.Second

// IdleNote is the note of a run that a tick stopped because its session
// ended a turn that Loam has no record of.
const IdleNote = "The session ended a turn, but Loam has no record of its checks. " +
	"Run loam run send-back to start it again"

// stopIdle stops each Running run whose session ended a turn that Loam has
// no record of, and returns the runs that it stopped. That happens when the
// Stop hook cannot record the end of the turn: the store fails, or the hook
// crashes or times out. Then nothing else moves the run. A run is idle when
// it has had no change and no event for [IdleWait], and claude agents does
// not show its session in a turn (see [sessionIdle]). A run whose Stop hook
// runs the gate is not idle (see [stopIfNoGate]). stopIdle does not run the
// gate itself. One claude agents call reads all the sessions, and only when
// a run has been quiet for that long.
func stopIdle(ctx context.Context, s *store.Store, runs []store.Run) ([]store.Run, []string) {
	var quiet []store.Run
	var warnings []string
	for _, r := range runs {
		if r.State != store.RunRunning || r.SessionID == "" {
			continue // a run with no session ID has no session that Loam can find
		}
		last, err := lastChange(s, r)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", r.Title, err))
			continue
		}
		if time.Since(last) >= IdleWait {
			quiet = append(quiet, r)
		}
	}
	if len(quiet) == 0 {
		return nil, warnings
	}
	states, unnamed, err := sessionStates(ctx)
	if err != nil {
		return nil, append(warnings, "Loam could not read the state of the run sessions: "+err.Error())
	}
	var stopped []store.Run
	for _, found := range quiet {
		if !sessionIdle(states, unnamed, found.SessionID) {
			continue
		}
		r, moved, err := stopIfNoGate(s, found)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", found.Title, err))
			continue
		}
		if moved {
			stopped = append(stopped, r)
		}
	}
	return stopped, warnings
}

// stopIfNoGate stops the run when no Stop hook runs its gate. The hook holds
// the gate lock of the run while it runs the gate (see [holdGate]), and a
// check can take up to [checkTimeout] with no event. The tick holds the lock
// while it stops the run, so a gate that starts then finds the run Stopped,
// and does not run.
func stopIfNoGate(s *store.Store, found store.Run) (store.Run, bool, error) {
	unlock, free, err := lockGate(s, found.ID, false)
	if err != nil || !free {
		return found, false, err
	}
	defer unlock()
	moved := false
	r, err := s.UpdateRun(found.ID, func(r *store.Run) error {
		// A Stop hook may have moved the run while Loam read the sessions.
		if r.State != store.RunRunning || !r.UpdatedAt.Equal(found.UpdatedAt) {
			return nil
		}
		r.State, r.Note, moved = store.RunStopped, IdleNote, true
		return nil
	})
	return r, moved, err
}

// holdGate takes the gate lock of the run for the Stop hook, and waits while
// a tick holds it. A lock that Loam cannot take, such as on a full disk, does
// not stop the gate: the hook then logs it and runs the gate with no lock.
func holdGate(s *store.Store, runID string, logf func(string, ...any)) (unlock func()) {
	unlock, _, err := lockGate(s, runID, true)
	if err != nil {
		logf("run %s: take the gate lock: %v", runID, err)
		return func() {}
	}
	return unlock
}

// lockGate takes the gate lock of the run, <home>/gates/<run-id>.lock. With
// wait, it waits for the lock. Else it returns false when another process
// holds it. The lock ends with the process, so a hook that crashes or that
// Claude Code kills does not keep it.
func lockGate(s *store.Store, runID string, wait bool) (unlock func(), ok bool, err error) {
	dir := filepath.Join(s.Home(), "gates")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, false, err
	}
	path := filepath.Join(dir, runID+".lock")
	if !wait {
		return lockFile(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, false, err
	}
	return func() { f.Close() }, true, nil
}

// lastChange is the time of the last change of the run, or of its last
// event when that is later.
func lastChange(s *store.Store, r store.Run) (time.Time, error) {
	events, err := s.RunEvents(r.ID)
	if err != nil {
		return time.Time{}, err
	}
	last := r.UpdatedAt
	if n := len(events); n > 0 && events[n-1].At.After(last) {
		last = events[n-1].At
	}
	return last, nil
}

// sessionIdle reports whether the session is not in a turn: its state is
// "done" or "stopped", or claude agents does not list it. "working",
// "blocked", and a state that Loam does not know are not idle. With unnamed,
// the list has a session with no sessionId, which can be this one, so a
// session that the list does not name is not idle.
func sessionIdle(states map[string]string, unnamed bool, sessionID string) bool {
	state, listed := states[sessionID]
	if !listed {
		return !unnamed
	}
	return state == "done" || state == "stopped"
}

// sessionStates returns the state of each background session by session
// ID, from claude agents --json --all. claude gives a sessionId only when
// the session has one, so unnamed reports a session with none.
func sessionStates(ctx context.Context) (states map[string]string, unnamed bool, err error) {
	claude, err := claudebin.Find()
	if err != nil {
		return nil, false, err
	}
	ctx, cancel := context.WithTimeout(ctx, agentsTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, claude, "agents", "--json", "--all")
	cmd.WaitDelay = time.Second
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		return nil, false, errors.New(failureNote("claude agents failed", err, errOut.String()))
	}
	var sessions []struct {
		SessionID string `json:"sessionId"`
		State     string `json:"state"`
	}
	if err := json.Unmarshal(out.Bytes(), &sessions); err != nil {
		return nil, false, fmt.Errorf("claude agents gave a list that Loam cannot read: %w", err)
	}
	// A session that the list does not have is idle, so a list that Loam
	// misreads must not look like a list with no sessions.
	if sessions == nil {
		return nil, false, errors.New("claude agents gave no list")
	}
	states = make(map[string]string, len(sessions))
	for _, a := range sessions {
		if a.SessionID == "" {
			unnamed = true
			continue
		}
		states[a.SessionID] = a.State
	}
	return states, unnamed, nil
}
