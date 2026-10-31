package run

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// fakeBox returns a check box with the fake sandbox-exec of the test harness,
// which runs each check with no sandbox.
func fakeBox(t *testing.T) checkBox {
	t.Helper()
	testutil.FakeSandbox(t)
	return checkBox{exec: os.Getenv("LOAM_SANDBOX_EXEC"), profile: "(version 1)\n"}
}

// A check after the end of the gate budget fails and does not run.
func TestRunCheckDoesNotRunAfterTheBudget(t *testing.T) {
	dir := t.TempDir()
	box := fakeBox(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := runCheck(ctx, dir, box, store.Check{Name: "Touch", Command: "touch ran"})
	if res.passed || !strings.Contains(res.output, "ran out of time") {
		t.Fatalf("%+v", res)
	}
	if res = runCheck(context.Background(), dir, box, store.Check{Name: "Ls", Command: "ls ran"}); res.passed {
		t.Fatalf("the check ran after the budget: %+v", res)
	}
}

// TAS-175: with no sandbox, a check fails closed: it does not run, and its
// output says why.
func TestRunCheckDoesNotRunWithNoSandbox(t *testing.T) {
	dir := t.TempDir()
	box := checkBox{err: errors.New("/usr/bin/sandbox-exec is missing")}
	res := runCheck(context.Background(), dir, box, store.Check{Name: "Touch", Command: "touch ran"})
	if res.passed || res.exit != -1 || !strings.Contains(res.output, "could not sandbox it: /usr/bin/sandbox-exec is missing") {
		t.Fatalf("%+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "ran")); err == nil {
		t.Fatal("the check ran with no sandbox")
	}
}

// TAS-175: SwiftPM sandboxes its manifest, and that sandbox cannot start in
// the sandbox of the checks. A check that fails on it gets one line that says
// what to pass. A check that passes, or fails on something else, gets none.
func TestRunCheckNamesTheFlagForANestedSandbox(t *testing.T) {
	dir := t.TempDir()
	box := fakeBox(t)
	nested := "echo 'sandbox-exec: sandbox_apply: Operation not permitted' >&2"
	cases := []struct {
		command string
		note    bool
	}{
		{nested + "; exit 1", true},
		{nested, false},
		{"echo boom; exit 1", false},
	}
	for _, c := range cases {
		res := runCheck(context.Background(), dir, box, store.Check{Name: "Build", Command: c.command})
		if got := strings.Contains(res.output, "pass --disable-sandbox to swift build, swift test, and swift package"); got != c.note {
			t.Errorf("%q: note %v, output:\n%s", c.command, got, res.output)
		}
		if c.note && strings.Count(res.output, "\n") != 1 {
			t.Errorf("%q: want one line after the output:\n%s", c.command, res.output)
		}
	}
}

// Work committed reads the stdout of git status only: a warning on stderr,
// as from an xcrun shim, does not fail it. A line on stdout does, and a git
// that fails does, with its error.
func TestCommittedReadsOnlyTheStdoutOfGit(t *testing.T) {
	box := fakeBox(t)
	bin := t.TempDir()
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	cases := []struct {
		git, want string
		passed    bool
	}{
		{"echo 'xcodebuild: Failed to start fs event stream.' >&2", "fs event stream", true},
		{"echo ' M main.go'", "These files are not committed. Commit them, or add them to .gitignore:\n M main.go", false},
		{"echo 'fatal: not a git repository' >&2; exit 128", "fatal: not a git repository", false},
	}
	for _, c := range cases {
		if err := os.WriteFile(filepath.Join(bin, "git"), []byte("#!/bin/sh\n"+c.git+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		res := committed(context.Background(), t.TempDir(), box)
		if res.passed != c.passed || !strings.Contains(res.output, c.want) || res.check.Command != "git status --porcelain" {
			t.Errorf("git %q: %+v, want passed %v and %q", c.git, res, c.passed, c.want)
		}
	}
}

// The xcrun cache of a gate starts as a copy of the cache of the user, so a
// shim does not run xcodebuild to fill it.
func TestSeedXcrunCacheCopiesTheCacheOfTheUser(t *testing.T) {
	src := filepath.Join(t.TempDir(), "xcrun_db")
	if err := os.WriteFile(src, []byte("XR1L"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := userXcrunCache
	t.Cleanup(func() { userXcrunCache = old })
	userXcrunCache = func() string { return src }
	cache := filepath.Join(t.TempDir(), "xcrun_db")
	seedXcrunCache(cache)
	if b, err := os.ReadFile(cache); err != nil || string(b) != "XR1L" {
		t.Errorf("cache = %q, %v, want a copy", b, err)
	}
	// With no cache of the user, the gate starts with none.
	userXcrunCache = func() string { return filepath.Join(t.TempDir(), "none") }
	cache = filepath.Join(t.TempDir(), "xcrun_db")
	seedXcrunCache(cache)
	if _, err := os.Stat(cache); !os.IsNotExist(err) {
		t.Errorf("cache with no cache of the user: %v", err)
	}
}

// GOPROXY of the checks names the module cache as a file URL. A cache path
// that would split the list of GOPROXY gives no GOPROXY.
func TestGoProxyNamesTheModuleCacheAsOneFileURL(t *testing.T) {
	for _, c := range []struct{ cache, want string }{
		{"/c/mod", "file:///c/mod/cache/download"},
		{"/c/my mod", "file:///c/my%20mod/cache/download"},
		{"/c/a,b", ""},
		{"/c/a|b", ""},
	} {
		t.Setenv("GOMODCACHE", c.cache)
		if got := goProxy(); got != c.want {
			t.Errorf("GOMODCACHE %q: GOPROXY %q, want %q", c.cache, got, c.want)
		}
	}
}

// A root that the gate cannot write gives way to the next one, and the gate
// says why when no root works.
func TestMakeGateDirTriesTheNextRoot(t *testing.T) {
	blocked := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	next := t.TempDir()
	dir, err := makeGateDir(blocked, next)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(dir) != next || !strings.HasPrefix(filepath.Base(dir), "loam-gate-") {
		t.Errorf("dir = %q, want a loam-gate- folder in %q", dir, next)
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Errorf("stat %s: %v, %v", dir, fi, err)
	}
	if _, err := makeGateDir(blocked); err == nil || !strings.Contains(err.Error(), blocked) {
		t.Errorf("err = %v, want one that names %s", err, blocked)
	}
}

// A relative root, such as a relative TMPDIR, still gives an absolute folder.
func TestMakeGateDirIsAbsolute(t *testing.T) {
	t.Chdir(t.TempDir())
	dir, err := makeGateDir(".")
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(dir) {
		t.Errorf("dir = %q, want an absolute path", dir)
	}
}

// When the gate cannot write /tmp, as in a sandbox, newCheckBox makes its
// folder in the next root, and a check gets that folder as TMPDIR.
func TestNewCheckBoxFallsBackWhenTmpIsDenied(t *testing.T) {
	testutil.GitEnv(t)
	testutil.FakeSandbox(t)
	repo, _ := testutil.GitRepo(t)
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	res, err := s.CreatePlot(store.PlotInput{Name: "Gate", Repos: []store.RepoInput{{Path: repo}}}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	denied := filepath.Join(t.TempDir(), "tmp")
	if err := os.WriteFile(denied, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	fallback := t.TempDir()
	old := gateRoots
	gateRoots = func() []string { return []string{denied, fallback} }
	t.Cleanup(func() { gateRoots = old })

	box := newCheckBox(s, store.Run{PlotID: res.Plot.ID, Folder: repo})
	defer box.close()
	if box.err != nil {
		t.Fatal(box.err)
	}
	if filepath.Dir(box.dir) != fallback {
		t.Fatalf("dir = %q, want a folder in %q", box.dir, fallback)
	}
	got := runCheck(context.Background(), repo, box, store.Check{Name: "Tmp", Command: `printf %s "$TMPDIR"`})
	if !got.passed || got.output != box.dir {
		t.Fatalf("TMPDIR of the check = %q (%+v), want %q", got.output, got, box.dir)
	}
}
