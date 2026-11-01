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

// A Critical or Major finding in the body of a review that only comments sends the run back, for any review app. A
// run never waits for a review app.

// botReview is a review by a review app of the commit head that only comments, with the body. The body of a review
// is JSON text here.
func botReview(id, head, body string) string {
	return fmt.Sprintf(`{"id": %q, "state": "COMMENTED", "body": %q, "url": "https://github.com/example/widgets/pull/1#pullrequestreview-9",
  "authorCanPushToRepository": true, "commit": {"oid": %q}, "author": {"__typename": "Bot", "login": "reviewbot"}}`, id, body, head)
}

// botState is reviewState with no threads, and with the last reviews of PR #1, as a JSON list of GitHub nodes.
func botState(branch, head, decision, changeRequests, reviews string) string {
	return strings.Replace(reviewState(branch, head, decision, changeRequests, "[]"), `"reviewThreads":`,
		fmt.Sprintf(`"reviews": {"nodes": %s}, "reviewThreads":`, reviews), 1)
}

// withSkippedCheck adds a check with the name that GitHub skipped to the checks of PR #1 of the state.
func withSkippedCheck(state, name string) string {
	return strings.Replace(state, `"contexts": {"totalCount": 1, "nodes": [`,
		fmt.Sprintf(`"contexts": {"totalCount": 2, "nodes": [{"__typename": "CheckRun", "name": %q, "status": "COMPLETED", "conclusion": "SKIPPED", "isRequired": false}, `, name), 1)
}

const (
	majorBody = "**Actionable comments posted: 0**\n\n<details>\n<summary>⚠️ Outside diff range comments (1)</summary>\n\n" +
		"`hello.txt`: _⚠️ Potential issue_ | _🟠 Major_\n\n**The greeting drops the name.**\n</details>"
	// majorIconBody is the icon form that a review app can write: an icon in a <picture>, then the severity.
	majorIconBody = "**Actionable comments posted: 0**\n\n<details>\n<summary>⚠️ Outside diff range comments (1)</summary>\n\n" +
		"`213-214`: **<picture><img src=\"https://example.com/icons/major-16.svg\" " +
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
	setGitHub(t, botState(w.Branch, head, "REVIEW_REQUIRED", "[]", "["+botReview("PRR_major", head, majorBody)+", "+reply+"]"))
	got := tick(t)
	note := "A review of #1 has a Critical or Major finding. Loam sent back 1 review (review try 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note || got.Runs[0].ReviewTries != 1 {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "review"); !slices.Equal(e, []string{"A review of #1 has a Critical or Major finding: 1 review"}) {
		t.Fatalf("review events %q", e)
	}
	p := resumes(t)
	if len(p) != 1 || !strings.Contains(p[0], "## Review by reviewbot") || !strings.Contains(p[0], "> **The greeting drops the name.**") ||
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
	person := strings.Replace(botReview("PRR_person", head, majorBody), `{"__typename": "Bot", "login": "reviewbot"}`, `{"__typename": "User", "login": "alice"}`, 1)
	reviews := "[" + botReview("PRR_old", "1111111111111111111111111111111111111111", majorBody) + ", " + person + ", " + botReview("PRR_minor", head, minorBody) + "]"
	setGitHub(t, botState(w.Branch, head, "REVIEW_REQUIRED", "[]", reviews))
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
	setGitHub(t, botState(w.Branch, head, "CHANGES_REQUESTED", "["+older+"]", "["+botReview("PRR_major", head, majorIconBody)+"]"))
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

// GitHub counts a skipped check as passed, whatever its name, so the run is Ready on the first tick after CI passed.
func TestRunTickMakesARunReadyWithNoWaitWhenACheckIsSkipped(t *testing.T) {
	for _, name := range []string{"reviewbot", "Code review", "lint / swiftformat"} {
		t.Run(name, func(t *testing.T) {
			s, r, w := shipRun(t, "3")
			tick(t)
			head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
			setGitHub(t, withSkippedCheck(ciState(w.Branch, head, "SUCCESS"), name))
			if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 2 of 2 checks" {
				t.Fatalf("%+v", got)
			}
			if e := events(t, s, r.ID, "review"); len(e) != 0 {
				t.Fatalf("review events %q", e)
			}
		})
	}
}
