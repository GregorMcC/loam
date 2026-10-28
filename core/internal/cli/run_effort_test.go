package cli

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Model and effort of a run: the flags, and the run defaults of the plot.

func runDefaultsOut(t *testing.T, args ...string) store.RunDefaults {
	t.Helper()
	out, code := loam(t, append([]string{"run", "defaults"}, append(args, "--json")...)...)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got struct {
		Defaults store.RunDefaults `json:"defaults"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Defaults
}

func TestRunStartPassesTheEffortToTheSession(t *testing.T) {
	runCLI(t)
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Effort", "--goal", "Do it.", "--model", "opus", "--effort", "xhigh", "--json"); err != nil {
		t.Fatal(err)
	}
	args := testutil.FakeClaudeInvocation(t).Args
	if argAfter(args, "--effort") != "xhigh" || argAfter(args, "--model") != "opus" {
		t.Fatalf("args %q", args)
	}
}

func TestRunStartWithNoEffortPassesNoFlag(t *testing.T) {
	runCLI(t)
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "No effort", "--goal", "Do it.", "--json"); err != nil {
		t.Fatal(err)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; slices.Contains(args, "--effort") || slices.Contains(args, "--model") {
		t.Fatalf("args %q", args)
	}
}

func TestRunWithABadEffortExitsWith2(t *testing.T) {
	runCLI(t)
	for _, args := range [][]string{
		{"run", "start", "alpha", "--title", "X", "--goal", "Y", "--effort", "extreme"},
		{"run", "shape", "alpha", "--title", "X", "--effort", "extreme"},
		{"recurring", "add", "alpha", "--title", "X", "--prompt", "Y", "--kind", "chore", "--days", "daily", "--at", "06:30", "--effort", "extreme"},
		{"run", "defaults", "alpha", "--effort", "extreme"},
	} {
		out, code := loam(t, args...)
		if code != 2 || !strings.Contains(out, "low, medium, high, xhigh, max") {
			t.Errorf("%v: exit %d: %s", args, code, out)
		}
	}
	if calls := testutil.FakeClaudeCalls(t); len(calls) != 0 {
		t.Fatalf("claude ran: %q", calls)
	}
}

func TestRunShapePassesTheEffortToTheDraftAndTheApprovedSession(t *testing.T) {
	shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot", "--effort", "high", "--model", "sonnet")
	if r.Shape.Effort != "high" || r.Shape.Model != "sonnet" {
		t.Fatalf("shape %+v", r.Shape)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; argAfter(args, "--effort") != "high" || argAfter(args, "--model") != "sonnet" {
		t.Fatalf("claude -p args %q", args)
	}
	shapeRun(t, "approve", r.ID)
	if args := testutil.FakeClaudeInvocation(t).Args; !slices.Contains(args, "--bg") || argAfter(args, "--effort") != "high" {
		t.Fatalf("session args %q", args)
	}
}

func TestRunDefaultsShowSetAndClear(t *testing.T) {
	s, p := runCLI(t)
	if d := runDefaultsOut(t, "alpha"); d != (store.RunDefaults{PlotID: p.ID}) {
		t.Fatalf("defaults of a new plot %+v", d)
	}
	if d := runDefaultsOut(t, "alpha", "--model", "opus", "--effort", "max"); d != (store.RunDefaults{PlotID: p.ID, Model: "opus", Effort: "max"}) {
		t.Fatalf("set %+v", d)
	}
	// A flag sets its own field and leaves the other.
	if d := runDefaultsOut(t, "alpha", "--effort", "low"); d.Model != "opus" || d.Effort != "low" {
		t.Fatalf("set one %+v", d)
	}
	if d := runDefaultsOut(t, "alpha", "--model", ""); d.Model != "" || d.Effort != "low" {
		t.Fatalf("clear %+v", d)
	}
	if d, err := s.GetRunDefaults(p.ID); err != nil || d.Effort != "low" {
		t.Fatalf("stored %+v %v", d, err)
	}
}

func TestRunStartUsesTheRunDefaultsOfThePlot(t *testing.T) {
	runCLI(t)
	runDefaultsOut(t, "alpha", "--model", "opus", "--effort", "high")
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Defaults", "--goal", "Do it.", "--json"); err != nil {
		t.Fatal(err)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; argAfter(args, "--model") != "opus" || argAfter(args, "--effort") != "high" {
		t.Fatalf("args %q", args)
	}

	// A flag wins over the default, field by field.
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Flag", "--goal", "Do it.", "--model", "haiku", "--json"); err != nil {
		t.Fatal(err)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; argAfter(args, "--model") != "haiku" || argAfter(args, "--effort") != "high" {
		t.Fatalf("args %q", args)
	}
}

func TestRunShapeUsesTheRunDefaultsOfThePlot(t *testing.T) {
	shapeCLI(t)
	runDefaultsOut(t, "alpha", "--model", "opus", "--effort", "medium")
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.Shape.Model != "opus" || r.Shape.Effort != "medium" {
		t.Fatalf("shape %+v", r.Shape)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; argAfter(args, "--model") != "opus" || argAfter(args, "--effort") != "medium" {
		t.Fatalf("claude -p args %q", args)
	}
}

func TestRecurringAddKeepsTheEffort(t *testing.T) {
	runCLI(t)
	out, code := loam(t, "recurring", "add", "alpha", "--title", "Nightly", "--prompt", "Tidy.", "--kind", "chore", "--days", "daily", "--at", "06:30", "--effort", "low", "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got struct {
		Recurring store.Recurring `json:"recurring"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil || got.Recurring.Effort != "low" {
		t.Fatalf("%v: %s", err, out)
	}
}
