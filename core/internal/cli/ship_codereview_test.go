package cli

import (
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-64: before each push, Loam runs a code review of the diff of the run.
// A Critical or Major finding goes back to the session, and a Minor finding
// goes in the ship notes.

// codeReviewSchemaText is a text that only the JSON Schema of the code review
// holds, so the fake claude gives the review its own answer.
const codeReviewSchemaText = `"findings"`

// codeReviewAnswer is the code review that claude -p prints, with findings, a
// JSON list.
func codeReviewAnswer(findings string) string {
	return `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"findings": ` + findings + `}}`
}

const majorFinding = `[{"severity": "major", "file": "hello.txt", "line": 1, "text": "The greeting has no capital letter."},
 {"severity": "minor", "file": "hello.txt", "line": 1, "text": "The greeting has no full stop."}]`

const minorFinding = `[{"severity": "minor", "file": "./hello.txt", "line": 1, "text": "The greeting has no full stop."}]`

// codeReviewRun is a run in Shipping in a folder that Claude Code trusts, with
// the ship notes of notesAnswer and the code review of findings.
func codeReviewRun(t *testing.T, findings string) (*store.Store, store.Run, store.Worktree) {
	t.Helper()
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, notesAnswer)
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(findings))
	return s, r, w
}

// isCodeReviewCall reports whether the claude call with args is a code review.
func isCodeReviewCall(args []string) bool {
	i := slices.Index(args, "--json-schema")
	return slices.Contains(args, "-p") && i >= 0 && i+1 < len(args) && strings.Contains(args[i+1], codeReviewSchemaText)
}

// codeReviewCalls are the claude -p calls of the code review.
func codeReviewCalls(t *testing.T) [][]string {
	t.Helper()
	return slices.DeleteFunc(testutil.FakeClaudeCalls(t), func(c []string) bool { return !isCodeReviewCall(c) })
}

// pushedBranch reports whether the branch of the worktree is on GitHub at
// the head of the run.
func pushedBranch(t *testing.T, r store.Run, w store.Worktree) bool {
	t.Helper()
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	out, err := exec.Command("git", "-C", remote, "rev-parse", "--verify", "--quiet", "refs/heads/"+w.Branch).Output()
	return err == nil && strings.TrimSpace(string(out)) == testutil.Git(t, r.Folder, "rev-parse", "HEAD")
}

// resumePrompt is the prompt of the last claude --bg --resume call, or "".
func resumePrompt(t *testing.T) string {
	t.Helper()
	calls := testutil.FakeClaudeCalls(t)
	for _, c := range slices.Backward(calls) {
		if len(c) > 3 && slices.Equal(c[:3], []string{"--bg", "--resume", shipSession}) {
			return c[len(c)-1]
		}
	}
	return ""
}

func TestRunTickSendsAMajorReviewFindingBackAndDoesNotPush(t *testing.T) {
	s, r, w := codeReviewRun(t, majorFinding)
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Tries != 0 ||
		got.Runs[0].Note != "The code review found 1 major issue and 1 minor issue (round 1 of 5)" {
		t.Fatalf("%+v", got)
	}
	if pushedBranch(t, r, w) || len(ghCreates(t)) != 0 {
		t.Fatalf("Loam pushed past a Major finding: %q", ghCreates(t))
	}
	prompt := resumePrompt(t)
	for _, want := range []string{"round 1 of 5", "## Major: hello.txt:1: The greeting has no capital letter.", "commit"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "full stop") {
		t.Errorf("the prompt has the Minor finding:\n%s", prompt)
	}
	calls := codeReviewCalls(t)
	if len(calls) != 1 {
		t.Fatalf("review calls %q", calls)
	}
	args := calls[0]
	review := args[slices.Index(args, "-p")+1]
	for _, want := range []string{"Say hi", "+hi there", "critical:", "major:", "minor:", "## Changed files", "hello.txt | 1 +"} {
		if !strings.Contains(review, want) {
			t.Errorf("the review prompt misses %q:\n%s", want, review)
		}
	}
	if strings.Contains(review, "The folder is not at the commit") {
		t.Errorf("the worktree is at the head, but the prompt says it is not:\n%s", review)
	}
	if !slices.Contains(args, "Read,Grep,Glob") || slices.Contains(args, "--effort") {
		t.Fatalf("review args %q", args)
	}
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review found 1 major issue and 1 minor issue (round 1 of 5)"}) {
		t.Fatalf("code_review events %q", e)
	}

	// The fix comes back through the gate. The review of the new diff finds
	// no issue, and the next tick pushes and opens the PR.
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(`[]`))
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatal("the gate did not pass the fix")
	}
	tick(t)
	if !pushedBranch(t, r, w) || len(ghCreates(t)) != 1 {
		t.Fatalf("no push after a clean review: %q", ghCreates(t))
	}
	if e := events(t, s, r.ID, "code_review"); len(e) != 2 || e[1] != "The code review found no issues" {
		t.Fatalf("code_review events %q", e)
	}
	if r2, _ := s.GetRun(r.ID); r2.CodeReview == nil || r2.CodeReview.Rounds != 0 {
		t.Fatalf("a review that lets Loam push starts the rounds again: %+v", r2.CodeReview)
	}
	// GitHub does not show the new head yet. The next tick does not review
	// the same head again.
	tick(t)
	if calls := codeReviewCalls(t); len(calls) != 2 {
		t.Fatalf("review calls %d", len(calls))
	}
}

func TestRunTickPutsMinorReviewFindingsInTheShipNotes(t *testing.T) {
	s, r, w := codeReviewRun(t, minorFinding)
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--model", "sonnet", "--review-effort", "low"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	tick(t)
	if !pushedBranch(t, r, w) || len(ghCreates(t)) != 1 {
		t.Fatalf("Loam did not push past a Minor finding: %q", ghCreates(t))
	}
	if up := testutil.Git(t, r.Folder, "rev-parse", "--abbrev-ref", w.Branch+"@{upstream}"); up != "origin/"+w.Branch {
		t.Fatalf("upstream %q", up)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	fact := "Minor issue from the code review: hello.txt:1: The greeting has no full stop."
	if got.Notes == nil || !slices.Contains(got.Notes.Risk.Reasons, fact) {
		t.Fatalf("notes %+v", got.Notes)
	}
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review found 1 minor issue"}) {
		t.Fatalf("code_review events %q", e)
	}
	calls := codeReviewCalls(t)
	if len(calls) != 1 || !containsRun(calls[0], []string{"--model", "sonnet"}) || !containsRun(calls[0], []string{"--effort", "low"}) {
		t.Fatalf("review calls %q", calls)
	}

	// A fix after a failed CI is reviewed again. Its findings replace those
	// of the first push in the notes.
	failCI(t, r, w)
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(`[]`))
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatal("the gate did not pass the fix")
	}
	tick(t)
	if !pushedBranch(t, r, w) {
		t.Fatal("the fix is not on GitHub")
	}
	if got, _ = s.GetRun(r.ID); got.Notes == nil || slices.Contains(got.Notes.Risk.Reasons, fact) ||
		!slices.Contains(got.Notes.Risk.Reasons, "One new file.") {
		t.Fatalf("notes after the fix %+v", got.Notes)
	}
}

func TestRunTickStopsARunAfterFiveReviewRoundsWithMajorFindings(t *testing.T) {
	s, r, w := codeReviewRun(t, majorFinding)
	for round := 1; round <= 4; round++ {
		got := tick(t)
		if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning {
			t.Fatalf("round %d: %+v", round, got)
		}
		writeAndCommit(t, r.Folder, "fix.txt", strings.Repeat("fixed\n", round))
		if code, _ := stopHook(t, r, "Stop"); code != 0 {
			t.Fatalf("round %d: the gate did not pass the fix", round)
		}
	}
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].Tries != 0 ||
		!strings.HasPrefix(got.Runs[0].Note, "The code review still found Critical or Major issues after 5 rounds:\n") ||
		!strings.Contains(got.Runs[0].Note, "- Major: hello.txt:1: The greeting has no capital letter.") {
		t.Fatalf("%+v", got)
	}
	if pushedBranch(t, r, w) || len(ghCreates(t)) != 0 {
		t.Fatal("Loam pushed past a Major finding")
	}
	if e := events(t, s, r.ID, "code_review"); len(e) != 5 || e[4] != "The code review found 1 major issue and 1 minor issue (round 5 of 5)" {
		t.Fatalf("code_review events %q", e)
	}
	prompts := func() int {
		return len(slices.DeleteFunc(testutil.FakeClaudeCalls(t), func(c []string) bool { return !slices.Contains(c, "--resume") }))
	}
	if n := prompts(); n != 4 {
		t.Fatalf("%d prompts, want 4", n)
	}

	// A send-back gives one more round that sends the findings to the
	// session. The round after it stops the run again.
	if _, errOut, err := lrRun(t, "", "run", "send-back", r.ID, "--note", "Use a capital letter."); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	for _, want := range []store.RunState{store.RunRunning, store.RunStopped} {
		writeAndCommit(t, r.Folder, "fix.txt", "fixed again "+string(want)+"\n")
		if code, _ := stopHook(t, r, "Stop"); code != 0 {
			t.Fatal("the gate did not pass the fix")
		}
		if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != want {
			t.Fatalf("after the send-back, want %s: %+v", want, got)
		}
	}
	if e := events(t, s, r.ID, "code_review"); len(e) != 7 || e[5] != "The code review found 1 major issue and 1 minor issue (round 4 of 5)" {
		t.Fatalf("code_review events %q", e)
	}
	if n := prompts(); n != 6 { // the send-back and the round after it
		t.Fatalf("%d prompts, want 6", n)
	}
}

func TestRunTickPushesWithNoReviewWhenTheReviewIsOff(t *testing.T) {
	s, r, w := codeReviewRun(t, majorFinding)
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--review", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	tick(t)
	if !pushedBranch(t, r, w) || len(ghCreates(t)) != 1 {
		t.Fatalf("no push with the review off: %q", ghCreates(t))
	}
	if calls := codeReviewCalls(t); len(calls) != 0 {
		t.Fatalf("review calls %q", calls)
	}
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review is off for the plot, so Loam pushes with no review"}) {
		t.Fatalf("code_review events %q", e)
	}
}

func TestRunTickPushesWithANoteWhenTheReviewFails(t *testing.T) {
	s, r, w := codeReviewRun(t, `[]`)
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, `{"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "API error"}`)
	tick(t)
	if !pushedBranch(t, r, w) || len(ghCreates(t)) != 1 {
		t.Fatalf("no push after a failed review: %q", ghCreates(t))
	}
	why := "claude -p gave no review. error_during_execution API error"
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review did not run, so Loam pushes with no review: " + why}) {
		t.Fatalf("code_review events %q", e)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Notes == nil || !slices.Contains(got.Notes.Risk.Reasons, "The code review did not run: "+why) {
		t.Fatalf("notes %+v", got.Notes)
	}
}

// A commit after Ready gets a code review before Loam pushes it. A Major
// finding sends the run back to its session from Ready, and the PR keeps the
// head that CI passed on.
func TestRunTickSendsAReviewOfACommitAfterReadyBackAndDoesNotPush(t *testing.T) {
	s, r, w := readyRun(t)
	shipped := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(majorFinding))
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunRunning {
		t.Fatalf("%+v", res)
	}
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != shipped {
		t.Fatal("Loam pushed a head with a Major finding")
	}
	if p := resumePrompt(t); !strings.Contains(p, "## Major: hello.txt:1: The greeting has no capital letter.") {
		t.Fatalf("prompt %q", p)
	}
	if e := events(t, s, r.ID, "ship"); slices.Contains(e, "Pushed the new commits to #1") {
		t.Fatalf("ship events %q", e)
	}
}

// A diff that is longer than the prompt keeps is cut. A review of it that
// lets Loam push says so in the event and in the ship notes.
func TestRunTickSaysWhenTheReviewSawACutDiff(t *testing.T) {
	s, r, w := codeReviewRun(t, `[]`)
	writeAndCommit(t, r.Folder, "big.txt", strings.Repeat("a long line of text\n", 4000))
	tick(t)
	if !pushedBranch(t, r, w) {
		t.Fatal("no push")
	}
	calls := codeReviewCalls(t)
	if len(calls) != 1 || !strings.Contains(calls[0][slices.Index(calls[0], "-p")+1], "so it is cut") {
		t.Fatalf("review calls %d", len(calls))
	}
	cut := "The diff is longer than 60000 characters, so the code review saw only its start in the prompt"
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review found no issues. " + cut}) {
		t.Fatalf("code_review events %q", e)
	}
	if got, _ := s.GetRun(r.ID); got.Notes == nil || !slices.Contains(got.Notes.Risk.Reasons, cut) {
		t.Fatalf("notes %+v", got.Notes)
	}
}

// When the diff is cut and the worktree is on another commit, the tools of
// Claude cannot read the rest of the head. The review of the start of the
// diff says that it did not see the rest.
func TestRunTickSaysWhenTheReviewSawACutDiffAwayFromTheHead(t *testing.T) {
	s, r, w := codeReviewRun(t, `[]`)
	writeAndCommit(t, r.Folder, "big.txt", strings.Repeat("a long line of text\n", 4000))
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	testutil.Git(t, r.Folder, "checkout", "-q", "--detach", "HEAD~1")
	tick(t)
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != head {
		t.Fatal("no push of the head")
	}
	if calls := codeReviewCalls(t); len(calls) != 1 {
		t.Fatalf("review calls %d", len(calls))
	}
	cut := "The diff is longer than 60000 characters, and the folder is not at its head, so the code review did not see the rest of the diff"
	if e := events(t, s, r.ID, "code_review"); !slices.Equal(e, []string{"The code review found no issues. " + cut}) {
		t.Fatalf("code_review events %q", e)
	}
	if got, _ := s.GetRun(r.ID); got.Notes == nil || !slices.Contains(got.Notes.Risk.Reasons, cut) {
		t.Fatalf("notes %+v", got.Notes)
	}
}
