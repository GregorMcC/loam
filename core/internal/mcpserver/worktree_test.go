package mcpserver_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// withGitRepo adds a real git repo to the first plot and returns its path.
func withGitRepo(t *testing.T, e *env) string {
	t.Helper()
	repo, _ := testutil.GitRepo(t)
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(repo)}}}); err != nil {
		t.Fatal(err)
	}
	return repo
}

func TestCreateAndListWorktrees(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo := withGitRepo(t, e)
	if err := e.s.SetRepoSettings(repo, store.S("make setup"), &[]string{".env"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".env"), []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A real .env is ignored by git, so the copy does not count as a change.
	if err := os.WriteFile(filepath.Join(repo, ".git", "info", "exclude"), []byte(".env\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// It needs no get_plot first, and it uses the main repo by default.
	out := e.ok("create_worktree", map[string]any{"name": "ENG-12-fix"})
	var created struct {
		Worktree store.Worktree `json:"worktree"`
		Copied   []string       `json:"copied"`
	}
	if err := json.Unmarshal([]byte(out), &created); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	w := created.Worktree
	if w.Branch != "ENG-12-fix" || w.PlotID != e.plot.ID || w.Repo != repo || !slices.Equal(created.Copied, []string{".env"}) {
		t.Fatalf("%+v", created)
	}
	if _, err := os.Stat(filepath.Join(w.Path, ".env")); err != nil {
		t.Fatal(err)
	}
	// It never runs the setup command: the record says setup is not done.
	if rec, _ := e.s.GetWorktree(w.ID); rec.SetupDone {
		t.Fatal("create_worktree ran setup")
	}
	// It is not a change.
	if cs, _ := e.s.ListChanges(store.ChangeQuery{PlotID: e.plot.ID}); len(cs) != 2 { // plot, repo add
		t.Fatalf("%d changes", len(cs))
	}

	out = e.ok("list_worktrees", nil)
	var list struct {
		Worktrees []struct {
			Worktree store.Worktree `json:"worktree"`
			Changed  int            `json:"changed"`
			Unpushed int            `json:"unpushed"`
			Merged   bool           `json:"merged"`
		} `json:"worktrees"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil || len(list.Worktrees) != 1 {
		t.Fatalf("%v: %s", err, out)
	}
	if got := list.Worktrees[0]; got.Worktree.ID != w.ID || !got.Merged || got.Changed != 0 {
		t.Fatalf("%+v", got)
	}
	// Another plot lists none.
	var none struct {
		Worktrees []any `json:"worktrees"`
	}
	if err := json.Unmarshal([]byte(e.ok("list_worktrees", map[string]any{"plot": e.other.ID})), &none); err != nil {
		t.Fatal(err)
	}
	if none.Worktrees == nil || len(none.Worktrees) != 0 {
		t.Fatalf("%#v", none)
	}
}

func TestCreateWorktreeOptionsAndErrors(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo := withGitRepo(t, e)
	testutil.Git(t, repo, "checkout", "-b", "develop")
	testutil.Git(t, repo, "push", "origin", "develop")
	testutil.Git(t, repo, "checkout", "main")
	repoID := e.plotNow(e.plot.ID).Repos[0].ID

	out := e.ok("create_worktree", map[string]any{"name": "feat", "base": "origin/develop", "repo_id": repoID})
	if !strings.Contains(out, "origin/develop") {
		t.Fatalf("%s", out)
	}
	e.fail("create_worktree", map[string]any{"name": "feat"})                      // exists
	e.fail("create_worktree", map[string]any{"name": ""})                          // no name
	e.fail("create_worktree", map[string]any{"name": "x", "repo_id": "nope"})      // no such repo
	e.fail("create_worktree", map[string]any{"name": "y", "base": "nope"})         // no such base
	e.fail("create_worktree", map[string]any{"name": "z", "plot": "nosuchplot12"}) // no such plot
	// A plot with no repo cannot make a worktree.
	out = e.fail("create_worktree", map[string]any{"name": "q", "plot": e.other.ID})
	if !strings.Contains(out, "repo") {
		t.Fatalf("%s", out)
	}
}

func TestRepoSettingsThroughAddAndUpdateRepo(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	dir := t.TempDir()
	id := idOut(t, e.ok("add_repo", map[string]any{"path": dir, "setup": "npm ci", "copy": []string{".env", "cfg/*.json"}}), "repo_id")
	r := e.plotNow(e.plot.ID).Repos[0]
	if r.Setup != "npm ci" || !slices.Equal(r.Copy, []string{".env", "cfg/*.json"}) {
		t.Fatalf("%+v", r)
	}
	// get_plot shows the settings.
	if out := e.ok("get_plot", nil); !strings.Contains(out, "npm ci") {
		t.Fatalf("%s", out)
	}

	// Settings only: it is not a change.
	before := e.lastChange().ID
	e.ok("update_repo", map[string]any{"repo_id": id, "setup": "make"})
	if r := e.plotNow(e.plot.ID).Repos[0]; r.Setup != "make" || len(r.Copy) != 2 || r.Note != "" {
		t.Fatalf("%+v", r)
	}
	if e.lastChange().ID != before {
		t.Fatal("a settings update made a change")
	}
	// An empty list clears the files. A note still works with it.
	e.ok("get_plot", nil)
	e.ok("update_repo", map[string]any{"repo_id": id, "copy": []string{}, "note": "n"})
	if r := e.plotNow(e.plot.ID).Repos[0]; len(r.Copy) != 0 || r.Note != "n" {
		t.Fatalf("%+v", r)
	}
	e.fail("update_repo", map[string]any{"repo_id": id})
	e.fail("update_repo", map[string]any{"repo_id": "nope", "setup": "x"})
}

// after_merge in update_repo and add_repo sets what the app does after a
// merge on GitHub. It is a setting of the repo path, not a change.
func TestAfterMergeThroughAddAndUpdateRepo(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	id := idOut(t, e.ok("add_repo", map[string]any{"path": t.TempDir()}), "repo_id")
	if got := e.plotNow(e.plot.ID).Repos[0].AfterMerge; got != store.AfterMergeAsk {
		t.Fatalf("default %q", got)
	}
	// get_plot shows the setting.
	if out := e.ok("get_plot", nil); !strings.Contains(out, `"after_merge": "ask"`) {
		t.Fatalf("%s", out)
	}

	before := e.lastChange().ID
	e.ok("update_repo", map[string]any{"repo_id": id, "after_merge": "remove"})
	if r := e.plotNow(e.plot.ID).Repos[0]; r.AfterMerge != store.AfterMergeRemove || r.Note != "" {
		t.Fatalf("%+v", r)
	}
	if e.lastChange().ID != before {
		t.Fatal("a settings update made a change")
	}
	// A value that is not ask, remove, or keep fails and changes nothing.
	out := e.fail("update_repo", map[string]any{"repo_id": id, "after_merge": "never"})
	if !strings.Contains(out, "ask, remove, or keep") {
		t.Fatalf("%s", out)
	}
	if r := e.plotNow(e.plot.ID).Repos[0]; r.AfterMerge != store.AfterMergeRemove {
		t.Fatalf("%+v", r)
	}
	// A bad value with a note changes neither.
	e.ok("get_plot", nil)
	e.fail("update_repo", map[string]any{"repo_id": id, "note": "n", "after_merge": "later"})
	if r := e.plotNow(e.plot.ID).Repos[0]; r.Note != "" || r.AfterMerge != store.AfterMergeRemove {
		t.Fatalf("%+v", r)
	}

	// add_repo takes it too, and a bad value adds no repo.
	e.ok("get_plot", nil)
	other := idOut(t, e.ok("add_repo", map[string]any{"path": t.TempDir(), "after_merge": "keep"}), "repo_id")
	for _, r := range e.plotNow(e.plot.ID).Repos {
		if r.ID == other && r.AfterMerge != store.AfterMergeKeep {
			t.Fatalf("%+v", r)
		}
	}
	e.ok("get_plot", nil)
	e.fail("add_repo", map[string]any{"path": t.TempDir(), "after_merge": "sometimes"})
	if n := len(e.plotNow(e.plot.ID).Repos); n != 2 {
		t.Fatalf("%d repos after a bad add", n)
	}
}

func TestRemoveRepoRefusedWhileWorktreesExist(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	withGitRepo(t, e)
	repoID := e.plotNow(e.plot.ID).Repos[0].ID
	e.ok("create_worktree", map[string]any{"name": "keep"})
	e.ok("get_plot", nil)
	out := e.fail("remove_repo", map[string]any{"repo_id": repoID})
	if !strings.Contains(out, "worktree") {
		t.Fatalf("%s", out)
	}
	if len(e.plotNow(e.plot.ID).Repos) != 1 {
		t.Fatal("repo removed")
	}
}

// list_worktrees reads the PR cache. With refresh, it asks GitHub first.
func TestListWorktreesRefresh(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo := withGitRepo(t, e)
	e.ok("create_worktree", map[string]any{"name": "fix-login"})
	testutil.Git(t, repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(t, `{"refs": ["fix-login"], "pulls": [], "details": {}}`)

	type listed struct {
		Worktrees []struct {
			Stage       string  `json:"stage"`
			PR          any     `json:"pr"`
			PRNote      string  `json:"pr_note"`
			PRCheckedAt *string `json:"pr_checked_at"`
			CompareURL  string  `json:"compare_url"`
		} `json:"worktrees"`
	}
	var before listed
	if err := json.Unmarshal([]byte(e.ok("list_worktrees", nil)), &before); err != nil {
		t.Fatal(err)
	}
	if w := before.Worktrees[0]; w.Stage != "" || w.PRCheckedAt != nil || len(testutil.FakeGHCalls(t)) != 0 {
		t.Fatalf("a list with no refresh: %+v", w)
	}

	var after listed
	if err := json.Unmarshal([]byte(e.ok("list_worktrees", map[string]any{"refresh": true})), &after); err != nil {
		t.Fatal(err)
	}
	if w := after.Worktrees[0]; w.Stage != "pushed_no_pr" || w.PR != nil || w.PRNote != "" || w.PRCheckedAt == nil ||
		w.CompareURL != "https://github.com/example/widgets/compare/main...fix-login" {
		t.Fatalf("%+v", w)
	}
	if n := len(testutil.FakeGHCalls(t)); n != 1 {
		t.Fatalf("%d gh calls", n)
	}
}

// list_worktrees gives the failed checks of a PR and counts the passed ones. It leaves out the list of the
// passed checks: a session reads those through gh, and up to 100 rows for each worktree would fill its
// context. The CLI list and the PR cache keep the list.
func TestListWorktreesLeavesOutThePassedChecks(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo := withGitRepo(t, e)
	e.ok("create_worktree", map[string]any{"name": "fix-login"})
	e.ok("create_worktree", map[string]any{"name": "add-search"})
	testutil.Git(t, repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(t, `{"refs": ["fix-login", "add-search"], "pulls": [
	  {"number": 14, "title": "Fix login", "url": "https://github.com/example/widgets/pull/14", "state": "OPEN",
	   "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE", "baseRefName": "main", "headRefName": "fix-login",
	   "headRefOid": "1111111111111111111111111111111111111111", "commits": {"totalCount": 1}}
	], "details": {"14": {"commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"totalCount": 3, "nodes": [
	  {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": false},
	  {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": false},
	  {"__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS", "targetUrl": "", "isRequired": false}
	]}}}}]}}}}`)

	out := e.ok("list_worktrees", map[string]any{"refresh": true})
	if strings.Contains(out, "passed_checks") {
		t.Fatalf("the list holds the passed checks: %s", out)
	}
	var list struct {
		Worktrees []struct {
			Worktree store.Worktree `json:"worktree"`
			PR       *struct {
				Number       int `json:"number"`
				Checks       struct{ Passed, Failed int }
				FailedChecks []struct{ Name string } `json:"failed_checks"`
			} `json:"pr"`
		} `json:"worktrees"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil || len(list.Worktrees) != 2 {
		t.Fatalf("%v: %s", err, out)
	}
	for _, w := range list.Worktrees {
		switch w.Worktree.Branch {
		case "fix-login":
			if w.PR == nil || w.PR.Number != 14 || w.PR.Checks.Passed != 2 || w.PR.Checks.Failed != 1 ||
				len(w.PR.FailedChecks) != 1 || w.PR.FailedChecks[0].Name != "docs" {
				t.Errorf("fix-login: %+v", w.PR)
			}
		default:
			if w.PR != nil {
				t.Errorf("%s: %+v", w.Worktree.Branch, w.PR)
			}
		}
	}

	// The PR cache still has the passed checks, for the CLI and the app.
	cached, err := worktree.List(e.s, e.plot.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, st := range cached {
		if st.PR != nil && len(st.PR.PassedChecks) != 2 {
			t.Errorf("%s: cached passed checks %+v", st.Worktree.Branch, st.PR.PassedChecks)
		}
	}
}
