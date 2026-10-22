package github_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// landState is a made-up GitHub repo for the commands that act on GitHub.
// fix-login has an open PR. Its branch on GitHub is at the PR head. moved-on
// has a merged PR, and its branch on GitHub has a new commit. The repo
// allows squash and rebase, and the base branch has a merge queue.
const landState = `{
  "refs": ["fix-login", "moved-on"],
  "heads": {"moved-on": "5555555555555555555555555555555555555555"},
  "pulls": [
    {"number": 15, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/15",
     "state": "OPEN", "isCrossRepository": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
     "reviewDecision": "APPROVED", "baseRefName": "main", "headRefName": "fix-login",
     "headRefOid": "2222222222222222222222222222222222222222", "commits": {"totalCount": 1}},
    {"number": 9, "title": "Moved on", "url": "https://github.com/example/widgets/pull/9",
     "state": "MERGED", "isCrossRepository": false, "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN",
     "baseRefName": "main", "headRefName": "moved-on", "headRefOid": "4444444444444444444444444444444444444444",
     "mergedAt": "2026-01-01T09:00:00Z", "closedAt": "2026-01-01T09:00:00Z", "commits": {"totalCount": 1}}
  ],
  "details": {},
  "repository": {"mergeCommitAllowed": false, "squashMergeAllowed": true, "rebaseMergeAllowed": true,
    "viewerDefaultMergeMethod": "REBASE"},
  "merge_queue": true
}`

const prHead = "2222222222222222222222222222222222222222"

func lastArgs(t *testing.T) []string {
	t.Helper()
	calls := testutil.FakeGHCalls(t)
	if len(calls) == 0 {
		t.Fatal("gh did not run")
	}
	return calls[len(calls)-1].Args
}

func TestMergeSettings(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, landState)
	got, err := client(t).MergeSettings(context.Background(), widgets, 15)
	if err != nil {
		t.Fatal(err)
	}
	want := github.MergeSettings{Methods: []github.MergeMethod{github.MethodSquash, github.MethodRebase}, Default: github.MethodRebase, Queue: true}
	if !slices.Equal(got.Methods, want.Methods) || got.Default != want.Default || got.Queue != want.Queue {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 1 || !slices.Equal(calls[0].Args, []string{"api", "graphql", "--hostname", "github.com", "--input", "-"}) ||
		calls[0].Variables["number"] != float64(15) || calls[0].Variables["owner"] != "example" {
		t.Fatalf("%+v", calls)
	}
}

// The default of GitHub is the last method that you used in the repo. When
// the repo no longer allows it, the default is the first method it allows.
func TestMergeSettingsDefaultIsAnAllowedMethod(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, strings.Replace(landState, `"viewerDefaultMergeMethod": "REBASE"`, `"viewerDefaultMergeMethod": "MERGE"`, 1))
	got, err := client(t).MergeSettings(context.Background(), widgets, 15)
	if err != nil || got.Default != github.MethodSquash {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestMergeSettingsWithNoAllowedMethodFails(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, strings.Replace(strings.Replace(landState, `"squashMergeAllowed": true`, `"squashMergeAllowed": false`, 1),
		`"rebaseMergeAllowed": true`, `"rebaseMergeAllowed": false`, 1))
	if _, err := client(t).MergeSettings(context.Background(), widgets, 15); err == nil {
		t.Fatal("want an error")
	}
}

func TestMerge(t *testing.T) {
	for _, c := range []struct {
		name string
		o    github.MergeOptions
		want []string
	}{
		{"squash", github.MergeOptions{Method: github.MethodSquash, HeadOID: prHead},
			[]string{"pr", "merge", "15", "--repo", "github.com/example/widgets", "--squash", "--match-head-commit", prHead}},
		{"auto", github.MergeOptions{Method: github.MethodRebase, Auto: true, HeadOID: prHead},
			[]string{"pr", "merge", "15", "--repo", "github.com/example/widgets", "--rebase", "--auto", "--match-head-commit", prHead}},
		// A merge queue merges with its own method.
		{"queue", github.MergeOptions{HeadOID: prHead},
			[]string{"pr", "merge", "15", "--repo", "github.com/example/widgets", "--match-head-commit", prHead}},
	} {
		t.Run(c.name, func(t *testing.T) {
			testutil.Home(t)
			testutil.FakeGH(t, landState)
			if err := client(t).Merge(context.Background(), widgets, 15, c.o); err != nil {
				t.Fatal(err)
			}
			if got := lastArgs(t); !slices.Equal(got, c.want) {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// GitHub refuses a merge when the PR head is not the commit that Loam
// checked.
func TestMergeRefusesWhenTheHeadMoved(t *testing.T) {
	testutil.Home(t)
	file := testutil.FakeGH(t, landState)
	err := client(t).Merge(context.Background(), widgets, 15, github.MergeOptions{Method: github.MethodSquash,
		HeadOID: "3333333333333333333333333333333333333333"})
	if err == nil || !strings.Contains(err.Error(), "Head branch was modified") {
		t.Fatalf("%v", err)
	}
	if b, _ := os.ReadFile(file); !strings.Contains(string(b), `"OPEN"`) {
		t.Fatalf("the PR merged: %s", b)
	}
}

// A refused merge keeps the words of GitHub. It is not "offline".
func TestMergeKeepsTheMessageOfGitHub(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, landState)
	t.Setenv("LOAM_FAKE_GH_FAIL", "not_mergeable")
	err := client(t).Merge(context.Background(), widgets, 15, github.MergeOptions{Method: github.MethodSquash, HeadOID: prHead})
	if err == nil || errors.Is(err, github.ErrOffline) || !strings.Contains(err.Error(), "is not mergeable") ||
		strings.Contains(err.Error(), "--auto") {
		t.Fatalf("%v", err)
	}
}

func TestActionErrors(t *testing.T) {
	for fail, want := range map[string]error{
		"signed_out":      github.ErrSignedOut,
		"bad_credentials": github.ErrSignedOut,
		"rate_limited":    github.ErrRateLimited,
	} {
		t.Run(fail, func(t *testing.T) {
			testutil.Home(t)
			testutil.FakeGH(t, landState)
			t.Setenv("LOAM_FAKE_GH_FAIL", fail)
			if err := client(t).UpdateBranch(context.Background(), widgets, 15); !errors.Is(err, want) {
				t.Fatalf("got %v, want %v", err, want)
			}
		})
	}
}

func TestRerunFailed(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, landState)
	if err := client(t).RerunFailed(context.Background(), widgets, 101); err != nil {
		t.Fatal(err)
	}
	want := []string{"run", "rerun", "101", "--failed", "--repo", "github.com/example/widgets"}
	if got := lastArgs(t); !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestUpdateBranch(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, landState)
	if err := client(t).UpdateBranch(context.Background(), widgets, 15); err != nil {
		t.Fatal(err)
	}
	want := []string{"pr", "update-branch", "15", "--repo", "github.com/example/widgets"}
	if got := lastArgs(t); !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// refs returns the branches that are on GitHub in the state of the fake gh.
func refs(t *testing.T, file string) []string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var st struct {
		Refs []string `json:"refs"`
	}
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st.Refs
}

// DeleteBranch reads the head of the branch first, and deletes the branch
// only when the head is the PR head.
func TestDeleteBranch(t *testing.T) {
	testutil.Home(t)
	file := testutil.FakeGH(t, landState)
	if err := client(t).DeleteBranch(context.Background(), widgets, "fix-login", prHead); err != nil {
		t.Fatal(err)
	}
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 2 ||
		!slices.Equal(calls[0].Args, []string{"api", "--hostname", "github.com", "repos/example/widgets/git/ref/heads/fix-login"}) ||
		!slices.Equal(calls[1].Args, []string{"api", "--hostname", "github.com", "--method", "DELETE", "repos/example/widgets/git/refs/heads/fix-login"}) {
		t.Fatalf("%+v", calls)
	}
	if got := refs(t, file); slices.Contains(got, "fix-login") {
		t.Fatalf("the branch is still on GitHub: %v", got)
	}
}

// A branch with commits after the PR head stays: they are not in the PR.
func TestDeleteBranchKeepsABranchThatMovedOn(t *testing.T) {
	testutil.Home(t)
	file := testutil.FakeGH(t, landState)
	err := client(t).DeleteBranch(context.Background(), widgets, "moved-on", "4444444444444444444444444444444444444444")
	if !errors.Is(err, github.ErrBranchMoved) {
		t.Fatalf("%v", err)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 1 || !slices.Contains(refs(t, file), "moved-on") {
		t.Fatalf("%d calls, refs %v", n, refs(t, file))
	}
}

// GitHub can delete the branch first, before the read (404) or between the
// read and the delete (422). The branch is gone, as Loam wants.
func TestDeleteBranchThatIsGone(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, landState)
	if err := client(t).DeleteBranch(context.Background(), widgets, "gone", prHead); err != nil {
		t.Fatal(err)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 1 {
		t.Fatalf("%d calls", n)
	}

	t.Setenv("LOAM_FAKE_GH_FAIL", "reference_missing")
	t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "3") // the delete of the second branch
	if err := client(t).DeleteBranch(context.Background(), widgets, "fix-login", prHead); err != nil {
		t.Fatal(err)
	}
}

// A branch name is escaped for the path, and keeps its slashes.
func TestDeleteBranchEscapesTheName(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{"refs": ["feature/fix#12"], "heads": {"feature/fix#12": "`+prHead+`"}, "pulls": [], "details": {}}`)
	if err := client(t).DeleteBranch(context.Background(), widgets, "feature/fix#12", prHead); err != nil {
		t.Fatal(err)
	}
	if got := lastArgs(t); got[len(got)-1] != "repos/example/widgets/git/refs/heads/feature/fix%2312" {
		t.Fatalf("%q", got)
	}
}

// Each failed check of GitHub Actions has its run, for a re-run.
func TestFetchReadsTheRunOfAFailedCheck(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, strings.Replace(state, `"checkSuite": {"workflowRun": {"workflow": {"name": "lint"}}}`,
		`"checkSuite": {"workflowRun": {"databaseId": 101, "workflow": {"name": "lint"}}}`, 1))
	got, err := client(t).Fetch(context.Background(), widgets, []string{"fix-login"})
	if err != nil {
		t.Fatal(err)
	}
	failed := got["fix-login"].PR.FailedChecks
	if len(failed) != 3 || failed[0].RunID != 101 || failed[1].RunID != 0 || failed[2].RunID != 0 {
		t.Fatalf("%+v", failed)
	}
}
