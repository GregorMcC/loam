package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// wtCLI makes a store with a plot that holds one real git repo.
func wtCLI(t *testing.T) (*store.Store, store.Plot, string) {
	t.Helper()
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: repo}}})
	return s, p, repo
}

func TestRepoSettingsFlags(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 1)
	out, _, err := lrRun(t, "", "repo", "add", "alpha", d[0], "--setup", "make setup", "--copy", ".env", "--copy", "cfg/*.json", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var added struct {
		Repo store.Repo `json:"repo"`
	}
	if err := json.Unmarshal([]byte(out), &added); err != nil {
		t.Fatal(err)
	}
	if added.Repo.Setup != "make setup" || !slices.Equal(added.Repo.Copy, []string{".env", "cfg/*.json"}) {
		t.Fatalf("%+v", added.Repo)
	}
	// The settings change nothing in the change log, so edit with only settings is not a change.
	out, _, err = lrRun(t, "", "repo", "edit", "alpha", d[0], "--setup", "npm ci", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var edited struct {
		ChangeID int64      `json:"change_id"`
		Repo     store.Repo `json:"repo"`
	}
	json.Unmarshal([]byte(out), &edited)
	if edited.ChangeID != 0 || edited.Repo.Setup != "npm ci" || len(edited.Repo.Copy) != 2 {
		t.Fatalf("%+v", edited)
	}
	if text, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0], "--copy", ""); err != nil || !strings.Contains(text, "Saved") {
		t.Fatalf("%q %v", text, err)
	}
	r := lrPlot(t, s, p.ID).Repos[0]
	if r.Setup != "npm ci" || len(r.Copy) != 0 {
		t.Fatalf("%+v", r)
	}
	// A note and a setting together.
	if _, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0], "--note", "hi", "--setup", ""); err != nil {
		t.Fatal(err)
	}
	if r := lrPlot(t, s, p.ID).Repos[0]; r.Note != "hi" || r.Setup != "" {
		t.Fatalf("%+v", r)
	}
	// With nothing to change, the command fails.
	if _, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0]); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("%v", err)
	}
}

// --after-merge sets what the app does after a merge on GitHub. It is a
// setting of the repo path, not a change, and the repo JSON shows it.
func TestRepoAfterMergeFlag(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 2)
	type written struct {
		ChangeID int64      `json:"change_id"`
		Repo     store.Repo `json:"repo"`
	}
	read := func(out string) written {
		t.Helper()
		var w written
		if err := json.Unmarshal([]byte(out), &w); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		return w
	}

	// A new repo asks by default.
	out, _, err := lrRun(t, "", "repo", "add", "alpha", d[0], "--json")
	if err != nil {
		t.Fatal(err)
	}
	if got := read(out).Repo.AfterMerge; got != store.AfterMergeAsk {
		t.Fatalf("default %q: %s", got, out)
	}
	if !strings.Contains(out, `"after_merge": "ask"`) {
		t.Fatalf("the repo JSON has no after_merge: %s", out)
	}
	// repo add takes the flag too.
	out, _, err = lrRun(t, "", "repo", "add", "alpha", d[1], "--after-merge", "keep", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if got := read(out).Repo.AfterMerge; got != store.AfterMergeKeep {
		t.Fatalf("add %q", got)
	}

	before := lrPlot(t, s, p.ID).Revision
	out, _, err = lrRun(t, "", "repo", "edit", "alpha", d[0], "--after-merge", "remove", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if w := read(out); w.ChangeID != 0 || w.Repo.AfterMerge != store.AfterMergeRemove {
		t.Fatalf("%+v", w)
	}
	if got := lrPlot(t, s, p.ID); got.Revision != before || got.Repos[0].AfterMerge != store.AfterMergeRemove {
		t.Fatalf("revision %d (was %d), repos %+v", got.Revision, before, got.Repos)
	}
	if text, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0], "--after-merge", "ask"); err != nil || !strings.Contains(text, "Saved") {
		t.Fatalf("%q %v", text, err)
	}

	// A value that is not ask, remove, or keep exits with code 2 and changes nothing.
	for _, bad := range []string{"never", "", "Remove"} {
		_, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0], "--after-merge", bad, "--json")
		if !errors.Is(err, store.ErrInvalid) || classify(err).ExitCode != ExitInvalid {
			t.Fatalf("%q: %v", bad, err)
		}
	}
	if got := lrPlot(t, s, p.ID).Repos[0].AfterMerge; got != store.AfterMergeAsk {
		t.Fatalf("a bad value changed the setting to %q", got)
	}
	// A bad value on repo add adds no repo.
	d2 := lrRepoDirs(t, 1)
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", d2[0], "--after-merge", "later"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("%v", err)
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 2 {
		t.Fatalf("%d repos after a bad add", n)
	}
}

func TestWorktreeNewListRm(t *testing.T) {
	s, p, repo := wtCLI(t)
	out, errOut, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-x", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var created struct {
		Worktree store.Worktree `json:"worktree"`
		Copied   []string       `json:"copied"`
	}
	if err := json.Unmarshal([]byte(out), &created); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	w := created.Worktree
	if w.Name != "fix-x" || w.Branch != "fix-x" || w.PlotID != p.ID || w.Base != "origin/main" || created.Copied == nil {
		t.Fatalf("%+v", created)
	}
	if _, err := os.Stat(w.Path); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(w.Path, filepath.Join("worktrees", p.ID, "app-fix-x")) {
		t.Fatalf("path %s", w.Path)
	}

	out, _, err = lrRun(t, "", "worktree", "list", "alpha", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var list []worktree.Status
	if err := json.Unmarshal([]byte(out), &list); err != nil || len(list) != 1 {
		t.Fatalf("%v: %s", err, out)
	}
	if list[0].Worktree.ID != w.ID || list[0].Changed != 0 || list[0].Unpushed != 0 || !list[0].Merged {
		t.Fatalf("%+v", list[0])
	}
	if text, _, err := lrRun(t, "", "worktree", "list"); err != nil || !strings.Contains(text, "app-fix-x") || !strings.Contains(text, "merged") {
		t.Fatalf("%q %v", text, err)
	}
	if text, _, _ := lrRun(t, "", "worktree", "list", "--json"); !strings.Contains(text, w.ID) {
		t.Fatalf("list of every plot: %s", text)
	}

	// Remove: a dirty worktree is refused, a pane blocks even with --force, then it goes.
	os.WriteFile(filepath.Join(w.Path, "x.txt"), []byte("x"), 0o644)
	if _, _, err := lrRun(t, "", "worktree", "rm", "alpha", "fix-x"); !errors.Is(err, worktree.ErrUnsafe) {
		t.Fatalf("%v", err)
	}
	if _, _, err := lrRun(t, "", "worktree", "rm", "alpha", "fix-x", "--force", "--open-pane", w.Path); !errors.Is(err, worktree.ErrPanesOpen) {
		t.Fatalf("%v", err)
	}
	out, _, err = lrRun(t, "", "worktree", "rm", "alpha", "fix-x", "--force", "--open-pane", repo, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var removed struct {
		Worktree      store.Worktree `json:"worktree"`
		BranchDeleted bool           `json:"branch_deleted"`
		BranchNote    string         `json:"branch_note"`
	}
	if err := json.Unmarshal([]byte(out), &removed); err != nil || removed.Worktree.ID != w.ID || !removed.BranchDeleted {
		t.Fatalf("%v: %s", err, out)
	}
	if ws, _ := s.ListWorktrees(p.ID); len(ws) != 0 {
		t.Fatalf("%v", ws)
	}
	if _, _, err := lrRun(t, "", "worktree", "rm", "alpha", "fix-x"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
}

func TestWorktreeNewFlagsAndArguments(t *testing.T) {
	_, _, repo := wtCLI(t)
	testutil.Git(t, repo, "checkout", "-b", "develop")
	testutil.Git(t, repo, "push", "origin", "develop")
	testutil.Git(t, repo, "checkout", "main")
	out, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "feat", "--base", "develop")
	if err != nil || !strings.Contains(out, "feat") {
		t.Fatalf("%q %v", out, err)
	}
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo); err == nil {
		t.Fatal("want an error for a missing name")
	}
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", "/not/a/repo", "x"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
	if _, _, err := lrRun(t, "", "worktree", "new", "nosuchplot", repo, "x"); !errors.Is(err, ErrUnknownPlot) {
		t.Fatalf("%v", err)
	}
}

func TestRepoRmRefusedWhilePlotHasWorktrees(t *testing.T) {
	s, p, repo := wtCLI(t)
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "keep"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", repo); !errors.Is(err, store.ErrHasWorktrees) {
		t.Fatalf("%v", err)
	}
	if got := lrPlot(t, s, p.ID).Repos; len(got) != 1 {
		t.Fatalf("%+v", got)
	}
	if _, _, err := lrRun(t, "", "worktree", "rm", "alpha", "keep"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", repo); err != nil {
		t.Fatal(err)
	}
}
