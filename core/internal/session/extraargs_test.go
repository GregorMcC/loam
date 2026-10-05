package session_test

import (
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestStartExtraArgsFromEnv(t *testing.T) {
	e := setup(t)
	t.Setenv("LOAM_CLAUDE_EXTRA_ARGS", `["-p","--model","haiku"]`)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if out, err := e.run(t, "start", p.ID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	n := len(inv.Args)
	if n < 3 || !slices.Equal(inv.Args[n-3:], []string{"-p", "--model", "haiku"}) {
		t.Errorf("args %v do not end with the extra args", inv.Args)
	}
}

func TestStartExtraArgsBad(t *testing.T) {
	e := setup(t)
	t.Setenv("LOAM_CLAUDE_EXTRA_ARGS", `not json`)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if out, err := e.run(t, "start", p.ID); err == nil {
		t.Errorf("start succeeded: %s", out)
	}
}
