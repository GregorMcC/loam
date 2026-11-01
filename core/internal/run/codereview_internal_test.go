package run

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
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
	push, moved, err := sh.pushPastCodeReview("new", findings)
	if err != nil || !push || moved {
		t.Fatalf("push %v, moved %v, err %v", push, moved, err)
	}
	got, err := s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"A small change.",
		"The code review used all 5 rounds of the run, so these findings wait for you:",
		"Critical issue from the code review: a.go:4: Leaks the token.",
		"Major issue from the code review: b.go: Loses the file.",
		"Minor issue from the code review: c.go:2: A typo.",
	}
	if got.Notes == nil || !slices.Equal(got.Notes.Risk.Reasons, want) {
		t.Fatalf("reasons %q", got.Notes.Risk.Reasons)
	}
	if got.Notes.Risk.Level != store.RiskHigh {
		t.Fatalf("risk level %q, want high: the notes hold a Major finding", got.Notes.Risk.Level)
	}
	if got.State != store.RunShipping || got.CodeReview.Rounds != codeReviewRounds || got.CodeReview.Head != "new" {
		t.Fatalf("run %s, review %+v", got.State, got.CodeReview)
	}
	if line := CodeReviewRounds(got); line != "Code review: 5 of 5 rounds" {
		t.Fatalf("status line %q", line)
	}
	if e := lastEvent(t, s, sh.r.ID, "code_review"); e != "The code review found 1 critical issue, 1 major issue and 1 minor issue "+
		"after all 5 rounds of the run, so Loam pushes with them in the ship notes" {
		t.Fatalf("event %q", e)
	}
}

func TestAReviewAfterTheLastRoundCountsTheFindingsAfterTheCap(t *testing.T) {
	_, sh := reviewedRun(t, codeReviewRounds)
	findings := make([]codeReviewFinding, codeReviewSendMax+2)
	for i := range findings {
		findings[i] = codeReviewFinding{Severity: severityMajor, File: "a.go", Line: i + 1, Text: "Loses the file."}
	}
	if _, _, err := sh.pushPastCodeReview("new", findings); err != nil {
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

// A run whose PR has no ship notes, because Claude wrote none, still gets the
// Critical and Major findings after the last round in notes.risk.reasons.
func TestAReviewAfterTheLastRoundGivesARunWithNoNotesNotes(t *testing.T) {
	s, sh := reviewedRun(t, codeReviewRounds)
	r, err := s.UpdateRun(sh.r.ID, func(r *store.Run) error {
		r.Notes, r.PR = nil, &store.RunPR{Number: 12, URL: "https://github.com/o/r/pull/12"}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sh.r = r
	findings := []codeReviewFinding{{Severity: severityMajor, File: "b.go", Text: "Loses the file."}}
	if push, _, err := sh.pushPastCodeReview("new", findings); err != nil || !push {
		t.Fatalf("push %v, err %v", push, err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{codeReviewSpentFact, "Major issue from the code review: b.go: Loses the file."}
	if got.Notes == nil || got.Notes.Risk.Level != store.RiskHigh || !slices.Equal(got.Notes.Risk.Reasons, want) {
		t.Fatalf("notes %+v", got.Notes)
	}
	// A review that lets Loam push with nothing to wait for gives no notes.
	r, err = s.UpdateRun(r.ID, func(r *store.Run) error { r.Notes = nil; return nil })
	if err != nil {
		t.Fatal(err)
	}
	sh.r = r
	if _, _, err := sh.passCodeReview("newer", []string{"Minor issue from the code review: a.go:1: A typo."}, "The code review found 1 minor issue", nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetRun(r.ID); got.Notes != nil {
		t.Fatalf("notes %+v", got.Notes)
	}
}

// The PR that Loam opens with no notes of Claude gets the notes of the
// findings after the last round, and no notes otherwise.
func TestPRNotesFallBackToTheFindingsAfterTheLastRound(t *testing.T) {
	spent := &store.RunCodeReview{Facts: []string{codeReviewSpentFact, "Major issue from the code review: b.go: Loses the file."}}
	if n := prNotes(&store.RunPRDraft{}, spent); n == nil || n.Risk.Level != store.RiskHigh || !slices.Equal(n.Risk.Reasons, spent.Facts) {
		t.Fatalf("notes %+v", n)
	}
	claude := &store.RunNotes{Walkthrough: "Says hi.", Risk: store.NoteRisk{Level: store.RiskLow}}
	if n := prNotes(&store.RunPRDraft{Notes: claude}, spent); n == nil || n.Walkthrough != "Says hi." || n.Risk.Level != store.RiskHigh {
		t.Fatalf("notes %+v", n)
	}
	if n := prNotes(&store.RunPRDraft{Notes: claude}, &store.RunCodeReview{}); n != claude || n.Risk.Level != store.RiskLow {
		t.Fatalf("notes with no findings past the last round %+v", n)
	}
	if n := prNotes(&store.RunPRDraft{}, &store.RunCodeReview{Facts: []string{"The code review did not run: no claude"}}); n != nil {
		t.Fatalf("notes %+v", n)
	}
	if n := prNotes(&store.RunPRDraft{}, nil); n != nil {
		t.Fatalf("notes %+v", n)
	}
}

// reviewRepo is a repo with a branch that changes a file after main, and a
// run in Shipping in it.
func reviewRepo(t *testing.T) (*store.Store, store.Run, store.Worktree, string) {
	t.Helper()
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	testutil.Git(t, repo, "switch", "-c", "feature")
	if err := os.WriteFile(filepath.Join(repo, "a.go"), []byte("package a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, repo, "add", ".")
	testutil.Git(t, repo, "commit", "-m", "add a")
	s, sh := reviewedRun(t, 0)
	r, err := s.UpdateRun(sh.r.ID, func(r *store.Run) error { r.Folder = repo; return nil })
	if err != nil {
		t.Fatal(err)
	}
	return s, r, store.Worktree{Base: "main", Branch: "feature"}, testutil.Git(t, repo, "rev-parse", "HEAD")
}

// TAS-212: the review of round 2 sees the Critical and Major findings of
// round 1 and the reply of the session, so it does not reverse a fix
// without a new reason.
func TestTheReviewAfterARoundSeesTheEarlierFindings(t *testing.T) {
	s, r, w, head := reviewRepo(t)
	prompt, why := firstAsk(r, w, head, nil)
	if why != "" || strings.Contains(prompt, "## Earlier rounds") {
		t.Fatalf("first review: why %q, prompt %q", why, prompt)
	}
	round := storedRound([]codeReviewFinding{
		{Severity: severityMajor, File: "gate.go", Line: 7, Text: "The gate fails when the sandbox cannot read the cache."},
		{Severity: severityMinor, File: "a.go", Line: 1, Text: "A typo."},
	})
	round.Round = 1
	if err := s.AddRunEventData(r.ID, "code_review", "The code review found 1 major issue and 1 minor issue (round 1 of 5)",
		store.RunEventData{CodeReview: round}); err != nil {
		t.Fatal(err)
	}
	// A review that let Loam push is not a round.
	if err := s.AddRunEventData(r.ID, "code_review", "The code review found 1 minor issue",
		store.RunEventData{CodeReview: storedRound([]codeReviewFinding{{Severity: severityMinor, File: "b.go", Text: "Old."}})}); err != nil {
		t.Fatal(err)
	}
	r, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.CodeReview = &store.RunCodeReview{Rounds: 1, ReplyRound: 1}
		keepReply(r, "  I changed the gate to warn and skip.  ")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.CodeReview.ReplyRound != 0 || r.CodeReview.Replies[1] != "I changed the gate to warn and skip." {
		t.Fatalf("review state %+v", r.CodeReview)
	}
	events, err := s.RunEvents(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	prompt, why = firstAsk(r, w, head, earlierRounds(events, r.CodeReview))
	if why != "" {
		t.Fatal(why)
	}
	for _, want := range []string{
		"## Earlier rounds",
		"### Round 1\n\n- Major: gate.go:7: The gate fails when the sandbox cannot read the cache.\n",
		"The last message of the session after round 1:\n\n```\nI changed the gate to warn and skip.\n```\n",
		"Do not raise a finding that reverses an earlier one",
		"say in its text which earlier finding it reverses",
		"Set needs_you on a critical or major finding",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt has no %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "A typo.") || strings.Contains(prompt, "Old.") {
		t.Fatalf("the prompt holds a Minor finding:\n%s", prompt)
	}
	if i, j := strings.Index(prompt, "## Earlier rounds"), strings.Index(prompt, "## Diff"); i > j {
		t.Fatalf("the earlier rounds come after the diff")
	}
}

func TestTheEarlierFindingsKeepTheLast20(t *testing.T) {
	var rounds []earlierRound
	for round := 1; round <= 3; round++ {
		er := earlierRound{round: round}
		for i := range 10 {
			er.findings = append(er.findings, codeReviewFinding{Severity: severityMajor, File: fmt.Sprintf("r%d.go", round), Line: i + 1, Text: "Wrong."})
		}
		rounds = append(rounds, er)
	}
	var b strings.Builder
	writeEarlier(&b, rounds)
	got := b.String()
	if n := strings.Count(got, "- Major: "); n != codeReviewEarlierMax {
		t.Fatalf("%d findings, want %d:\n%s", n, codeReviewEarlierMax, got)
	}
	if strings.Contains(got, "r1.go") || !strings.Contains(got, "### Round 2") || !strings.Contains(got, "r3.go:10") {
		t.Fatalf("not the last rounds:\n%s", got)
	}
	if !strings.Contains(got, "The list holds the last 20 of 30 findings.") {
		t.Fatalf("no count:\n%s", got)
	}
	// A cap inside a round keeps its first, most severe, findings.
	b.Reset()
	writeEarlier(&b, append(rounds[:1:1], earlierRound{round: 2, findings: rounds[1].findings[:5]}, rounds[2]))
	if got := b.String(); !strings.Contains(got, "r1.go:5:") || strings.Contains(got, "r1.go:6:") {
		t.Fatalf("cap inside a round:\n%s", got)
	}
	b.Reset()
	writeEarlier(&b, []earlierRound{{round: 1}})
	if b.Len() != 0 {
		t.Fatalf("a round with no findings writes %q", b.String())
	}
}

// TAS-212: a fix that needs a setting that only you can change does not go
// back to the session. The run stops with the finding and its reason, and no
// round counts.
func TestAFindingThatNeedsYouStopsTheRun(t *testing.T) {
	s, sh := reviewedRun(t, 1)
	findings := cleanFindings([]codeReviewFinding{
		{Severity: severityMajor, File: "gate.go", Line: 7, Text: "The gate fails when the sandbox cannot read the cache",
			NeedsYou: " The sandbox needs a read path for the GhosttyKit cache. "},
		{Severity: severityMinor, File: "c.go", Text: "A typo.", NeedsYou: "Not a blocker."},
	})
	if findings[1].NeedsYou != "" {
		t.Fatalf("a Minor finding keeps needs_you: %+v", findings[1])
	}
	push, moved, err := sh.judgeCodeReview(context.Background(), "new", findings)
	if err != nil || push || !moved {
		t.Fatalf("push %v, moved %v, err %v", push, moved, err)
	}
	got, err := s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := "The code review found 1 issue that only you can fix, so the run stops:\n" +
		"- Major: gate.go:7: The gate fails when the sandbox cannot read the cache. Needs you: The sandbox needs a read path for the GhosttyKit cache.\n" +
		"Change the setting, then run loam run send-back to start the run again."
	if got.State != store.RunStopped || got.Note != want {
		t.Fatalf("run %s, note %q", got.State, got.Note)
	}
	if got.CodeReview.Rounds != 1 || got.CodeReview.Head != "old" || got.CodeReview.ReplyRound != 0 || got.Tries != 0 {
		t.Fatalf("review %+v, tries %d: the stop costs no round and no try", got.CodeReview, got.Tries)
	}
	if e := lastEvent(t, s, sh.r.ID, "code_review"); e != "The code review found 1 issue that only you can fix, so the run stops" {
		t.Fatalf("event %q", e)
	}
	events, err := s.RunEvents(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	last := LastCodeReview(events)
	if last == nil || !last.NeedsYou || last.Round != 0 || len(last.Findings) != 2 || last.Findings[0].NeedsYou == "" {
		t.Fatalf("stored review %+v", last)
	}
	// The next review sees the finding that stopped the run, and not the
	// Minor one.
	var b strings.Builder
	writeEarlier(&b, earlierRounds(events, got.CodeReview))
	if p := b.String(); !strings.Contains(p, "### Stopped the run for the user\n\n- Major: gate.go:7:") ||
		!strings.Contains(p, "(needs the user: The sandbox needs a read path for the GhosttyKit cache.)") {
		t.Fatalf("earlier rounds:\n%s", p)
	} else if strings.Contains(p, "c.go") {
		t.Fatalf("the earlier rounds hold a finding that went nowhere:\n%s", p)
	}
}

// A review whose blocking findings do not need you sends them back as a
// round, and the round waits for the reply of the session.
func TestARoundWaitsForTheReplyOfTheSession(t *testing.T) {
	r := store.Run{CodeReview: &store.RunCodeReview{Rounds: 2, ReplyRound: 2, Replies: map[int]string{1: "Fixed."}}}
	keepReply(&r, "")
	if r.CodeReview.ReplyRound != 0 || len(r.CodeReview.Replies) != 1 {
		t.Fatalf("a stop with no message: %+v", r.CodeReview)
	}
	keepReply(&r, "Late.") // no round waits
	if _, ok := r.CodeReview.Replies[2]; ok {
		t.Fatalf("a stop with no round that waits keeps a reply: %+v", r.CodeReview)
	}
	r.CodeReview.ReplyRound = 3
	keepReply(&r, strings.Repeat("a", store.CodeReviewReplyMax+1))
	if got := r.CodeReview.Replies[3]; !strings.HasSuffix(got, " (cut)") || utf8.RuneCountInString(got) != store.CodeReviewReplyMax+len(" (cut)") {
		t.Fatalf("long reply %d runes", utf8.RuneCountInString(got))
	}
	keepReply(&store.Run{}, "No review.")
}

// TAS-212: in a review with a finding that needs you and one that does not,
// the one that does not goes back to the session as a round. The one that
// needs you does not: the note names it, and the next review finds it again.
func TestAFindingThatNeedsYouLetsTheOtherFindingsGoToTheSession(t *testing.T) {
	s, sh := reviewedRun(t, 1)
	// The only slot is taken, so the round waits in Queued with its prompt
	// and Loam starts no session.
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddRun(store.Run{PlotID: sh.r.PlotID, Folder: t.TempDir(), Title: "Other", State: store.RunRunning}); err != nil {
		t.Fatal(err)
	}
	findings := []codeReviewFinding{
		{Severity: severityMajor, File: "gate.go", Line: 7, Text: "The gate fails when the sandbox cannot read the cache.",
			NeedsYou: "The sandbox needs a read path for the cache."},
		{Severity: severityMajor, File: "b.go", Text: "Loses the file."},
	}
	push, moved, err := sh.judgeCodeReview(context.Background(), "new", findings)
	if err != nil || push || !moved {
		t.Fatalf("push %v, moved %v, err %v", push, moved, err)
	}
	got, err := s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunQueued || got.Queue == nil {
		t.Fatalf("run %s, queue %+v", got.State, got.Queue)
	}
	if p := got.Queue.Resume; !strings.Contains(p, "b.go: Loses the file.") || strings.Contains(p, "gate.go") {
		t.Fatalf("prompt %q", p)
	}
	if got.CodeReview.Rounds != 2 || got.CodeReview.ReplyRound != 2 {
		t.Fatalf("review %+v, want round 2", got.CodeReview)
	}
	wantEvent := "The code review found 2 major issues (round 2 of 5). 1 issue only you can fix, and wait for the next review"
	if e := lastEvent(t, s, sh.r.ID, "code_review"); e != wantEvent {
		t.Fatalf("event %q", e)
	}
	events, err := s.RunEvents(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	rounds := earlierRounds(events, got.CodeReview)
	if len(rounds) != 1 || rounds[0].round != 2 || len(rounds[0].findings) != 1 || rounds[0].findings[0].File != "b.go" {
		t.Fatalf("earlier rounds %+v: the finding that needs you went nowhere", rounds)
	}
	if len(got.CodeReview.Held) != 1 || got.CodeReview.Held[0].File != "gate.go" {
		t.Fatalf("held %+v, want the finding that needs you", got.CodeReview.Held)
	}

	// The session fixed b.go, and the next review finds nothing. The held
	// finding still reaches you: the run stops with it, and pushes nothing.
	r, err := s.UpdateRun(sh.r.ID, func(r *store.Run) error { r.State, r.Queue = store.RunShipping, nil; return nil })
	if err != nil {
		t.Fatal(err)
	}
	sh.r = r
	push, moved, err = sh.judgeCodeReview(context.Background(), "newer", nil)
	if err != nil || push || !moved {
		t.Fatalf("next review: push %v, moved %v, err %v", push, moved, err)
	}
	got, err = s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || !strings.Contains(got.Note, "- Major: gate.go:7: The gate fails when the sandbox cannot read the cache. Needs you:") {
		t.Fatalf("run %s, note %q", got.State, got.Note)
	}
	if len(got.CodeReview.Held) != 0 || got.CodeReview.Rounds != 2 {
		t.Fatalf("review %+v: the stop empties the held findings and counts no round", got.CodeReview)
	}

	// After the last round, a finding that needs you stops the run, and the
	// note names the other findings too.
	s, sh = reviewedRun(t, codeReviewRounds)
	if _, _, err := sh.judgeCodeReview(context.Background(), "new", findings); err != nil {
		t.Fatal(err)
	}
	got, err = s.GetRun(sh.r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || !strings.Contains(got.Note, "Needs you: The sandbox needs a read path for the cache.") ||
		!strings.Contains(got.Note, "The code review also found:\n- Major: b.go: Loses the file.") {
		t.Fatalf("run %s, note %q", got.State, got.Note)
	}
}

func TestWithHeldAddsTheHeldFindingsOnce(t *testing.T) {
	held := codeReviewFinding{Severity: severityMajor, File: "gate.go", Text: "Fails.", NeedsYou: "A read path."}
	c := &store.RunCodeReview{Held: []store.RunFinding{store.RunFinding(held)}}
	minor := codeReviewFinding{Severity: severityMinor, File: "a.go", Text: "A typo."}
	if got := withHeld([]codeReviewFinding{minor}, c); !slices.Equal(got, []codeReviewFinding{held, minor}) {
		t.Fatalf("got %+v", got)
	}
	if got := withHeld([]codeReviewFinding{held}, c); len(got) != 1 {
		t.Fatalf("a finding that the review found again is there twice: %+v", got)
	}
	if got := withHeld([]codeReviewFinding{minor}, nil); len(got) != 1 {
		t.Fatalf("no review state: %+v", got)
	}
}

func TestSplitDiffKeepsAllOfTheDiffAndTheContextOfEachPart(t *testing.T) {
	file := func(name string, lines int) string {
		return "diff --git a/" + name + " b/" + name + "\n@@ -1 +1 @@ " + name + "\n" + strings.Repeat("+é line\n", lines)
	}
	long := strings.Repeat("x", 90)
	diff := file("a", 1) + file("b", 1) + file("c", 30) + "diff --git a/d b/d\n+" + long + "\n"
	const limit = 60
	parts := splitDiff(diff, limit)
	joined := strings.Join(parts, "")
	if n := strings.Count(joined, "+é line\n"); n != 32 {
		t.Fatalf("%d of 32 lines in the parts: %q", n, parts)
	}
	if n := strings.Count(joined, "x"); n != len(long) {
		t.Fatalf("%d of %d characters of the long line", n, len(long))
	}
	for _, p := range parts {
		if !strings.HasPrefix(p, "diff --git ") {
			t.Errorf("a part with no file: %q", p)
		}
		if n := utf8.RuneCountInString(p); n > limit+40 {
			t.Errorf("part of %d characters: %q", n, p)
		}
	}
	if strings.Count(joined, "diff --git a/c") < 2 || strings.Count(joined, "@@ -1 +1 @@ c") < 2 {
		t.Errorf("a later part of a long file has no context: %q", parts)
	}
	if got := splitDiff("", limit); len(got) != 0 {
		t.Errorf("an empty diff gives parts: %q", got)
	}
}

// A diff of many files that do not fit together still gets a review, while it
// is within the limit of all the parts.
func TestSplitDiffPartsOfManyFiles(t *testing.T) {
	var b strings.Builder
	for i := range 7 {
		fmt.Fprintf(&b, "diff --git a/%d b/%d\n%s\n", i, i, strings.Repeat("+", 31000))
	}
	if parts := splitDiff(b.String(), codeReviewDiffMax); len(parts) != 7 {
		t.Fatalf("%d parts", len(parts))
	}
}

// firstAsk is the prompt of the first part of the review.
func firstAsk(r store.Run, w store.Worktree, head string, earlier []earlierRound) (prompt, why string) {
	prompts, why := codeReviewAsk(context.Background(), r, w, head, earlier)
	if why != "" {
		return "", why
	}
	return prompts[0], ""
}
