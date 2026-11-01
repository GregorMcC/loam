package github_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

var widgets = github.Repo{Owner: "example", Name: "widgets"}

func TestParseRepo(t *testing.T) {
	for url, want := range map[string]bool{
		"https://github.com/example/widgets":       true,
		"https://GitHub.com/example/widgets":       true,
		"https://gitlab.com/example/widgets":       false,
		"https://github.example.com/example/tools": false,
		"https://github.com/example":               false,
		"https://github.com/example/widgets/more":  false,
		"not a url": false,
	} {
		r, ok := github.ParseRepo(url)
		if ok != want || (ok && r != widgets) {
			t.Errorf("%s: got %+v %v", url, r, ok)
		}
	}
}

// Each branch name is escaped for a URL path, and keeps its slashes.
func TestCompareURL(t *testing.T) {
	for _, c := range []struct{ base, head, want string }{
		{"main", "fix-login", "https://github.com/example/widgets/compare/main...fix-login"},
		{"", "feature/search", "https://github.com/example/widgets/compare/feature/search"},
		{"main", "fix#12", "https://github.com/example/widgets/compare/main...fix%2312"},
		{"", "fix#12", "https://github.com/example/widgets/compare/fix%2312"},
		{"release/2.0", "feature/50%-faster", "https://github.com/example/widgets/compare/release/2.0...feature/50%25-faster"},
		{"main", "a;b,c?d", "https://github.com/example/widgets/compare/main...a%3Bb%2Cc%3Fd"},
	} {
		if got := widgets.CompareURL(c.base, c.head); got != c.want {
			t.Errorf("got %s, want %s", got, c.want)
		}
	}
}

func TestFindUsesLoamGH(t *testing.T) {
	gh := filepath.Join(t.TempDir(), "gh")
	if err := os.WriteFile(gh, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_GH", gh)
	if got, err := github.Find(); err != nil || got != gh {
		t.Fatalf("got %q, %v", got, err)
	}
	t.Setenv("LOAM_GH", filepath.Join(t.TempDir(), "missing"))
	if _, err := github.Find(); !errors.Is(err, github.ErrGHMissing) {
		t.Fatalf("%v", err)
	}
}

// state is a made-up GitHub repo. fix-login has a merged PR and a newer open
// one. fork-only has only a PR from a fork. old-work has a merged PR, and
// GitHub deleted its branch. The open PR has 120 checks: the answer holds the
// first page of them.
const state = `{
  "refs": ["fix-login", "fork-only"],
  "pulls": [
    {"number": 12, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/12",
     "state": "MERGED", "isDraft": false, "isCrossRepository": false, "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN",
     "reviewDecision": "APPROVED", "isInMergeQueue": false, "mergeQueueEntry": null, "baseRefName": "main",
     "headRefName": "fix-login", "headRefOid": "1111111111111111111111111111111111111111",
     "mergedAt": "2026-01-01T10:00:00Z", "closedAt": "2026-01-01T10:00:00Z", "commits": {"totalCount": 2}},
    {"number": 15, "title": "Fix the login form again", "url": "https://github.com/example/widgets/pull/15",
     "state": "OPEN", "isDraft": false, "isCrossRepository": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND",
     "reviewDecision": "REVIEW_REQUIRED", "isInMergeQueue": true, "mergeQueueEntry": {"position": 2}, "baseRefName": "main",
     "headRefName": "fix-login", "headRefOid": "2222222222222222222222222222222222222222",
     "mergedAt": null, "closedAt": null, "commits": {"totalCount": 3}},
    {"number": 16, "title": "From a fork", "url": "https://github.com/example/widgets/pull/16",
     "state": "OPEN", "isDraft": false, "isCrossRepository": true, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
     "reviewDecision": null, "isInMergeQueue": false, "mergeQueueEntry": null, "baseRefName": "main",
     "headRefName": "fork-only", "headRefOid": "3333333333333333333333333333333333333333",
     "mergedAt": null, "closedAt": null, "commits": {"totalCount": 1}},
    {"number": 9, "title": "Old work", "url": "https://github.com/example/widgets/pull/9",
     "state": "MERGED", "isDraft": false, "isCrossRepository": false, "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN",
     "reviewDecision": null, "isInMergeQueue": false, "mergeQueueEntry": null, "baseRefName": "main",
     "headRefName": "old-work", "headRefOid": "4444444444444444444444444444444444444444",
     "mergedAt": "2026-01-01T09:00:00Z", "closedAt": "2026-01-01T09:00:00Z", "commits": {"totalCount": 1}}
  ],
  "details": {
    "15": {
      "baseRef": {"compare": {"behindBy": 3}},
      "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}, {"state": "COMMENTED"},
        {"id": "PRR_1", "state": "CHANGES_REQUESTED", "body": "Two fixes, please.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-1",
         "author": {"login": "alice"}},
        {"id": "PRR_2", "state": "CHANGES_REQUESTED", "body": "", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-2", "author": null,
         "commit": {"oid": "1111111111111111111111111111111111111111"}}]},
      "reviews": {"nodes": [
        {"id": "PRR_3", "state": "COMMENTED", "body": "Outside diff: Major.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-3",
         "authorCanPushToRepository": true, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "Bot", "login": "reviewbot"}},
        {"id": "PRR_4", "state": "COMMENTED", "body": "", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-4",
         "authorCanPushToRepository": true, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "Bot", "login": "reviewbot"}},
        {"id": "PRR_5", "state": "COMMENTED", "body": "An old head.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-5",
         "authorCanPushToRepository": true, "commit": {"oid": "1111111111111111111111111111111111111111"}, "author": {"__typename": "Bot", "login": "otherbot"}},
        {"id": "PRR_6", "state": "COMMENTED", "body": "By a person.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-6",
         "authorCanPushToRepository": true, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "User", "login": "alice"}},
        {"id": "PRR_7", "state": "COMMENTED", "body": "No push access.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-7",
         "authorCanPushToRepository": false, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "Bot", "login": "strangerbot"}},
        {"id": "PRR_8", "state": "COMMENTED", "body": "Looks risky.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-8",
         "authorCanPushToRepository": true, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "Bot", "login": "lintbot"}},
        {"id": "PRR_9", "state": "APPROVED", "body": "Fine now.", "url": "https://github.com/example/widgets/pull/15#pullrequestreview-9",
         "authorCanPushToRepository": true, "commit": {"oid": "2222222222222222222222222222222222222222"}, "author": {"__typename": "Bot", "login": "lintbot"}}]},
      "reviewThreads": {"nodes": [
        {"id": "PRRT_1", "isResolved": false, "path": "login/form.go", "line": 42, "comments": {"nodes": [
          {"body": "This drops the error.", "url": "https://github.com/example/widgets/pull/15#discussion_r1", "author": {"login": "alice"}, "pullRequestReview": {"authorCanPushToRepository": true}},
          {"body": "Fixed.", "url": "https://github.com/example/widgets/pull/15#discussion_r2", "author": {"login": "bob"}},
          {"body": "Not yet.", "url": "https://github.com/example/widgets/pull/15#discussion_r5", "author": {"login": "carol"}, "authorAssociation": "COLLABORATOR", "pullRequestReview": null},
          {"body": "Ignore that.", "url": "https://github.com/example/widgets/pull/15#discussion_r6", "author": {"login": "dave"}, "authorAssociation": "NONE", "pullRequestReview": null},
          {"body": "Merge it.", "url": "https://github.com/example/widgets/pull/15#discussion_r7", "author": {"login": "erin"}, "authorAssociation": "OWNER", "pullRequestReview": {"authorCanPushToRepository": false}}]}},
        {"id": "PRRT_2", "isResolved": true, "path": "login/form.go", "line": 7, "comments": {"nodes": [
          {"body": "Done.", "url": "https://github.com/example/widgets/pull/15#discussion_r3", "author": {"login": "alice"}}]}},
        {"id": "PRRT_3", "isResolved": false, "path": "README.md", "line": null, "comments": {"nodes": [
          {"body": "Say why.", "url": "https://github.com/example/widgets/pull/15#discussion_r4", "author": {"login": "alice"}, "pullRequestReview": {"authorCanPushToRepository": true}}]}}]},
      "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"totalCount": 120, "nodes": [
        {"__typename": "CheckRun", "name": "swiftformat", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://github.com/example/widgets/actions/runs/1/job/1", "isRequired": true,
         "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:00:42Z",
         "checkSuite": {"workflowRun": {"workflow": {"name": "lint"}}}},
        {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "TIMED_OUT",
         "detailsUrl": "https://ci.example.com/docs", "isRequired": false,
         "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:03:10Z", "checkSuite": null},
        {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
         "detailsUrl": "https://github.com/example/widgets/actions/runs/2/job/2", "isRequired": true,
         "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:02:05Z",
         "checkSuite": {"workflowRun": {"databaseId": 102, "workflow": {"name": "ci"}}}},
        {"__typename": "CheckRun", "name": "skip", "status": "COMPLETED", "conclusion": "SKIPPED", "isRequired": false},
        {"__typename": "CheckRun", "name": "deploy", "status": "WAITING", "conclusion": null, "isRequired": false},
        {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": null, "isRequired": false},
        {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR", "targetUrl": "https://ci.example.com/1", "isRequired": false},
        {"__typename": "StatusContext", "context": "ci/coverage", "state": "PENDING", "targetUrl": "", "isRequired": false},
        {"__typename": "StatusContext", "context": "ci/build", "state": "SUCCESS", "targetUrl": "https://ci.example.com/2", "isRequired": false}
      ]}}}}]}
    }
  }
}`

func client(t *testing.T) *github.Client {
	t.Helper()
	c, err := github.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestFetchReadsEachBranch(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, state)
	got, err := client(t).Fetch(context.Background(), widgets, []string{"fix-login", "fork-only", "old-work", "local-only"})
	if err != nil {
		t.Fatal(err)
	}

	// Two PRs on one head: the open one wins over the merged one.
	b := got["fix-login"]
	pr := b.PR
	if !b.Pushed || pr == nil || pr.Number != 15 || pr.State != "OPEN" || pr.Title != "Fix the login form again" ||
		pr.URL != "https://github.com/example/widgets/pull/15" || pr.Base != "main" || pr.Head != "fix-login" ||
		pr.HeadOID != "2222222222222222222222222222222222222222" || pr.Commits != 3 {
		t.Fatalf("fix-login: %+v %+v", b, pr)
	}
	if pr.Mergeable != "MERGEABLE" || pr.MergeState != "BEHIND" || pr.ReviewDecision != "REVIEW_REQUIRED" ||
		!pr.InMergeQueue || pr.QueuePosition != 2 || pr.MergedAt != nil || pr.ClosedAt != nil {
		t.Fatalf("fix-login: %+v", pr)
	}
	if pr.BehindBase != 3 || pr.Approvals != 1 || pr.Comments != 2 {
		t.Fatalf("behind %d, approvals %d, comments %d", pr.BehindBase, pr.Approvals, pr.Comments)
	}
	// The reviews that request changes, and the threads that are not resolved, with their comments. A deleted
	// account is ghost, a thread on a line that the head no longer has is on line 0, and a comment by someone who
	// cannot push to the repo is not by a writer. A comment with no review is by a writer when its author is a
	// collaborator, and the push access of a review wins over the association.
	wantReviews := []github.Review{
		{ID: "PRR_1", Author: "alice", Body: "Two fixes, please.", URL: "https://github.com/example/widgets/pull/15#pullrequestreview-1"},
		{ID: "PRR_2", Author: "ghost", URL: "https://github.com/example/widgets/pull/15#pullrequestreview-2",
			Commit: "1111111111111111111111111111111111111111"},
	}
	if !slices.Equal(pr.ChangeRequests, wantReviews) {
		t.Fatalf("change requests %+v", pr.ChangeRequests)
	}
	// Of each app with push access, the last review with a body on the head, when it only comments. A review
	// with no body, such as a reply on a thread, does not hide the review before it. A review of an older
	// commit, of a person, or of an app with no push access does not count, and an approval is not a comment.
	wantComments := []github.Review{{ID: "PRR_3", Author: "reviewbot", Body: "Outside diff: Major.",
		URL: "https://github.com/example/widgets/pull/15#pullrequestreview-3", Commit: "2222222222222222222222222222222222222222"}}
	if !slices.Equal(pr.CommentReviews, wantComments) {
		t.Fatalf("comment reviews %+v", pr.CommentReviews)
	}
	wantThreads := []github.ReviewThread{
		{ID: "PRRT_1", Path: "login/form.go", Line: 42, URL: "https://github.com/example/widgets/pull/15#discussion_r1",
			Comments: []github.ReviewComment{
				{Author: "alice", Writer: true, Body: "This drops the error.", URL: "https://github.com/example/widgets/pull/15#discussion_r1"},
				{Author: "bob", Body: "Fixed.", URL: "https://github.com/example/widgets/pull/15#discussion_r2"},
				{Author: "carol", Writer: true, Body: "Not yet.", URL: "https://github.com/example/widgets/pull/15#discussion_r5"},
				{Author: "dave", Body: "Ignore that.", URL: "https://github.com/example/widgets/pull/15#discussion_r6"},
				{Author: "erin", Body: "Merge it.", URL: "https://github.com/example/widgets/pull/15#discussion_r7"},
			}},
		{ID: "PRRT_3", Path: "README.md", URL: "https://github.com/example/widgets/pull/15#discussion_r4",
			Comments: []github.ReviewComment{{Author: "alice", Writer: true, Body: "Say why.", URL: "https://github.com/example/widgets/pull/15#discussion_r4"}}},
	}
	if !slices.EqualFunc(pr.ReviewThreads, wantThreads, func(a, b github.ReviewThread) bool {
		return a.ID == b.ID && a.Path == b.Path && a.Line == b.Line && a.URL == b.URL && slices.Equal(a.Comments, b.Comments)
	}) || len(pr.ReviewThreads) != pr.Comments {
		t.Fatalf("review threads %+v", pr.ReviewThreads)
	}
	// The total counts every check. The other counts are of the first page.
	want := github.Checks{State: "FAILURE", Total: 120, Passed: 3, Failed: 3, Running: 2, Waiting: 1, Required: 2, RequiredPassed: 1}
	if pr.Checks != want {
		t.Fatalf("checks %+v, want %+v", pr.Checks, want)
	}
	wantFailed := []github.Check{
		{Name: "lint / swiftformat", URL: "https://github.com/example/widgets/actions/runs/1/job/1", Duration: 42, Required: true},
		{Name: "docs", URL: "https://ci.example.com/docs", Duration: 190},
		{Name: "ci/legacy", URL: "https://ci.example.com/1"},
	}
	if !slices.Equal(pr.FailedChecks, wantFailed) {
		t.Fatalf("failed checks %+v", pr.FailedChecks)
	}
	// A skipped check counts as passed, so the list has as many checks as checks.passed. The order is
	// the order of GitHub, and a status context is a check too.
	wantPassed := []github.Check{
		{Name: "ci / test", URL: "https://github.com/example/widgets/actions/runs/2/job/2", Duration: 125, Required: true, RunID: 102},
		{Name: "skip", Skipped: true},
		{Name: "ci/build", URL: "https://ci.example.com/2"},
	}
	if !slices.Equal(pr.PassedChecks, wantPassed) || len(pr.PassedChecks) != pr.Checks.Passed {
		t.Fatalf("passed checks %+v", pr.PassedChecks)
	}

	// A PR from a fork does not count: the branch is pushed, with no PR.
	if b := got["fork-only"]; b.PR != nil || !b.Pushed {
		t.Fatalf("fork-only: %+v", b)
	}
	// A merged PR still shows after GitHub deletes its branch.
	if b := got["old-work"]; b.Pushed || b.PR == nil || b.PR.Number != 9 || b.PR.State != "MERGED" ||
		b.PR.MergedAt == nil || !b.PR.MergedAt.Equal(time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)) ||
		b.PR.FailedChecks == nil || b.PR.PassedChecks == nil || b.PR.ChangeRequests == nil || b.PR.ReviewThreads == nil ||
		b.PR.CommentReviews == nil {
		t.Fatalf("old-work: %+v", b)
	}
	if b := got["local-only"]; b.PR != nil || b.Pushed {
		t.Fatalf("local-only: %+v", b)
	}

	// Two queries: one for every branch, one for the open PR only.
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 2 {
		t.Fatalf("%d gh calls", len(calls))
	}
	if !slices.Equal(calls[0].Args, []string{"api", "graphql", "--hostname", "github.com", "--input", "-"}) {
		t.Fatalf("args %v", calls[0].Args)
	}
	if v := calls[0].Variables; v["owner"] != "example" || v["name"] != "widgets" || v["h3"] != "local-only" || v["q3"] != "refs/heads/local-only" {
		t.Fatalf("first query variables %v", v)
	}
	if v := calls[1].Variables; v["n0"] != float64(15) || v["h0"] != "fix-login" || v["n1"] != nil {
		t.Fatalf("second query variables %v", v)
	}
}

func TestFetchMakesOneQueryWithNoOpenPR(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, state)
	got, err := client(t).Fetch(context.Background(), widgets, []string{"old-work"})
	if err != nil || got["old-work"].PR == nil {
		t.Fatalf("%+v %v", got, err)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 1 {
		t.Fatalf("%d gh calls", n)
	}
}

// A PR with no checks has empty lists of checks, never null, for an open PR
// and for a merged one.
func TestFetchGivesEmptyListsOfChecksNotNull(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{"refs": ["fix-login"], "pulls": [
	  {"number": 15, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/15",
	   "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "baseRefName": "main",
	   "headRefName": "fix-login", "headRefOid": "2222222222222222222222222222222222222222", "commits": {"totalCount": 1}},
	  {"number": 9, "title": "Old work", "url": "https://github.com/example/widgets/pull/9",
	   "state": "MERGED", "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "baseRefName": "main",
	   "headRefName": "old-work", "headRefOid": "4444444444444444444444444444444444444444", "commits": {"totalCount": 1}}
	], "details": {"15": {}}}`)
	got, err := client(t).Fetch(context.Background(), widgets, []string{"fix-login", "old-work"})
	if err != nil {
		t.Fatal(err)
	}
	for _, branch := range []string{"fix-login", "old-work"} {
		b, err := json.Marshal(got[branch].PR)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), `"failed_checks":[]`) || !strings.Contains(string(b), `"passed_checks":[]`) ||
			!strings.Contains(string(b), `"comment_reviews":[]`) {
			t.Errorf("%s: %s", branch, b)
		}
	}
}

// Each failure of gh maps to one error. The fake gh prints what gh prints
// for each one.
func TestFetchErrors(t *testing.T) {
	for fail, want := range map[string]error{
		"signed_out":           github.ErrSignedOut,
		"bad_credentials":      github.ErrSignedOut,
		"rate_limited":         github.ErrRateLimited,
		"secondary_rate_limit": github.ErrRateLimited,
		"forbidden":            github.ErrNoAccess,
		"not_found":            github.ErrNoAccess,
		"no_repo":              github.ErrNoAccess,
		"saml":                 github.ErrNoAccess,
		"sso":                  github.ErrNoAccess,
		"offline":              github.ErrOffline,
	} {
		t.Run(fail, func(t *testing.T) {
			testutil.Home(t)
			testutil.FakeGH(t, state)
			t.Setenv("LOAM_FAKE_GH_FAIL", fail)
			if _, err := client(t).Fetch(context.Background(), widgets, []string{"fix-login"}); !errors.Is(err, want) {
				t.Fatalf("got %v, want %v", err, want)
			}
		})
	}
}

// A gh call that does not end in time counts as offline.
func TestFetchTimesOut(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, state)
	t.Setenv("LOAM_FAKE_GH_FAIL", "hang")
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if _, err := client(t).Fetch(ctx, widgets, []string{"fix-login"}); !errors.Is(err, github.ErrOffline) {
		t.Fatalf("%v", err)
	}
}

func TestNewClientWithNoGH(t *testing.T) {
	testutil.Home(t)
	if _, err := github.NewClient(); !errors.Is(err, github.ErrGHMissing) {
		t.Fatalf("%v", err)
	}
}

// When the second query fails, the first one still counts: each branch with
// no PR, or with a merged or closed PR, needs nothing from the second. A
// branch with an open PR is not in the result.
func TestFetchKeepsTheFirstQueryWhenTheSecondFails(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, state)
	t.Setenv("LOAM_FAKE_GH_FAIL", "rate_limited")
	t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "2")
	got, err := client(t).Fetch(context.Background(), widgets, []string{"fix-login", "fork-only", "old-work", "local-only"})
	if !errors.Is(err, github.ErrRateLimited) {
		t.Fatalf("%v", err)
	}
	if _, ok := got["fix-login"]; ok || len(got) != 3 {
		t.Fatalf("%+v", got)
	}
	if b := got["old-work"]; b.PR == nil || b.PR.State != "MERGED" {
		t.Fatalf("old-work: %+v", b)
	}
	if b := got["fork-only"]; b.PR != nil || !b.Pushed {
		t.Fatalf("fork-only: %+v", b)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 2 {
		t.Fatalf("%d gh calls", n)
	}
}

// A cancelled refresh stops gh at once. It is not a GitHub failure.
func TestFetchStopsWhenTheContextIsCancelled(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, state)
	t.Setenv("LOAM_FAKE_GH_FAIL", "hang")
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(200*time.Millisecond, cancel)
	start := time.Now()
	_, err := client(t).Fetch(ctx, widgets, []string{"fix-login"})
	if !errors.Is(err, context.Canceled) || errors.Is(err, github.ErrOffline) {
		t.Fatalf("%v", err)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("gh ran for %v after the cancel", d)
	}
}
