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
	json.Unmarshal([]byte(e.ok("list_worktrees", map[string]any{"plot": e.other.ID})), &none)
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
