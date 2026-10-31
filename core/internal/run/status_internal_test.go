package run

import (
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// checkEvent is a "check" event with the result of the check name, or with
// no result when name is "", as an event from before Loam stored it.
func checkEvent(name string, passed bool) store.RunEvent {
	e := store.RunEvent{Kind: "check"}
	if name != "" {
		e.Check = &store.RunCheckResult{Name: name, Passed: passed}
	}
	return e
}

func TestLastGateIsTheLastBlockOfCheckEvents(t *testing.T) {
	events := []store.RunEvent{
		{Kind: "state"},
		checkEvent("Tests", false), checkEvent(CommittedCheck, true),
		{Kind: "try"},
		checkEvent("Tests", true), checkEvent("Lint", false), checkEvent(CommittedCheck, true),
		{Kind: "state"},
	}
	got := LastGate(events)
	if len(got) != 3 || got[0].Name != "Tests" || !got[0].Passed || got[1].Name != "Lint" || got[2].Name != CommittedCheck {
		t.Fatalf("%+v", got)
	}
	// A last gate from before Loam stored the results has none: it does not
	// reach back to the gate before it.
	events = append(events, checkEvent("", false), checkEvent("", true))
	if got := LastGate(events); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	if got := LastGate(nil); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestLastCodeReviewIsTheRoundOfTheLastReviewEvent(t *testing.T) {
	found := storedRound([]codeReviewFinding{{Severity: severityMajor, File: "a.go", Line: 2, Text: "It leaks."}})
	events := []store.RunEvent{
		{Kind: "code_review", RunEventData: store.RunEventData{CodeReview: found}},
		{Kind: "ship"},
	}
	if got := LastCodeReview(events); got != found {
		t.Fatalf("%+v", got)
	}
	// A review that did not run, after it, has no findings.
	events = append(events, store.RunEvent{Kind: "code_review"})
	if got := LastCodeReview(events); got != nil {
		t.Fatalf("%+v", got)
	}
}

func TestStoredRoundKeepsEachFindingUpToTheCap(t *testing.T) {
	findings := make([]codeReviewFinding, store.CodeReviewFindingsMax+3)
	for i := range findings {
		findings[i] = codeReviewFinding{Severity: severityMinor, Text: strings.Repeat("x", i+1)}
	}
	got := storedRound(findings)
	if len(got.Findings) != store.CodeReviewFindingsMax || got.More != 3 || got.Findings[0].Text != "x" || got.Findings[0].Severity != severityMinor {
		t.Fatalf("%d findings, %d more, first %+v", len(got.Findings), got.More, got.Findings[0])
	}
	if none := storedRound(nil); none.Findings == nil || len(none.Findings) != 0 || none.More != 0 {
		t.Fatalf("%+v", none)
	}
}
