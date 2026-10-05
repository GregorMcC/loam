package worktree_test

import (
	"errors"
	"os"
	osexec "os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

type env struct {
	t      *testing.T
	s      *store.Store
	home   string
	plot   store.Plot
	repo   string // the clone
	remote string // the bare remote
}

func setup(t *testing.T) *env {
	t.Helper()
	testutil.GitEnv(t)
	home := testutil.Home(t)
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	repo, remote := testutil.GitRepo(t)
	res, err := s.CreatePlot(store.PlotInput{Name: "Plot", What: "w", Why: "y", Repos: []store.RepoInput{{Path: repo}}}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	h, _ := filepath.EvalSymlinks(home)
	return &env{t: t, s: s, home: h, plot: res.Plot, repo: repo, remote: remote}
}

func (e *env) create(name, base string) *worktree.CreateResult {
	e.t.Helper()
	res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: name, Base: base})
	if err != nil {
		e.t.Fatalf("create %s: %v", name, err)
	}
	return res
}

// commit writes a file in dir and commits it.
func commit(t *testing.T, dir, file, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, file)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, file), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, dir, "add", file)
	testutil.Git(t, dir, "commit", "-m", "add "+file)
}

func TestCreateBranchesFromTheRemoteDefaultBranch(t *testing.T) {
	e := setup(t)
	// The remote moves on. The local main does not.
	other := filepath.Join(t.TempDir(), "other")
	testutil.Git(t, filepath.Dir(other), "clone", e.remote, other)
	commit(t, other, "new.txt", "new\n")
	testutil.Git(t, other, "push", "origin", "main")

	res := e.create("fix-x", "")
	w := res.Worktree
	// The store keeps LOAM_HOME as given. On macOS the temp folder is under
	// the link /var, so compare the resolved paths.
	want, err := filepath.EvalSymlinks(filepath.Join(e.home, "worktrees", e.plot.ID, "app-fix-x"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := filepath.EvalSymlinks(w.Path); err != nil || got != want {
		t.Fatalf("path %s, want %s", w.Path, want)
	}
	if w.Branch != "fix-x" || w.Name != "fix-x" || w.Base != "origin/main" || w.Repo != e.repo || w.SetupDone {
		t.Fatalf("%+v", w)
	}
	if _, err := os.Stat(filepath.Join(w.Path, "new.txt")); err != nil {
		t.Fatalf("the worktree did not start from the fetched main: %v", err)
	}
	if got := testutil.Git(t, w.Path, "rev-parse", "--abbrev-ref", "HEAD"); got != "fix-x" {
		t.Fatalf("branch %s", got)
	}
	// The new branch has no upstream, so a push does not go to main by mistake.
	if out, err := exec(w.Path, "config", "branch.fix-x.merge"); err == nil {
		t.Fatalf("branch has an upstream: %s", out)
	}
	if rec, err := e.s.GetWorktree(w.ID); err != nil || rec.Path != w.Path {
		t.Fatalf("no record: %+v %v", rec, err)
	}
	// Create is not a change.
	cs, _ := e.s.ListChanges(store.ChangeQuery{PlotID: e.plot.ID})
	if len(cs) != 1 {
		t.Fatalf("%d changes", len(cs))
	}
}

func exec(dir string, args ...string) (string, error) {
	b, err := osexec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	return string(b), err
}

func TestCreateFromABaseBranch(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "checkout", "-b", "develop")
	commit(t, e.repo, "dev.txt", "d\n")
	testutil.Git(t, e.repo, "push", "origin", "develop")
	testutil.Git(t, e.repo, "checkout", "main")

	res := e.create("feat", "origin/develop")
	if res.Worktree.Base != "origin/develop" {
		t.Fatalf("base %q", res.Worktree.Base)
	}
	if _, err := os.Stat(filepath.Join(res.Worktree.Path, "dev.txt")); err != nil {
		t.Fatal(err)
	}
	// A local base wins over the remote branch, so its commits that are not
	// pushed come along.
	testutil.Git(t, e.repo, "checkout", "develop")
	commit(t, e.repo, "local.txt", "l\n")
	testutil.Git(t, e.repo, "checkout", "main")
	res = e.create("feat2", "develop")
	if res.Worktree.Base != "develop" {
		t.Fatalf("base %q", res.Worktree.Base)
	}
	if _, err := os.Stat(filepath.Join(res.Worktree.Path, "local.txt")); err != nil {
		t.Fatal(err)
	}
	// A base that does not exist.
	_, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "z", Base: "nope"})
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("want not found, got %v", err)
	}
}

func TestCreateUsesAnExistingLocalBranch(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "branch", "mine")
	res := e.create("mine", "")
	if res.Worktree.Branch != "mine" || res.Worktree.Base != "" {
		t.Fatalf("%+v", res.Worktree)
	}
	// A branch that a worktree holds cannot be used twice.
	if _, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "mine"}); err == nil {
		t.Fatal("want an error for a second worktree on the same branch")
	}
}

func TestCreateUsesAnExistingRemoteBranch(t *testing.T) {
	e := setup(t)
	other := filepath.Join(t.TempDir(), "other")
	testutil.Git(t, filepath.Dir(other), "clone", e.remote, other)
	testutil.Git(t, other, "checkout", "-b", "from-linear")
	commit(t, other, "lin.txt", "l\n")
	testutil.Git(t, other, "push", "origin", "from-linear")

	res := e.create("from-linear", "")
	w := res.Worktree
	if w.Base != "" {
		t.Fatalf("base %q", w.Base)
	}
	if _, err := os.Stat(filepath.Join(w.Path, "lin.txt")); err != nil {
		t.Fatal(err)
	}
	if up := testutil.Git(t, w.Path, "rev-parse", "--abbrev-ref", "@{upstream}"); up != "origin/from-linear" {
		t.Fatalf("upstream %q", up)
	}
	// A base makes no sense for a branch that exists.
	testutil.Git(t, e.repo, "branch", "local-only")
	_, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "local-only", Base: "main"})
	if !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("want invalid, got %v", err)
	}
}

func TestCreateCopiesFiles(t *testing.T) {
	e := setup(t)
	write := func(name, body string) {
		t.Helper()
		p := filepath.Join(e.repo, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(".env", "SECRET=1\n")
	write("config/a.json", "{}")
	write("config/b.json", "{}")
	write("tools/x.sh", "#!/bin/sh\n")
	write("tools/sub/y.sh", "y")
	write(".worktreeinclude", "# local files\n\nconfig/*.json\n/tools/\n../escape\n")
	if err := e.s.SetRepoSettings(e.repo, nil, &[]string{".env", "missing.txt", "README.md"}); err != nil {
		t.Fatal(err)
	}
	res := e.create("copy", "")
	for _, f := range []string{".env", "config/a.json", "config/b.json", "tools/x.sh", "tools/sub/y.sh"} {
		b, err := os.ReadFile(filepath.Join(res.Worktree.Path, f))
		if err != nil || len(b) == 0 {
			t.Fatalf("%s not copied: %v", f, err)
		}
	}
	if fi, _ := os.Stat(filepath.Join(res.Worktree.Path, ".env")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	for _, f := range []string{".env", "config/a.json", "config/b.json", "tools/x.sh", "tools/sub/y.sh"} {
		if !slices.Contains(res.Copied, f) {
			t.Errorf("Copied misses %s: %v", f, res.Copied)
		}
	}
	// README.md is tracked, so it is already there and is not copied again.
	if slices.Contains(res.Copied, "README.md") {
		t.Errorf("a tracked file was copied: %v", res.Copied)
	}
	joined := strings.Join(res.Warnings, "\n")
	if !strings.Contains(joined, "missing.txt") || !strings.Contains(joined, "../escape") {
		t.Fatalf("warnings %v", res.Warnings)
	}
}

func TestCreateRefusals(t *testing.T) {
	e := setup(t)
	e.create("one", "")
	create := func(o worktree.CreateOptions) error {
		o.PlotID = e.plot.ID
		if o.Repo == "" {
			o.Repo = e.repo
		}
		_, err := worktree.Create(e.s, o)
		return err
	}
	if err := create(worktree.CreateOptions{Name: "one"}); !errors.Is(err, store.ErrDuplicate) {
		t.Errorf("same name: %v", err)
	}
	if err := create(worktree.CreateOptions{Name: "o/ne"}); err != nil {
		t.Errorf("slash in name: %v", err)
	}
	if err := create(worktree.CreateOptions{Name: "o-ne"}); !errors.Is(err, store.ErrDuplicate) {
		t.Errorf("same folder: %v", err)
	}
	for _, bad := range []string{"", "-x", "a b", "a..b", "x.lock"} {
		if err := create(worktree.CreateOptions{Name: bad}); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("name %q: %v", bad, err)
		}
	}
	if err := create(worktree.CreateOptions{Name: "n", Repo: "/not/a/repo"}); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("repo not in plot: %v", err)
	}
	// A repo can be named by its ID.
	if err := create(worktree.CreateOptions{Name: "by-id", Repo: e.plot.Repos[0].ID}); err != nil {
		t.Errorf("repo by ID: %v", err)
	}
	if err := create(worktree.CreateOptions{Name: "ok"}); err != nil {
		t.Error(err)
	}
	// The repo folder is not a git repo.
	plain := t.TempDir()
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI}, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(plain)}}}); err != nil {
		t.Fatal(err)
	}
	if err := create(worktree.CreateOptions{Name: "p", Repo: plain}); err == nil || !strings.Contains(err.Error(), "git") {
		t.Errorf("plain folder: %v", err)
	}
}

func TestCreateWithoutARemote(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "remote", "remove", "origin")
	if _, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "a"}); err == nil || !strings.Contains(err.Error(), "--base") {
		t.Fatalf("want a hint for --base, got %v", err)
	}
	res := e.create("b", "main")
	if res.Worktree.Base != "main" {
		t.Fatalf("base %q", res.Worktree.Base)
	}
}

func TestInspectShowsEachCheck(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree

	st := worktree.Inspect(w)
	if st.Missing || st.Changed != 0 || st.Unpushed != 0 || !st.Merged || st.MergedInto != "origin/main" {
		t.Fatalf("fresh: %+v", st)
	}
	// An uncommitted file, tracked or not.
	if err := os.WriteFile(filepath.Join(w.Path, "scratch.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(w.Path, "README.md"), []byte("changed\n"), 0o644)
	if st := worktree.Inspect(w); st.Changed != 2 {
		t.Fatalf("changed %d", st.Changed)
	}
	testutil.Git(t, w.Path, "add", ".")
	testutil.Git(t, w.Path, "commit", "-m", "work")
	st = worktree.Inspect(w)
	if st.Changed != 0 || st.Unpushed != 1 || st.Merged {
		t.Fatalf("committed: %+v", st)
	}
	testutil.Git(t, w.Path, "push", "origin", "work")
	st = worktree.Inspect(w)
	if st.Unpushed != 0 || st.Merged {
		t.Fatalf("pushed: %+v", st)
	}
	// The branch lands on main on the remote.
	testutil.Git(t, e.repo, "fetch", "origin")
	testutil.Git(t, e.repo, "merge", "--ff-only", "work")
	testutil.Git(t, e.repo, "push", "origin", "main")
	if st := worktree.Inspect(w); !st.Merged {
		t.Fatalf("merged: %+v", st)
	}

	// The folder is gone.
	os.RemoveAll(w.Path)
	st = worktree.Inspect(w)
	if !st.Missing || !st.Merged {
		t.Fatalf("missing: %+v", st)
	}
}

func TestInspectCountsCommitsOnADetachedHead(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	testutil.Git(t, w.Path, "checkout", "--detach")
	commit(t, w.Path, "lost.txt", "x\n")
	if st := worktree.Inspect(w); st.Unpushed != 1 {
		t.Fatalf("a commit on a detached HEAD must count: %+v", st)
	}
	if _, err := worktree.Remove(e.s, e.plot.ID, w.ID, worktree.RemoveOptions{}); !errors.Is(err, worktree.ErrUnsafe) {
		t.Fatalf("want a refusal, got %v", err)
	}
}

func TestList(t *testing.T) {
	e := setup(t)
	e.create("a", "")
	e.create("b", "")
	got, err := worktree.List(e.s, e.plot.ID)
	if err != nil || len(got) != 2 || got[0].Worktree.Name != "a" {
		t.Fatalf("%+v %v", got, err)
	}
	if all, err := worktree.List(e.s, ""); err != nil || len(all) != 2 {
		t.Fatalf("%v %v", all, err)
	}
	if none, err := worktree.List(e.s, "nosuchplot"); err != nil || none == nil || len(none) != 0 {
		t.Fatalf("%#v %v", none, err)
	}
}

func TestFind(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	for _, arg := range []string{w.ID, "feature", "app-feature", w.Path} {
		got, err := worktree.Find(e.s, e.plot.ID, "", arg)
		if err != nil || got.ID != w.ID {
			t.Errorf("find %q: %+v %v", arg, got, err)
		}
	}
	if _, err := worktree.Find(e.s, e.plot.ID, "", "nope"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("%v", err)
	}
	// The same name in a second repo is ambiguous until the repo is named.
	repo2, _ := testutil.GitRepo(t)
	lib := filepath.Join(filepath.Dir(repo2), "lib")
	if err := os.Rename(repo2, lib); err != nil {
		t.Fatal(err)
	}
	repo2 = lib
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI}, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(repo2)}}}); err != nil {
		t.Fatal(err)
	}
	w2, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: repo2, Name: "feature"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := worktree.Find(e.s, e.plot.ID, "", "feature"); err == nil || !strings.Contains(err.Error(), "--repo") {
		t.Errorf("want ambiguity: %v", err)
	}
	if got, err := worktree.Find(e.s, e.plot.ID, repo2, "feature"); err != nil || got.ID != w2.Worktree.ID {
		t.Errorf("%+v %v", got, err)
	}
	// A plot that does not own the worktree cannot find it.
	other, _ := e.s.CreatePlot(store.PlotInput{Name: "O", What: "w", Why: "y"}, store.Actor{Kind: store.ActorCLI})
	if _, err := worktree.Find(e.s, other.Plot.ID, "", w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("%v", err)
	}
}

func TestRemoveRefusesUnsafeWorktreesUnlessForced(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	rm := func(force bool) (*worktree.RemoveResult, error) {
		return worktree.Remove(e.s, e.plot.ID, w.ID, worktree.RemoveOptions{Force: force})
	}

	os.WriteFile(filepath.Join(w.Path, "scratch.txt"), []byte("x"), 0o644)
	if _, err := rm(false); !errors.Is(err, worktree.ErrUnsafe) || !strings.Contains(err.Error(), "uncommitted") {
		t.Fatalf("dirty: %v", err)
	}
	if _, err := os.Stat(w.Path); err != nil {
		t.Fatal("folder removed")
	}
	testutil.Git(t, w.Path, "add", ".")
	testutil.Git(t, w.Path, "commit", "-m", "work")
	if _, err := rm(false); !errors.Is(err, worktree.ErrUnsafe) || !strings.Contains(err.Error(), "not pushed") {
		t.Fatalf("unpushed: %v", err)
	}
	if _, err := e.s.GetWorktree(w.ID); err != nil {
		t.Fatal("record removed")
	}
	// Forced: it goes, with the dirty file and the unpushed commit.
	os.WriteFile(filepath.Join(w.Path, "more.txt"), []byte("x"), 0o644)
	res, err := rm(true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(w.Path); !os.IsNotExist(err) {
		t.Fatal("folder still there")
	}
	if _, err := e.s.GetWorktree(w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("record still there")
	}
	// The unpushed commit keeps the branch: git branch -d refuses.
	if res.BranchDeleted || res.BranchNote == "" {
		t.Fatalf("%+v", res)
	}
	if out := testutil.Git(t, e.repo, "branch", "--list", "work"); out == "" {
		t.Fatal("the branch is gone")
	}
}

func TestRemoveDeletesTheMergedLocalBranchAndNeverTheRemoteBranch(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	commit(t, w.Path, "f.txt", "f\n")
	testutil.Git(t, w.Path, "push", "origin", "work")
	// Land it on main, locally and on the remote.
	testutil.Git(t, e.repo, "merge", "--ff-only", "work")
	testutil.Git(t, e.repo, "push", "origin", "main")

	res, err := worktree.Remove(e.s, e.plot.ID, "work", worktree.RemoveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !res.BranchDeleted {
		t.Fatalf("%+v", res)
	}
	if out := testutil.Git(t, e.repo, "branch", "--list", "work"); out != "" {
		t.Fatalf("local branch left: %s", out)
	}
	if out := testutil.Git(t, e.repo, "ls-remote", "--heads", "origin", "work"); out == "" {
		t.Fatal("the remote branch was deleted")
	}
}

func TestRemoveKeepsAPushedBranchThatIsNotMerged(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	commit(t, w.Path, "f.txt", "f\n")
	testutil.Git(t, w.Path, "push", "origin", "work")
	res, err := worktree.Remove(e.s, e.plot.ID, "work", worktree.RemoveOptions{})
	if err != nil {
		t.Fatalf("a pushed branch is safe to remove: %v", err)
	}
	if res.BranchDeleted || !strings.Contains(res.BranchNote, "work") {
		t.Fatalf("%+v", res)
	}
	if out := testutil.Git(t, e.remote, "branch", "--list", "work"); out == "" {
		t.Fatal("the remote branch is gone")
	}
}

func TestRemoveRefusesWhilePanesAreOpen(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	rm := func(force bool, panes ...string) error {
		_, err := worktree.Remove(e.s, e.plot.ID, w.ID, worktree.RemoveOptions{Force: force, OpenPanes: panes})
		return err
	}
	// A pane in a subfolder counts. Force does not skip this check.
	sub := filepath.Join(w.Path, "sub")
	os.MkdirAll(sub, 0o755)
	if err := rm(true, sub); !errors.Is(err, worktree.ErrPanesOpen) {
		t.Fatalf("flag: %v", err)
	}
	// A pane elsewhere does not.
	// state.json: saved panes that have not resumed yet count too.
	appDir := t.TempDir()
	t.Setenv("LOAM_APP_STATE_DIR", appDir)
	state := `{"panes":[{"plot_id":"` + e.plot.ID + `","folder":"` + w.Path + `"}],"other":1}`
	if err := os.WriteFile(filepath.Join(appDir, "state.json"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := rm(false); !errors.Is(err, worktree.ErrPanesOpen) {
		t.Fatalf("state.json: %v", err)
	}
	if _, err := e.s.GetWorktree(w.ID); err != nil {
		t.Fatal("record removed")
	}
	// Panes in other folders do not block. The name of a sibling folder is not a match.
	state = `{"panes":[{"plot_id":"x","folder":"` + w.Path + `-2"},{"plot_id":"x","folder":"` + e.repo + `"}]}`
	os.WriteFile(filepath.Join(appDir, "state.json"), []byte(state), 0o644)
	if err := rm(false, e.repo); err != nil {
		t.Fatal(err)
	}
}

func TestOpenPanes(t *testing.T) {
	home := t.TempDir()
	got, err := worktree.OpenPanes(home, nil)
	if err != nil || len(got) != 0 {
		t.Fatalf("missing file: %v %v", got, err)
	}
	os.WriteFile(filepath.Join(home, "state.json"), []byte(`{"panes":[{"plot_id":"p","folder":"/a"},{"plot_id":"p","folder":""}]}`), 0o644)
	got, err = worktree.OpenPanes(home, []string{"/b"})
	if err != nil || len(got) != 2 || got[0].Folder != "/a" || got[1].Folder != "/b" {
		t.Fatalf("%+v %v", got, err)
	}
	os.WriteFile(filepath.Join(home, "state.json"), []byte(`{not json`), 0o644)
	if _, err := worktree.OpenPanes(home, nil); err == nil || !strings.Contains(err.Error(), "state.json") {
		t.Fatalf("want an error that names state.json: %v", err)
	}
}

func TestRemoveWhenTheFolderIsGone(t *testing.T) {
	e := setup(t)
	w := e.create("work", "").Worktree
	os.RemoveAll(w.Path)
	res, err := worktree.Remove(e.s, e.plot.ID, w.ID, worktree.RemoveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !res.BranchDeleted {
		t.Fatalf("%+v", res)
	}
	if _, err := e.s.GetWorktree(w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("record still there")
	}
	// Git forgot the worktree, so the name can be used again.
	e.create("work", "")
}
