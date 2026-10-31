package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-204: run status shows why the last gate failed and what the last code
// review found, and the JSON holds all that Loam stored.

// runStatusOut is the JSON of run status.
type runStatusOut struct {
	Run          store.Run                 `json:"run"`
	Events       []store.RunEvent          `json:"events"`
	FailedChecks []store.RunCheckResult    `json:"failed_checks"`
	CodeReview   *store.RunCodeReviewRound `json:"code_review"`
}

// runStatus returns the text and the JSON of run status.
func runStatus(t *testing.T, id string) (string, runStatusOut) {
	t.Helper()
	text, code := loam(t, "run", "status", id)
	if code != 0 {
		t.Fatalf("run status: exit %d: %s", code, text)
	}
	raw, code := loam(t, "run", "status", id, "--json")
	if code != 0 {
		t.Fatalf("run status --json: exit %d: %s", code, raw)
	}
	var got runStatusOut
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
	if !strings.Contains(raw, `"failed_checks": [`) || !strings.Contains(raw, `"code_review": `) {
		t.Fatalf("the JSON misses a field: %s", raw)
	}
	return text, got
}

func TestRunStatusShowsTheOutputOfTheFailedChecksOfTheLastGate(t *testing.T) {
	_, _ = runCLI(t)
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--max-tries", "3",
		"--check", "Loud=seq 1 30; grep -qx 'hi there' hello.txt", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var started runStartOut
	if err := json.Unmarshal([]byte(out), &started); err != nil {
		t.Fatal(err)
	}
	r := started.Run
	if code, _ := stopHook(t, r, "Stop"); code != 2 {
		t.Fatalf("the gate passed a failed check: %d", code)
	}

	text, got := runStatus(t, r.ID)
	history := strings.Index(text, "  check Loud failed (exit 2, ")
	failed := strings.Index(text, "Failed checks of the last gate:\n  Loud (exit 2)\n    (11 earlier lines cut)\n    12\n")
	if history < 0 || failed < history {
		t.Fatalf("the status shows no failed check under the history:\n%s", text)
	}
	if !strings.Contains(text, "    30\n    grep: hello.txt: No such file or directory\n") || strings.Contains(text, "    11\n") {
		t.Fatalf("the status does not show the last 20 lines of the output:\n%s", text)
	}
	if strings.Contains(text, "Work committed (exit") || strings.Contains(text, "Findings of the last code review") {
		t.Fatalf("the status shows more than the failed check:\n%s", text)
	}

	if len(got.FailedChecks) != 1 {
		t.Fatalf("failed checks %+v", got.FailedChecks)
	}
	c := got.FailedChecks[0]
	var want strings.Builder
	for i := 1; i <= 30; i++ {
		fmt.Fprintf(&want, "%d\n", i)
	}
	if c.Name != "Loud" || c.Command != "seq 1 30; grep -qx 'hi there' hello.txt" || c.Passed || c.Exit != 2 || c.OutputCut ||
		!strings.HasPrefix(c.Output, want.String()) || !strings.Contains(c.Output, "hello.txt") {
		t.Fatalf("failed check %+v", c)
	}
	if got.CodeReview != nil {
		t.Fatalf("a run with no review has %+v", got.CodeReview)
	}
	var checks []store.RunCheckResult
	for _, e := range got.Events {
		if e.Kind == "check" && e.Check != nil {
			checks = append(checks, *e.Check)
		}
	}
	if len(checks) != 2 || checks[0].Name != "Loud" || checks[1].Name != "Work committed" || !checks[1].Passed || checks[1].Output != "" {
		t.Fatalf("check events %+v", checks)
	}

	// The next gate passes, so the status shows no failed check.
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("passing gate: code %d, reason:\n%s", code, reason)
	}
	text, got = runStatus(t, r.ID)
	if strings.Contains(text, "Failed checks") || len(got.FailedChecks) != 0 {
		t.Fatalf("a passed gate shows failed checks: %+v\n%s", got.FailedChecks, text)
	}
}

func TestRunStatusShowsTheFindingsOfTheLastCodeReview(t *testing.T) {
	_, r, _ := codeReviewRun(t, majorFinding)
	tick(t)

	text, got := runStatus(t, r.ID)
	history := strings.Index(text, "code_review The code review found 1 major issue and 1 minor issue (round 1 of 5)")
	findings := strings.Index(text, "Findings of the last code review:\n"+
		"  Major: hello.txt:1: The greeting has no capital letter.\n"+
		"  Minor: hello.txt:1: The greeting has no full stop.\n")
	if history < 0 || findings < history {
		t.Fatalf("the status shows no findings under the history:\n%s", text)
	}
	want := []store.RunFinding{
		{Severity: "major", File: "hello.txt", Line: 1, Text: "The greeting has no capital letter."},
		{Severity: "minor", File: "hello.txt", Line: 1, Text: "The greeting has no full stop."},
	}
	if got.CodeReview == nil || got.CodeReview.More != 0 || fmt.Sprint(got.CodeReview.Findings) != fmt.Sprint(want) {
		t.Fatalf("code review %+v", got.CodeReview)
	}
	var stored *store.RunCodeReviewRound
	for _, e := range got.Events {
		if e.Kind == "code_review" {
			stored = e.CodeReview
		}
	}
	if stored == nil || fmt.Sprint(stored.Findings) != fmt.Sprint(want) {
		t.Fatalf("the code_review event holds %+v", stored)
	}

	// The review of the fix finds no issues: the last round has an empty
	// list, and the status shows no findings.
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(`[]`))
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatal("the gate did not pass the fix")
	}
	tick(t)
	text, got = runStatus(t, r.ID)
	if strings.Contains(text, "Findings of the last code review") || got.CodeReview == nil ||
		got.CodeReview.Findings == nil || len(got.CodeReview.Findings) != 0 {
		t.Fatalf("a review with no issues: %+v\n%s", got.CodeReview, text)
	}
}

func TestRunStatusHasNoFindingsWhenTheCodeReviewIsOff(t *testing.T) {
	_, r, _ := codeReviewRun(t, minorFinding)
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--review", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	tick(t)
	text, got := runStatus(t, r.ID)
	if !strings.Contains(text, "The code review is off for the plot") || strings.Contains(text, "Findings of the last code review") ||
		got.CodeReview != nil {
		t.Fatalf("a review that is off: %+v\n%s", got.CodeReview, text)
	}
}
