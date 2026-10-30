package run

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// fakeBox returns a check box with the fake sandbox-exec of the test harness,
// which runs each check with no sandbox.
func fakeBox(t *testing.T) checkBox {
	t.Helper()
	testutil.FakeSandbox(t)
	profile := filepath.Join(t.TempDir(), "gate.sb")
	if err := os.WriteFile(profile, []byte("(version 1)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return checkBox{exec: os.Getenv("LOAM_SANDBOX_EXEC"), profile: profile}
}

// A check after the end of the gate budget fails and does not run.
func TestRunCheckDoesNotRunAfterTheBudget(t *testing.T) {
	dir := t.TempDir()
	box := fakeBox(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := runCheck(ctx, dir, box, store.Check{Name: "Touch", Command: "touch ran"})
	if res.passed || !strings.Contains(res.output, "ran out of time") {
		t.Fatalf("%+v", res)
	}
	if res = runCheck(context.Background(), dir, box, store.Check{Name: "Ls", Command: "ls ran"}); res.passed {
		t.Fatalf("the check ran after the budget: %+v", res)
	}
}

// TAS-175: with no sandbox, a check fails closed: it does not run, and its
// output says why.
func TestRunCheckDoesNotRunWithNoSandbox(t *testing.T) {
	dir := t.TempDir()
	box := checkBox{err: errors.New("/usr/bin/sandbox-exec is missing")}
	res := runCheck(context.Background(), dir, box, store.Check{Name: "Touch", Command: "touch ran"})
	if res.passed || res.exit != -1 || !strings.Contains(res.output, "could not sandbox it: /usr/bin/sandbox-exec is missing") {
		t.Fatalf("%+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "ran")); err == nil {
		t.Fatal("the check ran with no sandbox")
	}
}

// TAS-175: SwiftPM sandboxes its manifest, and that sandbox cannot start in
// the sandbox of the checks. A check that fails on it gets one line that says
// what to pass. A check that passes, or fails on something else, gets none.
func TestRunCheckNamesTheFlagForANestedSandbox(t *testing.T) {
	dir := t.TempDir()
	box := fakeBox(t)
	nested := "echo 'sandbox-exec: sandbox_apply: Operation not permitted' >&2"
	cases := []struct {
		command string
		note    bool
	}{
		{nested + "; exit 1", true},
		{nested, false},
		{"echo boom; exit 1", false},
	}
	for _, c := range cases {
		res := runCheck(context.Background(), dir, box, store.Check{Name: "Build", Command: c.command})
		if got := strings.Contains(res.output, "pass --disable-sandbox to swift build, swift test, and swift package"); got != c.note {
			t.Errorf("%q: note %v, output:\n%s", c.command, got, res.output)
		}
		if c.note && strings.Count(res.output, "\n") != 1 {
			t.Errorf("%q: want one line after the output:\n%s", c.command, res.output)
		}
	}
}
