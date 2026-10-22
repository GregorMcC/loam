package github_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
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

func TestCompareURL(t *testing.T) {
	for _, c := range []struct{ base, head, want string }{
		{"main", "fix-login", "https://github.com/example/widgets/compare/main...fix-login"},
		{"", "feature/search", "https://github.com/example/widgets/compare/feature/search"},
		{"main", "fix#12", "https://github.com/example/widgets/compare/main...fix%2312"},
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
// GitHub deleted its branch.
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
      "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}, {"state": "COMMENTED"}]},
      "reviewThreads": {"nodes": [{"isResolved": false}, {"isResolved": true}, {"isResolved": false}]},
      "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"nodes": [
        {"__typename": "CheckRun", "name": "swiftformat", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://github.com/example/widgets/actions/runs/1/job/1", "isRequired": true,
         "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:00:42Z",
         "checkSuite": {"workflowRun": {"workflow": {"name": "lint"}}}},
        {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "TIMED_OUT",
         "detailsUrl": "https://ci.example.com/docs", "isRequired": false,
         "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:03:10Z", "checkSuite": null},
        {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true},
        {"__typename": "CheckRun", "name": "skip", "status": "COMPLETED", "conclusion": "SKIPPED", "isRequired": false},
        {"__typename": "CheckRun", "name": "deploy", "status": "WAITING", "conclusion": null, "isRequired": false},
        {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": null, "isRequired": false},
        {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR", "targetUrl": "https://ci.example.com/1", "isRequired": false},
        {"__typename": "StatusContext", "context": "ci/coverage", "state": "PENDING", "targetUrl": "", "isRequired": false}
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
	want := github.Checks{State: "FAILURE", Total: 8, Passed: 2, Failed: 3, Running: 2, Waiting: 1}
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

	// A PR from a fork does not count: the branch is pushed, with no PR.
	if b := got["fork-only"]; b.PR != nil || !b.Pushed {
		t.Fatalf("fork-only: %+v", b)
	}
	// A merged PR still shows after GitHub deletes its branch.
	if b := got["old-work"]; b.Pushed || b.PR == nil || b.PR.Number != 9 || b.PR.State != "MERGED" ||
		b.PR.MergedAt == nil || !b.PR.MergedAt.Equal(time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)) || b.PR.FailedChecks == nil {
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

func TestFetchErrors(t *testing.T) {
	for fail, want := range map[string]error{
		"signed_out":   github.ErrSignedOut,
		"rate_limited": github.ErrRateLimited,
		"offline":      github.ErrOffline,
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
