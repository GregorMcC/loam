package cli

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-221: a Critical or Major finding in the body of a review that only comments sends the run back, and a run
// whose head CodeRabbit did not review waits for it before it is Ready.

// botReview is a review by CodeRabbit of the commit head that only comments, with the body. The body of a review
// is JSON text here.
func botReview(id, head, body string) string {
	return fmt.Sprintf(`{"id": %q, "state": "COMMENTED", "body": %q, "url": "https://github.com/example/widgets/pull/1#pullrequestreview-9",
  "authorCanPushToRepository": true, "commit": {"oid": %q}, "author": {"__typename": "Bot", "login": "coderabbitai"}}`, id, body, head)
}

// botComment is a comment by CodeRabbit on PR #1, not on a line.
func botComment(body, at string) string {
	return fmt.Sprintf(`{"body": %q, "url": "https://github.com/example/widgets/pull/1#issuecomment-1", "updatedAt": %q,
  "author": {"__typename": "Bot", "login": "coderabbitai"}}`, body, at)
}

// botState is reviewState with no threads, and with the last reviews and the last comments of PR #1, as JSON
// lists of GitHub nodes.
func botState(branch, head, decision, changeRequests, reviews, comments string) string {
	return strings.Replace(reviewState(branch, head, decision, changeRequests, "[]"), `"reviewThreads":`,
		fmt.Sprintf(`"reviews": {"nodes": %s}, "comments": {"nodes": %s}, "reviewThreads":`, reviews, comments), 1)
}

// withSkippedCodeRabbit adds a CodeRabbit check that GitHub skipped to the checks of PR #1 of the state.
func withSkippedCodeRabbit(state string) string {
	return strings.Replace(state, `"contexts": {"totalCount": 1, "nodes": [`,
		`"contexts": {"totalCount": 2, "nodes": [{"__typename": "CheckRun", "name": "CodeRabbit", "status": "COMPLETED", "conclusion": "SKIPPED", "isRequired": false}, `, 1)
}

const (
	majorBody = "**Actionable comments posted: 0**\n\n<details>\n<summary>⚠️ Outside diff range comments (1)</summary>\n\n" +
		"`hello.txt`: _⚠️ Potential issue_ | _🟠 Major_\n\n**The greeting drops the name.**\n</details>"
	// majorIconBody is the form of CodeRabbit on this repo, as in its review of #95: an icon in a <picture>, then
	// the severity.
	majorIconBody = "**Actionable comments posted: 0**\n\n<details>\n<summary>⚠️ Outside diff range comments (1)</summary>\n\n" +
		"`213-214`: **<picture><img src=\"https://storage.googleapis.com/coderabbit_public_assets/review-comment-icons-v1/major-16.svg\" " +
		"width=\"16\" height=\"16\" align=\"absmiddle\" alt=\"\"></picture> Major** · **Data Integrity & Integration** · **Quick win**\n\n" +
		"**The greeting drops the name.**\n</details>"
	minorBody = "**Actionable comments posted: 0**\n\n<details>\n<summary>🧹 Nitpick comments (1)</summary>\n\n" +
		"`hello.txt`: _🛠️ Refactor suggestion_ | _🟡 Minor_\n\n**Critical section of the greeting: say hi with a capital letter.**\n</details>"
)

func TestRunTickSendsAMajorFindingInTheBodyOfACommentReviewBack(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	// A reply of the bot on a thread after its review is a review with no body, and it does not hide the review.
	reply := botReview("PRR_reply", head, "")
	setGitHub(t, botState(w.Branch, head, "REVIEW_REQUIRED", "[]", "["+botReview("PRR_major", head, majorBody)+", "+reply+"]", "[]"))
	got := tick(t)
	note := "A review of #1 has a Critical or Major finding. Loam sent back 1 review (review try 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note || got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{"A review of #1 has a Critical or Major finding: 1 review"}) {
		t.Fatalf("review events %q", e)
	}
	p := resumes(t)
	if len(p) != 1 || !strings.Contains(p[0], "## Review by coderabbitai") || !strings.Contains(p[0], "> **The greeting drops the name.**") ||
		!strings.Contains(p[0], "Fix each Critical or Major point") || !strings.Contains(p[0], `{"comment": "<comment>"}`) {
		t.Fatalf("prompts %q", p)
	}
	// The session makes no commit: Loam sent the review, so the run is Ready.
	passGate(t, s, r)
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("%+v", got)
	}
	if n := len(resumes(t)); n != 1 {
		t.Fatalf("%d prompts", n)
	}
}

// A body with only Minor or Trivial findings, a Major finding on an older commit, and a Major finding of a person
// who only comments do not send the run back.
func TestRunTickMakesARunReadyWithAMinorFindingInTheBodyOfACommentReview(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	person := strings.Replace(botReview("PRR_person", head, majorBody), `{"__typename": "Bot", "login": "coderabbitai"}`, `{"__typename": "User", "login": "alice"}`, 1)
	reviews := "[" + botReview("PRR_old", "1111111111111111111111111111111111111111", majorBody) + ", " + person + ", " + botReview("PRR_minor", head, minorBody) + "]"
	setGitHub(t, botState(w.Branch, head, "REVIEW_REQUIRED", "[]", reviews, "[]"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("%+v", got)
	}
	if p := resumes(t); len(p) != 0 {
		t.Fatalf("prompts %q", p)
	}
}

// The case of #95: an older review requested changes and went back, and the bot's review of the head only comments,
// with a Major finding outside the diff. The Ready run goes back to Shipping, and send-review counts the review.
func TestRunSendReviewSendsAMajorFindingInTheBodyOfACommentReview(t *testing.T) {
	s, r, w := readyRun(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	older := strings.Replace(reviewR1, `"author"`, `"commit": {"oid": "1111111111111111111111111111111111111111"}, "author"`, 1)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.ReviewsSent = []string{"R1"}; return nil }); err != nil {
		t.Fatal(err)
	}
	setGitHub(t, botState(w.Branch, head, "CHANGES_REQUESTED", "["+older+"]", "["+botReview("PRR_major", head, majorIconBody)+"]", "[]"))
	out, code := loam(t, "run", "send-review", r.ID, "--dry-run", "--json")
	var plan run.ReviewResult
	if err := json.Unmarshal([]byte(out), &plan); err != nil || code != 0 || plan.Threads != 0 || plan.Reviews != 1 ||
		len(plan.PR.CommentReviews) != 1 {
		t.Fatalf("exit %d, %v: %s", code, err, out)
	}
	got := tick(t)
	note := "Changes are requested on #1 after it was ready. Loam sends the review back"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
	if got = tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if p := resumes(t); len(p) != 1 || !strings.Contains(p[0], "> **The greeting drops the name.**") || strings.Contains(p[0], "Two things before this merges.") {
		t.Fatalf("prompts %q", p)
	}
}

// GitHub keeps CHANGES_REQUESTED until the reviewer reviews again, so the Ready note says when only a review of an
// older commit requests changes.
func TestRunTickSaysWhenOnlyAReviewOfAnOlderCommitRequestsChanges(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	older := strings.Replace(reviewR1, `"author"`, `"commit": {"oid": "1111111111111111111111111111111111111111"}, "author"`, 1)
	setGitHub(t, reviewState(w.Branch, head, "CHANGES_REQUESTED", "["+older+"]", "[]"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning {
		t.Fatalf("%+v", got)
	}
	passGate(t, s, r)
	note := "CI passed on #1: 1 of 1 checks. Changes are requested on #1 only by a review of an older commit, by alice"
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
}

// A run whose head CodeRabbit did not review waits in Shipping, with one review event that says why. After the wait
// it is Ready, and the note says that CodeRabbit did not review the head.
func TestRunTickWaitsForCodeRabbitWhenItDidNotReviewTheHead(t *testing.T) {
	for _, c := range []struct {
		name, checks, comments, why string
	}{
		{"skipped", "skipped", "[]", "its check was skipped"},
		{"paused", "", "[" + botComment("> [!NOTE]\n> ## Reviews paused\n>\n> Use `@coderabbitai resume`.", "2026-01-01T10:00:00Z") + "]", "its reviews are paused"},
		{"limit", "", "[" + botComment("> [!WARNING]\n> ## Rate limit exceeded\n>\n> Wait 12 minutes.", "2026-01-01T10:00:00Z") + "]", "it reached its review limit"},
		// The summary comment, which CodeRabbit wrote first and edited last, is its last word.
		{"edited", "", "[" + botComment("## Walkthrough\n\n> [!NOTE]\n> ## Reviews paused", "2026-01-01T11:00:00Z") + ", " +
			botComment("A reply.", "2026-01-01T10:00:00Z") + "]", "its reviews are paused"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s, r, w := shipRun(t, "3")
			tick(t)
			head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
			state := botState(w.Branch, head, "REVIEW_REQUIRED", "[]", "[]", c.comments)
			total := 1
			if c.checks == "skipped" {
				state, total = withSkippedCodeRabbit(state), 2
			}
			setGitHub(t, state)
			wait := fmt.Sprintf("CodeRabbit did not review %s, the head of #1: %s. Loam waits up to 30 minutes for its review", head[:7], c.why)
			if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Note != wait {
				t.Fatalf("%+v", got)
			}
			if got := tick(t); len(got.Runs) != 0 {
				t.Fatalf("a second tick: %+v", got)
			}
			if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{wait}) {
				t.Fatalf("review events %q", e)
			}
			if e := events(t, s, r.ID, "ci"); len(e) != 0 {
				t.Fatalf("ci events %q", e)
			}
			before := run.CodeRabbitWait
			run.CodeRabbitWait = time.Duration(0)
			t.Cleanup(func() { run.CodeRabbitWait = before })
			note := fmt.Sprintf("CI passed on #1: %d of %d checks. CodeRabbit did not review the head of #1: %s", total, total, c.why)
			if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != note {
				t.Fatalf("%+v", got)
			}
		})
	}
}

// CodeRabbit's last comment with no notice heading does not stop the run, also when its text is about a pause or
// a limit, and nor does a comment of a person. A review of CodeRabbit on the head stops no run, whatever its check
// and its comment say.
func TestRunTickDoesNotWaitForCodeRabbitThatSaysNothingOfAPause(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	person := strings.Replace(botComment("> ## Reviews paused", "2026-01-01T12:00:00Z"), `"Bot", "login": "coderabbitai"`, `"User", "login": "coderabbitfan"`, 1)
	comments := "[" + botComment("> ## Reviews paused", "2026-01-01T10:00:00Z") + ", " +
		botComment("## Walkthrough\nA run waits when reviews are paused or the review limit is reached.", "2026-01-01T11:00:00Z") + ", " + person + "]"
	setGitHub(t, botState(w.Branch, head, "REVIEW_REQUIRED", "[]", "[]", comments))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("%+v", got)
	}
}

func TestRunTickDoesNotWaitForCodeRabbitThatReviewedTheHead(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	state := botState(w.Branch, head, "REVIEW_REQUIRED", "[]", "["+botReview("PRR_minor", head, minorBody)+"]",
		"["+botComment("> ## Reviews paused", "2026-01-01T10:00:00Z")+"]")
	setGitHub(t, withSkippedCodeRabbit(state))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 2 of 2 checks" {
		t.Fatalf("%+v", got)
	}
}
