package run

import (
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

	failed := checkResult{check: check, exit: 1, output: "FAIL\n"}
	pr := &github.PR{Number: 7, ReviewDecision: changesRequested}
	review, _ := reviewPrompt(store.Run{}, pr, reviewOf(store.Run{}, pr), testReplies)
	sendBacks := map[string]string{
		"gate":        reason(store.Run{Tries: 1, MaxTries: 3}, gateResult{results: []checkResult{failed}, failed: []checkResult{failed}}),
		"code review": codeReviewPrompt([]codeReviewFinding{{Severity: severityMajor, File: "a.go", Line: 1, Text: "Loses the file."}}, 0, 1),
		"PR review":   review,
		"notes":       notesPrompt(store.Run{}, []Note{{Text: "Say hello."}}),
	}
	for name, p := range sendBacks {
		if !strings.Contains(p, leaveChecks) {
			t.Errorf("the %s prompt does not leave the checks to Loam:\n%s", name, p)
		}
	}
}
