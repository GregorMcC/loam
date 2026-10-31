package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
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
		if len(c) > 3 && c[0] == "--bg" && c[1] == "--resume" {
			out = append(out, c[len(c)-1])
		}
	}
	return out
}

// repliesFile is where the session of the run writes its replies to a review: below the git folder of its worktree.
func repliesFile(t *testing.T, r store.Run) string {
	t.Helper()
	return filepath.Join(testutil.Git(t, r.Folder, "rev-parse", "--absolute-git-dir"), "loam", "review-replies.json")
}

// writeReplies writes the replies file of the run, as the session does.
func writeReplies(t *testing.T, r store.Run, text string) {
	t.Helper()
	if err := os.WriteFile(repliesFile(t, r), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// ghPosts is what Loam posted on the fake GitHub.
type ghPosts struct {
	ThreadReplies map[string][]string `json:"thread_replies"`
	Resolved      []string            `json:"resolved"`
	PRComments    map[string][]string `json:"pr_comments"`
}

func posts(t *testing.T) ghPosts {
	t.Helper()
	var p ghPosts
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &p)
	}
	if err != nil {
		t.Fatal(err)
	}
	return p
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
		"Commit all the fixes in one commit", "Fix each Critical or Major point that holds against the code.", "Fix a Minor point or a nitpick only when the fix is small",
		repliesFile(t, r), `{"threads": [{"id": "<thread ID>", "body": "<reply>", "resolve": true}], "comment": "<comment>"}`,
		"Do not run gh: Loam posts the replies on GitHub after it pushes the fix.", "pushes the fix to #1",
	} {
		if !strings.Contains(prompts[0], want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompts[0])
		}
	}
	if strings.Contains(prompts[0], "An old point.") || strings.Contains(prompts[0], "And keep it short.") {
		t.Errorf("the prompt has a resolved thread, or the text of a reader:\n%s", prompts[0])
	}

	// TAS-175: the session fixes the code and writes its replies to the file. When GitHub shows the fix, Loam posts
	// the replies and resolves the thread. GitHub keeps the decision until alice reviews again: with the review sent
	// and no thread open, the run is Ready, and Loam does not send the review twice.
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	writeReplies(t, r, `{"threads": [{"id": "T1", "body": "It says hello to the world now.", "resolve": true}],
  "comment": "The second thing stays: the name is in the contract."}`)
	passGate(t, s, r)
	tick(t) // pushes the fix
	if p := posts(t); len(p.ThreadReplies) != 0 || len(p.PRComments) != 0 {
		t.Fatalf("Loam posted before GitHub showed the fix: %+v", p)
	}
	head = testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+reviewR1+"]", "["+threadT1+", "+threadT0+"]"))
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" ||
		got.Runs[0].ReviewTries != 1 || len(got.Warnings) != 0 {
		t.Fatalf("%+v", got)
	}
	if n := len(resumes(t)); n != 1 {
		t.Fatalf("%d prompts", n)
	}
	p := posts(t)
	if !slices.Equal(p.ThreadReplies["T1"], []string{"It says hello to the world now."}) || !slices.Equal(p.Resolved, []string{"T1"}) ||
		!slices.Equal(p.PRComments["1"], []string{"The second thing stays: the name is in the contract."}) {
		t.Fatalf("posts %+v", p)
	}
	want := "Posted 1 review reply and a comment on #1, and resolved 1 thread"
	if e := events(t, s, r.ID, "review"); len(e) != 2 || e[1] != want {
		t.Fatalf("review events %q", e)
	}
	if _, err := os.Stat(repliesFile(t, r)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the replies file stays: %v", err)
	}
	// A later tick posts nothing again.
	if got := tick(t); len(got.Runs) != 0 || len(posts(t).ThreadReplies["T1"]) != 1 {
		t.Fatalf("%+v", got)
	}
}

// TAS-175: an old replies file never goes to a new review. Loam removes it before it sends the review, and leaves the
// folder for the session.
func TestRunTickRemovesAnOldReplyFileBeforeItSendsAReview(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	if err := os.MkdirAll(filepath.Dir(repliesFile(t, r)), 0o755); err != nil {
		t.Fatal(err)
	}
	writeReplies(t, r, `{"threads": [{"id": "T1", "body": "An old reply.", "resolve": true}]}`)
	setGitHub(t, reviewState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "CHANGES_REQUESTED", "[]", "["+threadT1+"]"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning {
		t.Fatalf("%+v", got)
	}
	if _, err := os.Stat(repliesFile(t, r)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the old file stays: %v", err)
	}
	if fi, err := os.Stat(filepath.Dir(repliesFile(t, r))); err != nil || !fi.IsDir() {
		t.Fatalf("no folder for the replies: %v", err)
	}
}

// TAS-175: a reply that GitHub refuses, or a file that Loam cannot read, does not stop the run. The event says why, a
// refusal is a warning, and the file stays. The thread stays open, so the next review try sends it again.
func TestRunTickKeepsTheRepliesThatItCouldNotPost(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	state := reviewState(w.Branch, head, "CHANGES_REQUESTED", "[]", "["+threadT1+"]")
	setGitHub(t, state)
	tick(t) // sends the review
	writeReplies(t, r, `{"threads": [{"id": "T1", "body": "Done.", "resolve": true}]}`)
	passGate(t, s, r) // no commit: GitHub shows the head already
	setGitHub(t, strings.Replace(state, `"refs":`, `"thread_refusals": {"T1": "Pull request review thread is locked"}, "refs":`, 1))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].ReviewTries != 2 {
		t.Fatalf("%+v", got)
	}
	path := repliesFile(t, r)
	want := "Loam posted no review replies on #1. 1 post failed, the first with: could not reply on the review thread T1: " +
		"Pull request review thread is locked. The replies stay in " + path
	if e := events(t, s, r.ID, "review"); len(e) < 2 || e[1] != want {
		t.Fatalf("review events %q", e)
	}
	if len(got.Warnings) != 1 || got.Warnings[0] != "Say hi: "+want {
		t.Fatalf("warnings %q", got.Warnings)
	}

	// The second review try removed the file. A file that is not JSON gives an event, and the run is Ready.
	writeReplies(t, r, "Done, all of it.")
	passGate(t, s, r)
	setGitHub(t, state)
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", got)
	}
	e := events(t, s, r.ID, "review")
	if !strings.HasPrefix(e[len(e)-1], "Loam posted no review replies on #1: the file "+path+": it is not JSON in the format of the prompt") {
		t.Fatalf("review events %q", e)
	}
	if b, err := os.ReadFile(path); err != nil || string(b) != "Done, all of it." {
		t.Fatalf("the file: %q, %v", b, err)
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
		!strings.Contains(p[0], "Commit all the fixes in one commit") || !strings.Contains(p[0], "make no commit") ||
		!strings.Contains(p[0], `{"comment": "<comment>"}`) || strings.Contains(p[0], `"threads"`) {
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
	if e := events(t, s, r.ID, "review"); e[len(e)-1] != "The session wrote no review replies, so Loam posted none on #1" {
		t.Fatalf("review events %q", e)
	}
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
		"bob, who cannot push to the repo, wrote a comment", repliesFile(t, r), "Do not run gh",
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
