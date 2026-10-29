package cli

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-60: a run whose PR has changes requested does not go Ready when CI passes. The review goes back to its
// session first, with its own count of tries.

// reviewR1 is a review by alice that requests changes, and threadT1 is a thread of hers that is not resolved, with
// a reply by bob, who cannot push to the repo. threadT0 is resolved.
const (
	reviewR1 = `{"id": "R1", "state": "CHANGES_REQUESTED", "body": "Two things before this merges.",
  "url": "https://github.com/example/widgets/pull/1#pullrequestreview-1", "author": {"login": "alice"}}`
	threadT1 = `{"id": "T1", "isResolved": false, "path": "hello.txt", "line": 1, "comments": {"nodes": [
  {"body": "Say hello to the world.", "url": "https://github.com/example/widgets/pull/1#discussion_r1", "author": {"login": "alice"},
   "pullRequestReview": {"authorCanPushToRepository": true}},
  {"body": "And keep it short.", "url": "https://github.com/example/widgets/pull/1#discussion_r2", "author": {"login": "bob"}}]}}`
	threadT0 = `{"id": "T0", "isResolved": true, "path": "hello.txt", "line": 1, "comments": {"nodes": [
  {"body": "An old point.", "url": "https://github.com/example/widgets/pull/1#discussion_r0", "author": {"login": "alice"}}]}}`
)

// reviewState is ciState with CI passed, the review decision, and the reviews and threads of PR #1, as JSON
// lists of GitHub nodes.
func reviewState(branch, head, decision, reviews, threads string) string {
	state := ciState(branch, head, "SUCCESS")
	state = strings.Replace(state, `"mergeStateStatus": "CLEAN"`,
		fmt.Sprintf(`"mergeStateStatus": "CLEAN", "reviewDecision": %q`, decision), 1)
	return strings.Replace(state, `"reviewThreads": {"nodes": []}`,
		fmt.Sprintf(`"latestOpinionatedReviews": {"nodes": %s}, "reviewThreads": {"nodes": %s}`, reviews, threads), 1)
}

// resumes are the prompts that Loam sent to the session with claude --bg --resume, in order.
func resumes(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, c := range testutil.FakeClaudeCalls(t) {
		if len(c) == 4 && c[0] == "--bg" && c[1] == "--resume" {
			out = append(out, c[3])
		}
	}
	return out
}

// passGate ends the turn of the session of a Running run, so its gate passes and it is Shipping again.
func passGate(t *testing.T, s *store.Store, r store.Run) {
	t.Helper()
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("gate: %d %s", code, reason)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunShipping {
		t.Fatalf("not shipping: %+v", got)
	}
}

func TestRunTickSendsAReviewThatRequestsChangesBackAsAReviewTry(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "["+threadT1+", "+threadT0+"]"))
	got := tick(t)
	note := "Changes are requested on #1. Loam sent back 1 review thread and 1 review (review try 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note ||
		got.Runs[0].Tries != 0 || got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{"Changes are requested on #1: 1 review thread and 1 review"}) {
		t.Fatalf("review events %q", e)
	}
	prompts := resumes(t)
	if len(prompts) != 1 {
		t.Fatalf("prompts %q", prompts)
	}
	for _, want := range []string{
		"Changes are requested on #1 (review try 1 of 2)",
		"## Review by alice", "https://github.com/example/widgets/pull/1#pullrequestreview-1", "> Two things before this merges.",
		"## Thread on hello.txt:1", "Thread ID: T1", "https://github.com/example/widgets/pull/1#discussion_r1",
		"alice wrote:\n> Say hello to the world.", "bob, who cannot push to the repo, wrote a comment (https://github.com/example/widgets/pull/1#discussion_r2). Loam leaves out its text.",
		"Commit all the fixes in one commit", "A nitpick or a Minor point whose fix is not worth it needs no change",
		"addPullRequestReviewThreadReply", "resolveReviewThread", "pushes the fix to #1",
	} {
		if !strings.Contains(prompts[0], want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompts[0])
		}
	}
	if strings.Contains(prompts[0], "An old point.") || strings.Contains(prompts[0], "And keep it short.") {
		t.Errorf("the prompt has a resolved thread, or the text of a reader:\n%s", prompts[0])
	}

	// The session fixes the code and resolves the thread. GitHub keeps the decision until alice reviews again: with
	// the review sent and no thread open, the run is Ready, and Loam does not send the review twice.
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	passGate(t, s, r)
	tick(t) // pushes the fix
	head = testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "["+threadT0+"]"))
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" ||
		got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if n := len(resumes(t)); n != 1 {
		t.Fatalf("%d prompts", n)
	}
}

// A review with a body and no threads goes back once. The next time CI passes, it does not stop the run.
func TestRunTickSendsAReviewWithNoThreadsOnce(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "[]"))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning ||
		got.Runs[0].Note != "Changes are requested on #1. Loam sent back 1 review (review try 1 of 2)" {
		t.Fatalf("%+v", got)
	}
	if p := resumes(t); len(p) != 1 || !strings.Contains(p[0], "> Two things before this merges.") ||
		!strings.Contains(p[0], "commit all the fixes in one commit") || !strings.Contains(p[0], "make no commit") ||
		strings.Contains(p[0], "resolveReviewThread") {
		t.Fatalf("prompts %q", p)
	}
	// The session ends its turn with no change: the head is the same, and CI passed on it.
	passGate(t, s, r)
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("%+v", got)
	}
	if n := len(resumes(t)); n != 1 {
		t.Fatalf("%d prompts", n)
	}
}

// A thread that stays open goes back again, as the next review try. With no review tries left, the run is Ready,
// and the note says that changes are requested. A tick then leaves it Ready.
func TestRunTickMakesARunReadyWhenTheReviewTriesAreUsedUp(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "["+threadT1+"]"))
	for try := 1; try <= store.DefaultMaxReviewTries; try++ {
		got := tick(t)
		if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].ReviewTries != try {
			t.Fatalf("try %d: %+v", try, got)
		}
		passGate(t, s, r)
	}
	prompts := resumes(t)
	if len(prompts) != store.DefaultMaxReviewTries || !strings.Contains(prompts[1], "(review try 2 of 2)") ||
		!strings.Contains(prompts[1], "Thread ID: T1") || strings.Contains(prompts[1], "## Review by alice") {
		t.Fatalf("prompts %q", prompts)
	}
	got := tick(t)
	note := "CI passed on #1: 1 of 1 checks. The review tries are used up, and changes are requested on #1"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != note || got.Runs[0].Tries != 0 {
		t.Fatalf("%+v", got)
	}
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("tick after Ready: %+v", got)
	}
}

// Only a review that requests changes stops the run. A thread with no change request does not.
func TestRunTickMakesARunReadyWithOpenThreadsAndNoChangesRequested(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "REVIEW_REQUIRED", "[]", "["+threadT1+"]"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", got)
	}
	if p := resumes(t); len(p) != 0 {
		t.Fatalf("prompts %q", p)
	}
}

// A review that requests changes after the run is Ready moves the run back to Shipping, and a later tick sends the
// review back.
func TestRunTickShipsAReadyRunAgainWhenChangesAreRequested(t *testing.T) {
	s, r, w := readyRun(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "["+threadT1+"]"))
	got := tick(t)
	note := "Changes are requested on #1 after it was ready. Loam sends the review back"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{note}) {
		t.Fatalf("review events %q", e)
	}
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if p := resumes(t); len(p) != 1 || !strings.Contains(p[0], "Thread ID: T1") {
		t.Fatalf("prompts %q", p)
	}
}

// A review that does not reach the session stops the run, as a CI failure does, and the review try counts.
func TestRunTickStopsARunWhoseReviewDidNotReachTheSession(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.SessionID = ""; return nil }); err != nil {
		t.Fatal(err)
	}
	setGitHub(t, reviewState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "CHANGES_REQUESTED", "["+reviewR1+"]", "[]"))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].ReviewTries != 1 ||
		got.Runs[0].Note != "Could not send the review to the session: the run has no session" {
		t.Fatalf("%+v", got)
	}
}

// TAS-61: you send the review of a Ready run back to its session from the desk. The review decision does not
// matter, no review try counts, and the text of a reader stays out of the prompt.
func TestRunSendReviewSendsOpenThreadsWithNoChangeRequestAndUsesNoTry(t *testing.T) {
	s, r, w := readyRun(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "REVIEW_REQUIRED", "[]", "["+threadT1+", "+threadT0+"]"))
	// A dry run reads the PR and sends nothing.
	out, code := loam(t, "run", "send-review", r.ID, "--dry-run", "--json")
	var plan run.ReviewResult
	if err := json.Unmarshal([]byte(out), &plan); err != nil || code != 0 || plan.Threads != 1 || plan.Reviews != 0 ||
		plan.PR.ReviewDecision != "REVIEW_REQUIRED" || len(plan.PR.ReviewThreads) != 1 || plan.Run.State != store.RunReady || len(resumes(t)) != 0 {
		t.Fatalf("exit %d, %v: %s", code, err, out)
	}
	out, code = loam(t, "run", "send-review", r.ID, "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunRunning || got.ReviewTries != 0 || got.Tries != r.Tries ||
		got.Note != "You sent back the review of #1. Loam sent back 1 review thread" {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{"You sent back the review of #1: 1 review thread"}) {
		t.Fatalf("review events %q", e)
	}
	prompts := resumes(t)
	if len(prompts) != 1 {
		t.Fatalf("prompts %q", prompts)
	}
	for _, want := range []string{
		"I ask you to address the review of #1.", "Thread ID: T1", "alice wrote:\n> Say hello to the world.",
		"bob, who cannot push to the repo, wrote a comment", "resolveReviewThread",
	} {
		if !strings.Contains(prompts[0], want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompts[0])
		}
	}
	if strings.Contains(prompts[0], "review try") || strings.Contains(prompts[0], "And keep it short.") || strings.Contains(prompts[0], "An old point.") {
		t.Errorf("the prompt has a review try, the text of a reader, or a resolved thread:\n%s", prompts[0])
	}
}

// A review that requests changes is sent once: after the send, a run that is Ready again has nothing to send.
func TestRunSendReviewSendsAReviewOnceAndRefusesWhenThereIsNothingToSend(t *testing.T) {
	s, r, w := readyRun(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "[]"))
	if out, code := loam(t, "run", "send-review", r.ID, "--json"); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if p := resumes(t); len(p) != 1 || !strings.Contains(p[0], "> Two things before this merges.") {
		t.Fatalf("prompts %q", p)
	}
	passGate(t, s, r)
	tick(t) // CI passed on the head, and Loam sent the review: the run is Ready again
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("%+v", got)
	}
	out, code := loam(t, "run", "send-review", r.ID, "--json")
	if code != ExitInvalid || !strings.Contains(out, "no review to send back") {
		t.Fatalf("exit %d: %s", code, out)
	}
	// A dry run says that there is nothing to send, and it is no error.
	var plan run.ReviewResult
	out, code = loam(t, "run", "send-review", r.ID, "--dry-run", "--json")
	if err := json.Unmarshal([]byte(out), &plan); err != nil || code != 0 || plan.Threads != 0 || plan.Reviews != 0 {
		t.Fatalf("exit %d, %v: %s", code, err, out)
	}
}

func TestRunSendReviewRefusesARunThatIsNotReady(t *testing.T) {
	_, r, _ := shipRun(t, "3")
	if out, code := loam(t, "run", "send-review", r.ID, "--json"); code != ExitInvalid || !strings.Contains(out, "Ready to land") {
		t.Fatalf("exit %d: %s", code, out)
	}
}
