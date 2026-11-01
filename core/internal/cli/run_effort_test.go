package cli

import (
	"encoding/json"
	"errors"
	"reflect"
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
	if d := runDefaultsOut(t, "alpha"); !reflect.DeepEqual(d, store.RunDefaults{PlotID: p.ID, MCPServers: []string{}, Review: true, Checks: []store.Check{}}) {
		t.Fatalf("defaults of a new plot %+v", d)
	}
	if d := runDefaultsOut(t, "alpha", "--model", "opus", "--effort", "max"); !reflect.DeepEqual(d, store.RunDefaults{PlotID: p.ID, Model: "opus", Effort: "max", MCPServers: []string{}, Review: true, Checks: []store.Check{}}) {
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

func TestRunDefaultsSetShowAndClearTheMCPServers(t *testing.T) {
	s, p := runCLI(t)
	if d := runDefaultsOut(t, "alpha", "--mcp", "loam, linear-server,,loam"); !slices.Equal(d.MCPServers, []string{"loam", "linear-server"}) || d.Effort != "" {
		t.Fatalf("set %+v", d)
	}
	// --model leaves the servers as they are.
	if d := runDefaultsOut(t, "alpha", "--model", "opus"); !slices.Equal(d.MCPServers, []string{"loam", "linear-server"}) {
		t.Fatalf("set model %+v", d)
	}
	if out, code := loam(t, "run", "defaults", "alpha"); code != 0 || !strings.Contains(out, "mcp servers: loam, linear-server\n") {
		t.Fatalf("text %q exit %d", out, code)
	}
	if d := runDefaultsOut(t, "alpha", "--mcp", ""); d.MCPServers == nil || len(d.MCPServers) != 0 || d.Model != "opus" {
		t.Fatalf("clear %+v", d)
	}
	if out, code := loam(t, "run", "defaults", "alpha"); code != 0 || !strings.Contains(out, "mcp servers: (none)\n") {
		t.Fatalf("text %q exit %d", out, code)
	}
	if d, err := s.GetRunDefaults(p.ID); err != nil || len(d.MCPServers) != 0 {
		t.Fatalf("stored %+v %v", d, err)
	}
}

func TestRunDefaultsTurnTheCodeReviewOffAndSetItsEffort(t *testing.T) {
	_, p := runCLI(t)
	want := store.RunDefaults{PlotID: p.ID, Effort: "low", MCPServers: []string{}, Review: false, ReviewEffort: "high", Checks: []store.Check{}}
	if d := runDefaultsOut(t, "alpha", "--effort", "low", "--review", "off", "--review-effort", "high"); !reflect.DeepEqual(d, want) {
		t.Fatalf("set %+v", d)
	}
	// Another flag keeps the review as it is.
	if d := runDefaultsOut(t, "alpha", "--effort", ""); d.Review || d.ReviewEffort != "high" {
		t.Fatalf("set the effort %+v", d)
	}
	if d := runDefaultsOut(t, "alpha", "--review", "on", "--review-effort", ""); !d.Review || d.ReviewEffort != "" {
		t.Fatalf("on %+v", d)
	}
	for _, args := range [][]string{{"--review", "yes"}, {"--review-effort", "extreme"}} {
		if _, _, err := lrRun(t, "", append([]string{"run", "defaults", "alpha"}, args...)...); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%q: %v", args, err)
		}
	}
	out, _, err := lrRun(t, "", "run", "defaults", "alpha")
	if err != nil || !strings.Contains(out, "review: on\nreview effort: (Claude Code setting)\n") {
		t.Fatalf("%v: %q", err, out)
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

// The default checks of a plot go to a run that names none, and a flag
// replaces or clears them.
func TestRunDefaultsSetAndClearTheChecks(t *testing.T) {
	s, _, _ := shipRun(t, "3")
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--check", "Tests=go test ./...", "--check", "Lint=make lint"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	out, errOut, err := lrRun(t, "", "run", "defaults", "alpha")
	if err != nil || !strings.Contains(out, "check: Tests=go test ./...\ncheck: Lint=make lint\n") {
		t.Fatalf("%v %s:\n%s", err, errOut, out)
	}
	p, err := s.ListPlots()
	if err != nil || len(p) == 0 {
		t.Fatalf("%v %+v", err, p)
	}
	d, err := s.GetRunDefaults(p[0].ID)
	if err != nil || len(d.Checks) != 2 || d.Checks[1] != (store.Check{Name: "Lint", Command: "make lint"}) {
		t.Fatalf("%v %+v", err, d)
	}
	// Another flag keeps them.
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--review", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	if d, err = s.GetRunDefaults(p[0].ID); err != nil || len(d.Checks) != 2 {
		t.Fatalf("%v %+v", err, d)
	}
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--no-checks"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	if d, err = s.GetRunDefaults(p[0].ID); err != nil || len(d.Checks) != 0 {
		t.Fatalf("%v %+v", err, d)
	}
	if _, _, err := lrRun(t, "", "run", "defaults", "alpha", "--check", "no equals sign"); err == nil {
		t.Fatal("a bad check was accepted")
	}
}
