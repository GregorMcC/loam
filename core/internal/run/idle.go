package run

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
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
// not show its session in a turn (see [sessionIdle]). stopIdle does not run
// the gate, because the Stop hook may still run it. One claude agents call
// reads all the sessions, and only when a run has been quiet for that long.
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
	states, err := sessionStates(ctx)
	if err != nil {
		return nil, append(warnings, "Loam could not read the state of the run sessions: "+err.Error())
	}
	var stopped []store.Run
	for _, found := range quiet {
		if !sessionIdle(states, found.SessionID) {
			continue
		}
		moved := false
		r, err := s.UpdateRun(found.ID, func(r *store.Run) error {
			// The Stop hook may have moved the run while Loam read the sessions.
			if r.State != store.RunRunning || !r.UpdatedAt.Equal(found.UpdatedAt) {
				return nil
			}
			r.State, r.Note, moved = store.RunStopped, IdleNote, true
			return nil
		})
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
// "blocked", and a state that Loam does not know are not idle.
func sessionIdle(states map[string]string, sessionID string) bool {
	state, listed := states[sessionID]
	return !listed || state == "done" || state == "stopped"
}

// sessionStates returns the state of each background session by session
// ID, from claude agents --json --all.
func sessionStates(ctx context.Context) (map[string]string, error) {
	claude, err := claudebin.Find()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, agentsTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, claude, "agents", "--json", "--all")
	cmd.WaitDelay = time.Second
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		return nil, errors.New(failureNote("claude agents failed", err, errOut.String()))
	}
	var sessions []struct {
		SessionID string `json:"sessionId"`
		State     string `json:"state"`
	}
	if err := json.Unmarshal(out.Bytes(), &sessions); err != nil {
		return nil, fmt.Errorf("claude agents gave a list that Loam cannot read: %w", err)
	}
	states := make(map[string]string, len(sessions))
	for _, a := range sessions {
		states[a.SessionID] = a.State
	}
	return states, nil
}
