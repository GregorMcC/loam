package run

import (
	"context"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// A check after the end of the gate budget fails and does not run.
func TestRunCheckDoesNotRunAfterTheBudget(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := runCheck(ctx, dir, store.Check{Name: "Touch", Command: "touch ran"})
	if res.passed || !strings.Contains(res.output, "ran out of time") {
		t.Fatalf("%+v", res)
	}
	if res = runCheck(context.Background(), dir, store.Check{Name: "Ls", Command: "ls ran"}); res.passed {
		t.Fatalf("the check ran after the budget: %+v", res)
	}
}
