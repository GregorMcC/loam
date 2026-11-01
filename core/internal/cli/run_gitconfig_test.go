package cli

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// includeInGlobalConfig adds an include of target to the global git config of
// the test.
func includeInGlobalConfig(t *testing.T, target string) {
	t.Helper()
	f, err := os.OpenFile(os.Getenv("GIT_CONFIG_GLOBAL"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString("[include]\n\tpath = " + target + "\n"); err != nil {
		t.Fatal(err)
	}
}

// TAS-191: a run does not start with a git config include in a write path. It
// is stopped, and the note says why. No session starts.
func TestRunStartStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, p := runCLI(t)
	target := filepath.Join(p.Repos[0].Path, ".git", "team.gitconfig")
	includeInGlobalConfig(t, target)
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "A run", "--json"); err == nil {
		t.Fatal("run start gives no error")
	}
	runs, err := s.ListRuns(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].State != store.RunStopped || !strings.Contains(runs[0].Note, target) || !strings.Contains(runs[0].Note, "Remove the include") {
		t.Fatalf("runs %+v, want one stopped run with a note on %s", runs, target)
	}
	if got := bgStarts(t); len(got) != 0 {
		t.Fatalf("session starts %q, want none", got)
	}
}

// TAS-191: the same check runs before a resume, and a failure there stops the
// run. The session gets no prompt.
func TestRunSendBackStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, r, _ := readyRun(t)
	before := len(testutil.FakeClaudeCalls(t))
	target := filepath.Join(r.Folder, "team.gitconfig")
	includeInGlobalConfig(t, target)
	if _, code, out := sendBack(t, r.ID, "--note", "Add a test."); code == 0 {
		t.Fatalf("send-back exits 0: %s", out)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || !strings.Contains(got.Note, target) {
		t.Fatalf("run %+v, want stopped with a note on %s", got, target)
	}
	for _, c := range testutil.FakeClaudeCalls(t)[before:] {
		if slices.Contains(c, "--resume") {
			t.Fatalf("the session got a prompt: %q", c)
		}
	}
}

// TAS-191: the gate builds the rules again, and runs no check when the config
// changed so that the run can write it.
func TestRunGateStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, r := gateRun(t, "3")
	target := filepath.Join(r.Folder, "team.gitconfig")
	includeInGlobalConfig(t, target)
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || got.Tries != 0 || !strings.Contains(got.Note, target) {
		t.Fatalf("after the gate: %+v, want stopped with a note on %s", got, target)
	}
}

// TAS-191: a check of the gate can write the commondir file after Loam builds
// the rules, and a tick then runs git with no new check. The file names a copy
// of the git folder whose config sets a hook folder of the run. Git of Loam
// ignores it: the hook does not run, and the push and the PR go on.
func TestRunTickIgnoresAConfigThatACommondirFileNames(t *testing.T) {
	s, r, w := shipRun(t, "3")
	git := filepath.Join(w.Repo, ".git")
	admin := filepath.Join(git, "worktrees", filepath.Base(r.Folder))
	if _, err := os.Stat(filepath.Join(admin, "commondir")); err != nil {
		t.Fatal(err)
	}
	fake := filepath.Join(r.Folder, "fake")
	for _, d := range []string{"refs", "hooks"} {
		if err := os.MkdirAll(filepath.Join(fake, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(git, "objects"), filepath.Join(fake, "objects")); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, r.Folder, "pack-refs", "--all")
	copyFile := func(from, to string) {
		t.Helper()
		b, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(to, b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	copyFile(filepath.Join(git, "packed-refs"), filepath.Join(fake, "packed-refs"))
	copyFile(filepath.Join(git, "HEAD"), filepath.Join(fake, "HEAD"))
	copyFile(filepath.Join(git, "config"), filepath.Join(fake, "config"))
	f, err := os.OpenFile(filepath.Join(fake, "config"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("[core]\n\thooksPath = " + filepath.Join(fake, "hooks") + "\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	marker := filepath.Join(t.TempDir(), "hook-ran")
	hook := "#!/bin/sh\ntouch '" + marker + "'\n"
	if err := os.WriteFile(filepath.Join(fake, "hooks", "pre-push"), []byte(hook), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(admin, "commondir"), []byte(fake+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := testutil.Git(t, r.Folder, "config", "core.hooksPath"); got != filepath.Join(fake, "hooks") {
		t.Fatalf("git does not follow the commondir file: %q", got)
	}
	tick(t)
	if _, err := os.Stat(marker); err == nil {
		t.Error("the hook of the config that the commondir file names ran outside the sandbox")
	}
	if e := events(t, s, r.ID, "ship"); !slices.ContainsFunc(e, func(x string) bool { return strings.HasPrefix(x, "Opened") }) {
		t.Errorf("ship events %q, want the push and the PR", e)
	}
}
