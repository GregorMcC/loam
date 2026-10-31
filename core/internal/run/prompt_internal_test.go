package run

import (
	"context"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-205: a full check can take minutes, and the gate runs it anyway. So
// the first prompt of a run with checks, and each prompt that sends work
// back, tell the session to run only fast tests and to leave the checks to
// Loam.
func TestThePromptsLeaveTheChecksToTheGate(t *testing.T) {
	check := store.Check{Name: "Checks", Command: "scripts/check.sh"}
	first := Prompt(store.Run{Goal: "Say hi.", DoneWhen: []store.Check{check}, MaxTries: 3}, nil)
	for _, want := range []string{
		"run only the fast tests of the code that you change, such as the tests of one package.",
		"Do not run the checks above yourself: Loam runs them when you end a turn.",
	} {
		if !strings.Contains(first, want) {
			t.Errorf("the first prompt misses %q:\n%s", want, first)
		}
	}
	if none := Prompt(store.Run{Goal: "Say hi."}, nil); strings.Contains(none, "fast tests") {
		t.Errorf("the first prompt of a run with no checks names the fast tests:\n%s", none)
	}

	// Each gate has the committed check, so a gate with only that check is
	// the gate of a run with no checks.
	committedOnly := checkResult{check: store.Check{Name: CommittedCheck}, exit: 1}
	failed := checkResult{check: check, exit: 1, output: "FAIL\n"}
	gates := map[bool]gateResult{
		true:  {results: []checkResult{failed, committedOnly}, failed: []checkResult{failed, committedOnly}},
		false: {results: []checkResult{committedOnly}, failed: []checkResult{committedOnly}},
	}
	pr := &github.PR{Number: 7, ReviewDecision: changesRequested}
	for _, checks := range []bool{true, false} {
		review, _ := reviewPromptFor("Changes are requested on #7.", pr, reviewOf(store.Run{}, pr), testReplies, checks)
		ci := ciPrompt(context.Background(), nil, github.Repo{}, store.Run{MaxTries: 3},
			&github.PR{Number: 7, FailedChecks: []github.Check{{Name: "core"}}}, checks)
		sendBacks := map[string]string{
			"gate":        reason(store.Run{Tries: 1, MaxTries: 3}, gates[checks]),
			"code review": codeReviewPrompt([]codeReviewFinding{{Severity: severityMajor, File: "a.go", Line: 1, Text: "Loses the file."}}, 0, 1, checks),
			"PR review":   review,
			"notes":       notesPrompt(store.Run{}, []Note{{Text: "Say hello."}}, checks),
			// The gate does not run the checks of CI, so the session can
			// run the tests that failed there.
			"CI": ci,
		}
		for name, p := range sendBacks {
			want := leaveChecks
			if name == "CI" {
				want = ciChecks
			}
			switch {
			case checks && !strings.Contains(p, want):
				t.Errorf("the %s prompt does not leave the checks to Loam:\n%s", name, p)
			case !checks && strings.Contains(p, leaveToGate):
				t.Errorf("the %s prompt of a run with no checks leaves the checks to Loam:\n%s", name, p)
			}
		}
		if strings.Contains(ci, "fast tests") {
			t.Errorf("the CI prompt does not let the session run the failed tests:\n%s", ci)
		}
	}
}

// A run has checks when it has a Done when check or its plot has a rule.
func TestHasChecksCountsTheRulesOfThePlot(t *testing.T) {
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	res, err := s.CreatePlot(store.PlotInput{Name: "Runs"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	r := store.Run{PlotID: res.Plot.ID}
	if hasChecks(s, r) {
		t.Fatal("a run with no checks and no rules has checks")
	}
	if !hasChecks(s, store.Run{PlotID: r.PlotID, DoneWhen: []store.Check{{Name: "Hello", Command: "true"}}}) {
		t.Fatal("a run with a Done when check has no checks")
	}
	if _, err := s.AddRule(store.Rule{PlotID: r.PlotID, Name: "No TODO", Command: "! grep -rq TODO ."}); err != nil {
		t.Fatal(err)
	}
	if !hasChecks(s, r) {
		t.Fatal("a run whose plot has a rule has no checks")
	}
}
