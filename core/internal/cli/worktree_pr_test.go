package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// prState is a made-up GitHub repo. fix-login has an old merged PR and an
// open PR that is ready to merge. pushed-only is on GitHub with no PR.
const prState = `{
  "refs": ["fix-login", "pushed-only"],
  "pulls": [
    {"number": 12, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/12",
     "state": "MERGED", "isCrossRepository": false, "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN",
     "baseRefName": "main", "headRefName": "fix-login", "headRefOid": "1111111111111111111111111111111111111111",
     "mergedAt": "2026-01-01T10:00:00Z", "closedAt": "2026-01-01T10:00:00Z", "commits": {"totalCount": 2}},
    {"number": 15, "title": "Fix the login form again", "url": "https://github.com/example/widgets/pull/15",
     "state": "OPEN", "isCrossRepository": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
     "reviewDecision": "APPROVED", "baseRefName": "main", "headRefName": "fix-login",
     "headRefOid": "2222222222222222222222222222222222222222", "commits": {"totalCount": 3}}
  ],
  "details": {
    "15": {
      "baseRef": {"compare": {"behindBy": 0}},
      "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]},
      "reviewThreads": {"nodes": []},
      "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"nodes": [
        {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true}
      ]}}}}]}
    }
  }
}`

// prCLI makes a plot with a repo whose origin is on GitHub, and three
// worktrees: fix-login, pushed-only, and local-work with a commit that is
// not pushed. The fake gh answers from prState.
func prCLI(t *testing.T) (*store.Store, store.Plot, string) {
	t.Helper()
	s, p, repo := wtCLI(t)
	for _, name := range []string{"fix-login", "pushed-only", "local-work"} {
		if _, errOut, err := lrRun(t, "", "worktree", "new", "alpha", repo, name); err != nil {
			t.Fatalf("%v %s", err, errOut)
		}
	}
	local, err := s.ListWorktrees(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, local[2].Path, "commit", "--allow-empty", "-m", "work")
	// The worktrees came from the local remote. From now on, origin names
	// GitHub, and no command fetches.
	testutil.Git(t, repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(t, prState)
	return s, p, repo
}

func listJSON(t *testing.T, args ...string) map[string]worktree.Status {
	t.Helper()
	out, errOut, err := lrRun(t, "", append(append([]string{"worktree", "list"}, args...), "--json")...)
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var list []worktree.Status
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	byName := map[string]worktree.Status{}
	for _, st := range list {
		byName[st.Worktree.Name] = st
	}
	return byName
}

func changedMarker(t *testing.T, s *store.Store) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(s.Home(), store.ChangedFile))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func TestWorktreeListRefreshWritesTheCache(t *testing.T) {
	s, _, _ := prCLI(t)
	before := changedMarker(t, s)

	got := listJSON(t, "alpha", "--refresh")
	if after := changedMarker(t, s); after != before {
		t.Fatalf("a refresh moved loam.changed from %q to %q", before, after)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 2 {
		t.Fatalf("%d gh calls, want 2: one repo, one open PR", n)
	}
	// Two PRs on one head: the open one wins.
	if st := got["fix-login"]; st.Stage != worktree.StageReadyToMerge || st.PR == nil || st.PR.Number != 15 ||
		st.PR.Checks.Passed != 1 || st.PR.Approvals != 1 || st.PRNote != "" || st.PRCheckedAt == nil || st.CompareURL != "" {
		t.Fatalf("fix-login: %+v %+v", st, st.PR)
	}
	if st := got["pushed-only"]; st.Stage != worktree.StagePushedNoPR || st.PR != nil ||
		st.CompareURL != "https://github.com/example/widgets/compare/main...pushed-only" {
		t.Fatalf("pushed-only: %+v", st)
	}
	if st := got["local-work"]; st.Stage != worktree.StageNotPushed || st.PR != nil || st.PRCheckedAt == nil || st.CompareURL != "" {
		t.Fatalf("local-work: %+v", st)
	}

	// A plain list reads the cache and makes no gh call.
	again := listJSON(t, "alpha")
	if n := len(testutil.FakeGHCalls(t)); n != 2 {
		t.Fatalf("a plain list called gh: %d calls", n)
	}
	for name, st := range got {
		if a := again[name]; a.Stage != st.Stage || !a.PRCheckedAt.Equal(*st.PRCheckedAt) {
			t.Fatalf("%s: refresh %+v, plain list %+v", name, st, a)
		}
	}
	text, _, err := lrRun(t, "", "worktree", "list", "alpha")
	if err != nil || !strings.Contains(text, "PR #15 ready to merge") || !strings.Contains(text, "pushed, no PR") {
		t.Fatalf("%q %v", text, err)
	}
}

// GitHub gives mergeable UNKNOWN while it checks a PR. The stage of the last
// refresh stays.
func TestWorktreeListRefreshKeepsTheStageWhileGitHubChecks(t *testing.T) {
	prCLI(t)
	listJSON(t, "alpha", "--refresh")
	file := os.Getenv("LOAM_FAKE_GH_STATE")
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	unknown := strings.Replace(string(b), `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`, `"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"`, 1)
	if unknown == string(b) {
		t.Fatal("the state has no open PR to change")
	}
	if err := os.WriteFile(file, []byte(unknown), 0o644); err != nil {
		t.Fatal(err)
	}
	st := listJSON(t, "alpha", "--refresh")["fix-login"]
	if st.Stage != worktree.StageReadyToMerge || st.PR.Mergeable != "UNKNOWN" {
		t.Fatalf("%+v", st)
	}
	if st := listJSON(t, "alpha")["fix-login"]; st.Stage != worktree.StageReadyToMerge {
		t.Fatalf("plain list: %+v", st)
	}
}

// A failed refresh keeps the cached state and its time, and sets a note.
func TestWorktreeListRefreshNotes(t *testing.T) {
	for _, c := range []struct {
		note worktree.PRNote
		fail func(t *testing.T)
	}{
		{worktree.NoteGHSignedOut, func(t *testing.T) { t.Setenv("LOAM_FAKE_GH_FAIL", "signed_out") }},
		{worktree.NoteRateLimited, func(t *testing.T) { t.Setenv("LOAM_FAKE_GH_FAIL", "rate_limited") }},
		{worktree.NoteOffline, func(t *testing.T) { t.Setenv("LOAM_FAKE_GH_FAIL", "offline") }},
		{worktree.NoteGHMissing, func(t *testing.T) { t.Setenv("LOAM_GH", filepath.Join(t.TempDir(), "gh")) }},
	} {
		t.Run(string(c.note), func(t *testing.T) {
			prCLI(t)
			first := listJSON(t, "alpha", "--refresh")["fix-login"]
			c.fail(t)
			got := listJSON(t, "alpha", "--refresh")
			st := got["fix-login"]
			if st.PRNote != c.note || st.PR == nil || st.PR.Number != 15 || st.Stage != worktree.StageReadyToMerge ||
				st.PRCheckedAt == nil || !st.PRCheckedAt.Equal(*first.PRCheckedAt) {
				t.Fatalf("%+v", st)
			}
			// The note stays for a plain list, until a refresh gets an answer.
			if st := listJSON(t, "alpha")["local-work"]; st.PRNote != c.note {
				t.Fatalf("plain list: %+v", st)
			}
		})
	}
}

func TestWorktreeListRefreshSkipsARepoWithNoGitHubRemote(t *testing.T) {
	_, _, repo := wtCLI(t)
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login"); err != nil {
		t.Fatal(err)
	}
	testutil.FakeGH(t, prState)
	st := listJSON(t, "alpha", "--refresh")["fix-login"]
	if st.PRNote != worktree.NoteNoGitHubRemote || st.PR != nil || st.Stage != worktree.StageNone {
		t.Fatalf("%+v", st)
	}
	if calls := testutil.FakeGHCalls(t); len(calls) != 0 {
		t.Fatalf("gh ran for a repo with no GitHub remote: %+v", calls)
	}
}

func TestWorktreeListRefreshOneWorktree(t *testing.T) {
	_, _, repo := prCLI(t)
	got := listJSON(t, "alpha", "--refresh", "--worktree", "app-pushed-only")
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 1 || calls[0].Variables["h0"] != "pushed-only" || calls[0].Variables["h1"] != nil {
		t.Fatalf("calls %+v", calls)
	}
	if len(got) != 3 || got["pushed-only"].Stage != worktree.StagePushedNoPR || got["fix-login"].PRCheckedAt != nil {
		t.Fatalf("%+v", got)
	}

	for _, args := range [][]string{
		{"worktree", "list", "alpha", "--worktree", "pushed-only"},
		{"worktree", "list", "--refresh", "--worktree", "pushed-only"},
		{"worktree", "list", "alpha", "--refresh", "--repo", repo},
	} {
		if _, _, err := lrRun(t, "", args...); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%v: %v", args, err)
		}
	}
}

// A worktree whose folder is gone gets no query and shows no ship state.
func TestWorktreeListRefreshSkipsAMissingFolder(t *testing.T) {
	s, p, _ := prCLI(t)
	listJSON(t, "alpha", "--refresh")
	ws, err := s.ListWorktrees(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(ws[0].Path); err != nil {
		t.Fatal(err)
	}
	st := listJSON(t, "alpha", "--refresh")["fix-login"]
	if !st.Missing || st.PR != nil || st.Stage != worktree.StageNone || st.PRCheckedAt != nil {
		t.Fatalf("%+v", st)
	}
	calls := testutil.FakeGHCalls(t)
	last := calls[len(calls)-1].Variables
	if len(calls) != 3 || last["h0"] != "pushed-only" || last["h1"] != "local-work" || last["h2"] != nil {
		t.Fatalf("%+v", calls)
	}
}

// Each PR stage and each note has text for the line of a worktree.
func TestEveryStageAndNoteHasText(t *testing.T) {
	for _, s := range worktree.Stages {
		_, ok := prStageWords[s]
		noPR := s == worktree.StagePushedNoPR || s == worktree.StageNotPushed || s == worktree.StageBehindBase
		if ok == noPR {
			t.Errorf("stage %q: text %v", s, ok)
		}
	}
	for _, n := range worktree.PRNotes {
		if noteText[n] == "" {
			t.Errorf("note %q has no text", n)
		}
	}
}
