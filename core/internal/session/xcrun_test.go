package session_test

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-216: the session of a run gets a private xcrun cache, so the xcrun
// shims in its sandbox, such as /usr/bin/git, do not miss the cache. The
// cache is a copy of the cache of the user, in the private folder of the run,
// which the sandbox lets Bash write. The cache of the user stays denied. The
// env of the settings does not set xcrun_db, because Claude Code, its hooks,
// and its MCP servers get that env outside the sandbox: only Bash gets it,
// from the SessionStart hook. A resume makes the folder again.
func TestPrepareRunGivesTheSessionAPrivateXcrunCache(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	r := store.Run{ID: "r1", PlotID: p.ID, Folder: repo, SessionID: "11111111-2222-4333-8444-555555555555"}
	dir := session.RunTemp(e.store, r.ID)
	if !strings.HasPrefix(dir, e.store.Home()+string(filepath.Separator)) {
		t.Errorf("RunTemp = %s, want a folder in the Loam home %s", dir, e.store.Home())
	}
	for _, prepare := range []func() (*session.Plan, error){
		func() (*session.Plan, error) { return session.PrepareRun(e.store, r, "go", "loam", "", "") },
		func() (*session.Plan, error) { return session.PrepareRunResume(e.store, r, "go on", "loam", "", "") },
	} {
		if err := os.RemoveAll(dir); err != nil {
			t.Fatal(err)
		}
		plan, err := prepare()
		if err != nil {
			t.Fatal(err)
		}
		if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
			t.Fatalf("the private folder %s: %v, want a folder", dir, err)
		}
		cache := filepath.Join(dir, sandbox.PrivateXcrunCache)
		if user, err := os.ReadFile(sandbox.XcrunCache()); err == nil {
			if b, err := os.ReadFile(cache); err != nil || len(b) != len(user) {
				t.Errorf("the private cache has %d bytes, %v, want a copy of the %d bytes of the user", len(b), err, len(user))
			}
		}
		got := readRunSettings(t, plan)
		fs := got.Sandbox.Filesystem
		real := realpath(t, dir)
		if !slices.Contains(fs.AllowWrite, real) || !slices.Contains(fs.AllowRead, real) {
			t.Errorf("allowRead = %q, allowWrite = %q, want the private folder %s", fs.AllowRead, fs.AllowWrite, real)
		}
		if c := sandbox.XcrunCache(); c != "" && !slices.Contains(fs.DenyWrite, c+"*") {
			t.Errorf("denyWrite = %q, want the cache of the user %s", fs.DenyWrite, c)
		}
		if v, ok := got.Env["xcrun_db"]; ok {
			t.Errorf("env sets xcrun_db = %q, which reaches the processes outside the sandbox", v)
		}
		if want := "export xcrun_db='" + cache + "'\n"; session.RunBashEnv(e.store, r.ID) != want {
			t.Errorf("RunBashEnv = %q, want %q", session.RunBashEnv(e.store, r.ID), want)
		}
	}
	if err := session.RemoveRunTemp(e.store, r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Errorf("the private folder after RemoveRunTemp: %v, want none", err)
	}
}

// The session can write its private folder, so it can put a link there.
// Loam makes a new folder in its place and does not write through the link.
func TestPrepareRunReplacesALinkAtThePrivateFolder(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	r := store.Run{ID: "r1", PlotID: p.ID, Folder: repo}
	dir := session.RunTemp(e.store, r.ID)
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, dir); err != nil {
		t.Fatal(err)
	}
	plan, err := session.PrepareRun(e.store, r, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
		t.Fatalf("the private folder %s: %v, want a folder", dir, err)
	}
	if entries, err := os.ReadDir(target); err != nil || len(entries) != 0 {
		t.Errorf("the target of the link has %v, %v, want nothing", entries, err)
	}
	if fs := readRunSettings(t, plan).Sandbox.Filesystem; slices.Contains(fs.AllowWrite, realpath(t, target)) {
		t.Errorf("allowWrite = %q has the target of the link", fs.AllowWrite)
	}
}
