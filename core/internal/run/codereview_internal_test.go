package run

import (
	"slices"
	"strings"
	"testing"
	"unicode/utf8"
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
	if p := codeReviewPrompt(f, 3, 2); !strings.Contains(p, "The review found 3 more Critical or Major issues.") {
		t.Fatalf("prompt %q", p)
	}
	if p := codeReviewPrompt(f, 0, 2); strings.Contains(p, "more Critical") {
		t.Fatalf("prompt with no more %q", p)
	}
	if l := findingLines(f, 1); l != "- Major: a.go:1: Loses the file.\n- and 1 more Critical or Major issue" {
		t.Fatalf("lines %q", l)
	}
}
