package run

import (
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-217: when Loam cannot make the git metadata of the worktree ready,
// such as when a rebuild in another Loam process holds the lock too long,
// the gate runs no check. It blocks the stop with no try, as a gate that
// waits out the gate lock does, and it never stops the run for it.
func TestAGateWithNoGitCountsNoTryAndRunsAgain(t *testing.T) {
	g := gateResult{noGit: errors.New("another Loam process rebuilds the git metadata of a worktree, and it did not end in time")}
	for i := range 3 {
		r := store.Run{State: store.RunRunning, Tries: 1, MaxTries: 3}
		r.GateTimeouts = i
		block := gateOutcome(&r, g, store.RunLimits{}, true, false)
		if r.State != store.RunRunning || r.Tries != 1 || r.GateTimeouts != i ||
			!strings.Contains(block, "no try counts") || !strings.Contains(block, "did not end in time") {
			t.Fatalf("after %d timeouts: %+v, block %q", i, r, block)
		}
	}
}

// stopAfter stops a run that has not ended. A run that you cancelled while
// Loam waited, such as for the rebuild lock, stays Cancelled.
func TestStopAfterKeepsARunThatEnded(t *testing.T) {
	s, r := runWithTemp(t, store.RunRunning)
	_ = stopAfter(s, r.ID, errors.New("the branch is gone"))
	if got, _ := s.GetRun(r.ID); got.State != store.RunStopped || got.Note != "the branch is gone" {
		t.Fatalf("running run: %+v", got)
	}
	s, r = runWithTemp(t, store.RunCancelled)
	_ = stopAfter(s, r.ID, errors.New("the branch is gone"))
	if got, _ := s.GetRun(r.ID); got.State != store.RunCancelled || got.Note == "the branch is gone" {
		t.Fatalf("cancelled run: %+v", got)
	}
}
