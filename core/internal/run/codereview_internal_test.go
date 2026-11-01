package run

import (
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestCleanFindingsSortsBySeverityAndPlacesAnUnknownOneAsMajor(t *testing.T) {
	got := cleanFindings([]codeReviewFinding{
		{Severity: "minor", File: "./a.go", Line: 3, Text: " A typo. "},
		{Severity: "major", File: "b.go", Text: "   "},
		{Severity: "minor", File: "d.go", Text: ""},
		{Severity: "Severe", File: "c.go", Line: 9, Text: "Loses the file."},
		{Severity: " CRITICAL", Text: "Leaks the token."},
	})
	want := []codeReviewFinding{
		{Severity: severityCritical, Text: "Leaks the token."},
		{Severity: severityMajor, File: "b.go", Text: "The review gave this issue no text."},
		{Severity: severityMajor, File: "c.go", Line: 9, Text: "Loses the file."},
		{Severity: severityMinor, File: "a.go", Line: 3, Text: "A typo."},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("got %+v", got)
	}
	if s := got[3].String(); s != "a.go:3: A typo." {
		t.Fatalf("string %q", s)
	}
}

func TestCountFindingsCountsEachSeverity(t *testing.T) {
	for _, c := range []struct {
		findings []codeReviewFinding
		want     string
	}{
		{nil, "no issues"},
		{[]codeReviewFinding{{Severity: severityMinor}}, "1 minor issue"},
		{[]codeReviewFinding{{Severity: severityCritical}, {Severity: severityMinor}, {Severity: severityMinor}},
			"1 critical issue and 2 minor issues"},
		{[]codeReviewFinding{{Severity: severityCritical}, {Severity: severityMajor}, {Severity: severityMinor}},
			"1 critical issue, 1 major issue and 1 minor issue"},
	} {
		if got := countFindings(c.findings); got != c.want {
			t.Errorf("%+v: got %q, want %q", c.findings, got, c.want)
		}
	}
}

func TestReviewFactsNameTheFirstFindingsAndCountTheRest(t *testing.T) {
	var findings []codeReviewFinding
	for i := range codeReviewFactsMax + 3 {
		findings = append(findings, codeReviewFinding{Severity: severityMinor, File: "a.go", Line: i + 1, Text: "A typo."})
	}
	facts := codeReviewFacts(findings)
	if len(facts) != codeReviewFactsMax+1 || facts[0] != "Minor issue from the code review: a.go:1: A typo." ||
		facts[codeReviewFactsMax] != "The code review found 3 more minor issues." {
		t.Fatalf("facts %q", facts)
	}
	if facts := codeReviewFacts(findings[:codeReviewFactsMax+1]); facts[codeReviewFactsMax] != "The code review found 1 more minor issue." {
		t.Fatalf("one more: %q", facts)
	}
	if facts := codeReviewFacts(nil); facts == nil || len(facts) != 0 {
		t.Fatalf("no findings: %q", facts)
	}
}

func TestCleanFindingsCutsALongText(t *testing.T) {
	got := cleanFindings([]codeReviewFinding{{Severity: severityMajor, Text: strings.Repeat("é", codeReviewTextMax+5)}})
	if n := utf8.RuneCountInString(got[0].Text); n != codeReviewTextMax+len(" (cut)") || !strings.HasSuffix(got[0].Text, " (cut)") {
		t.Fatalf("got %d runes: %q", n, got[0].Text[len(got[0].Text)-20:])
	}
}

func TestCodeReviewPromptAndNoteCountTheFindingsAfterTheCap(t *testing.T) {
	f := []codeReviewFinding{{Severity: severityMajor, File: "a.go", Line: 1, Text: "Loses the file."}}
	if p := codeReviewPrompt(f, 3, 2, true); !strings.Contains(p, "The review found 3 more Critical or Major issues.") {
		t.Fatalf("prompt %q", p)
	}
	if p := codeReviewPrompt(f, 0, 2, true); strings.Contains(p, "more Critical") {
		t.Fatalf("prompt with no more %q", p)
	}
}

// reviewedRun is a run in Shipping that has used rounds of the code review,
// with ship notes that hold one reason of Claude and the facts of the last
// review, and a shipper of it.
func reviewedRun(t *testing.T, rounds int) (*store.Store, *shipper) {
	t.Helper()
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	res, err := s.CreatePlot(store.PlotInput{Name: "Review"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.AddRun(store.Run{PlotID: res.Plot.ID, Folder: t.TempDir(), Title: "Say hi", State: store.RunShipping})
	if err != nil {
		t.Fatal(err)
	}
	old := "Minor issue from the code review: a.go:1: A typo."
	r, err = s.UpdateRun(r.ID, func(r *store.Run) error {
		r.CodeReview = &store.RunCodeReview{Head: "old", Rounds: rounds, Facts: []string{old}}
		r.Notes = &store.RunNotes{Risk: store.NoteRisk{Level: store.RiskLow, Reasons: []string{"A small change.", old}}}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return s, &shipper{s: s, r: r}
}

// lastEvent is the detail of the last event of kind of the run, or "".
func lastEvent(t *testing.T, s *store.Store, id, kind string) string {
	t.Helper()
	events, err := s.RunEvents(id)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range slices.Backward(events) {
		if e.Kind == kind {
			return e.Detail
		}
	}
	return ""
}

// TAS-219: the code review rounds count for the whole run. A review that lets
// Loam push keeps the count, so a PR review that sends the run back does not
// start the station at round 1 again.
func TestAReviewThatLetsLoamPushKeepsTheRoundsOfTheRun(t *testing.T) {
	s, sh := reviewedRun(t, 3)
	push, _, err := sh.passCodeReview("new", nil, "The code review found no issues", storedRound(nil))
	if err != nil || !push {
		t.Fatalf("push %v, err %v", push, err)
	}
	got, err := s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.CodeReview == nil || got.CodeReview.Rounds != 3 || got.CodeReview.Head != "new" {
		t.Fatalf("review %+v, want 3 rounds at head new", got.CodeReview)
	}
	if line := CodeReviewRounds(got); line != "Code review: 3 of 5 rounds" {
		t.Fatalf("status line %q", line)
	}
}

// After the last round, the review of a new head still runs, and its
// Critical and Major findings go in the ship notes, not to the session.
func TestAReviewAfterTheLastRoundPutsTheFindingsInTheShipNotes(t *testing.T) {
	s, sh := reviewedRun(t, codeReviewRounds)
	findings := []codeReviewFinding{
		{Severity: severityCritical, File: "a.go", Line: 4, Text: "Leaks the token."},
		{Severity: severityMajor, File: "b.go", Text: "Loses the file."},
		{Severity: severityMinor, File: "c.go", Line: 2, Text: "A typo."},
	}
	push, moved, err := sh.pushPastCodeReview("new", findings, codeReviewCutFact)
	if err != nil || !push || moved {
		t.Fatalf("push %v, moved %v, err %v", push, moved, err)
	}
	got, err := s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"A small change.",
		codeReviewCutFact,
		"The code review used all 5 rounds of the run, so these findings wait for you:",
		"Critical issue from the code review: a.go:4: Leaks the token.",
		"Major issue from the code review: b.go: Loses the file.",
		"Minor issue from the code review: c.go:2: A typo.",
	}
	if got.Notes == nil || !slices.Equal(got.Notes.Risk.Reasons, want) {
		t.Fatalf("reasons %q", got.Notes.Risk.Reasons)
	}
	if got.State != store.RunShipping || got.CodeReview.Rounds != codeReviewRounds || got.CodeReview.Head != "new" {
		t.Fatalf("run %s, review %+v", got.State, got.CodeReview)
	}
	if line := CodeReviewRounds(got); line != "Code review: 5 of 5 rounds" {
		t.Fatalf("status line %q", line)
	}
	if e := lastEvent(t, s, sh.r.ID, "code_review"); e != "The code review found 1 critical issue, 1 major issue and 1 minor issue "+
		"after all 5 rounds of the run, so Loam pushes with them in the ship notes. "+codeReviewCutFact {
		t.Fatalf("event %q", e)
	}
}

func TestAReviewAfterTheLastRoundCountsTheFindingsAfterTheCap(t *testing.T) {
	_, sh := reviewedRun(t, codeReviewRounds)
	findings := make([]codeReviewFinding, codeReviewSendMax+2)
	for i := range findings {
		findings[i] = codeReviewFinding{Severity: severityMajor, File: "a.go", Line: i + 1, Text: "Loses the file."}
	}
	if _, _, err := sh.pushPastCodeReview("new", findings, ""); err != nil {
		t.Fatal(err)
	}
	reasons := sh.r.Notes.Risk.Reasons
	if n := len(reasons); n != 1+1+codeReviewSendMax+1 || reasons[n-1] != "The code review found 2 more Critical or Major issues." {
		t.Fatalf("reasons %q", reasons)
	}
}

func TestCodeReviewRoundsIsEmptyForARunWithNoReview(t *testing.T) {
	if line := CodeReviewRounds(store.Run{}); line != "" {
		t.Fatalf("status line %q", line)
	}
}

func TestTheLastRoundTellsTheSessionThatItIsTheLast(t *testing.T) {
	f := []codeReviewFinding{{Severity: severityMajor, File: "a.go", Line: 1, Text: "Loses the file."}}
	last := "This is the last code review round of the run."
	if p := codeReviewPrompt(f, 0, codeReviewRounds, true); !strings.Contains(p, "(round 5 of 5)") || !strings.Contains(p, last) {
		t.Fatalf("prompt %q", p)
	}
	if p := codeReviewPrompt(f, 0, codeReviewRounds-1, true); strings.Contains(p, last) {
		t.Fatalf("prompt before the last round %q", p)
	}
}
