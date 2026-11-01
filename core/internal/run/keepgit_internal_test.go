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
