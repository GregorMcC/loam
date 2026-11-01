package gitcmd_test

import (
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/gitcmd"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func real(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func write(t *testing.T, name, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCommonDir(t *testing.T) {
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	repo = real(t, repo)
	wt := filepath.Join(real(t, t.TempDir()), "wt")
	testutil.Git(t, repo, "worktree", "add", "-q", wt)
	git := filepath.Join(repo, ".git")
	sub := filepath.Join(wt, "a", "b")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	module := real(t, t.TempDir())
	write(t, filepath.Join(module, ".git"), "gitdir: ../somewhere/modules/x\n")
	broken := real(t, t.TempDir())
	write(t, filepath.Join(broken, ".git"), "not a gitdir\n")
	for dir, want := range map[string]string{
		repo:                   git,
		wt:                     git,
		sub:                    git,
		filepath.Join(git):     git,
		module:                 "",
		broken:                 "",
		real(t, t.TempDir()):   "",
		filepath.Join(wt, "x"): git,
	} {
		if got := gitcmd.CommonDir(dir); got != want {
			t.Errorf("CommonDir(%s) = %q, want %q", dir, got, want)
		}
	}
}

// fakeCommon makes a folder that git takes as a common git folder. Its config
// sets user.email and turns the extension on.
func fakeCommon(t *testing.T, dir string) {
	t.Helper()
	write(t, filepath.Join(dir, "config"), "[user]\n\temail = fake@example.com\n[extensions]\n\tworktreeConfig = true\n")
	write(t, filepath.Join(dir, "HEAD"), "ref: refs/heads/main\n")
	for _, d := range []string{"objects", "refs"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func email(t *testing.T, dir string) string {
	t.Helper()
	out, err := gitcmd.Command(context.Background(), dir, "config", "user.email").Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}

// Each way that a run can make git take another folder as the common git
// folder: git with no setting follows it, and a command of Loam does not.
func TestCommandIgnoresTheConfigThatACommondirFileNames(t *testing.T) {
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	repo = real(t, repo)
	wt := filepath.Join(real(t, t.TempDir()), "wt")
	testutil.Git(t, repo, "worktree", "add", "-q", wt)
	const want = "test@example.com"
	admin := filepath.Join(repo, ".git", "worktrees", "wt")
	fake := filepath.Join(wt, "fake")
	fakeCommon(t, fake)
	write(t, filepath.Join(admin, "config.worktree"), "[user]\n\temail = worktree@example.com\n")

	write(t, filepath.Join(admin, "commondir"), fake+"\n")
	if got := testutil.Git(t, wt, "config", "user.email"); got == want {
		t.Fatalf("git does not follow the file of the worktree: %q", got)
	}
	if got := email(t, wt); got != want {
		t.Errorf("a commondir file in the metadata folder: user.email %q, want %q", got, want)
	}
	write(t, filepath.Join(admin, "commondir"), "../..\n")

	// With no commondir file, git takes the metadata folder as the git folder.
	fakeCommon(t, admin)
	if err := os.Remove(filepath.Join(admin, "commondir")); err != nil {
		t.Fatal(err)
	}
	if got := email(t, wt); got != want {
		t.Errorf("no commondir file: user.email %q, want %q", got, want)
	}
	write(t, filepath.Join(admin, "commondir"), "../..\n")

	file := filepath.Join(repo, ".git", "commondir")
	write(t, file, fake+"\n")
	if got := testutil.Git(t, repo, "config", "user.email"); got == want {
		t.Fatalf("git does not follow the file of the main checkout: %q", got)
	}
	if got := email(t, repo); got != want {
		t.Errorf("a commondir file in the git folder: user.email %q, want %q", got, want)
	}
}

// The work of a worktree goes on with the setting.
func TestCommandWorksInAWorktree(t *testing.T) {
	testutil.GitEnv(t)
	repo, remote := testutil.GitRepo(t)
	repo = real(t, repo)
	wt := filepath.Join(real(t, t.TempDir()), "wt")
	run := func(dir string, args ...string) string {
		t.Helper()
		out, err := gitcmd.Command(context.Background(), dir, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("git %q: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	run(repo, "worktree", "add", "-q", "-b", "work", wt)
	write(t, filepath.Join(wt, "a.txt"), "a\n")
	run(wt, "add", "a.txt")
	run(wt, "commit", "-q", "-m", "a")
	run(wt, "push", "-q", "origin", "work:refs/heads/work")
	run(wt, "branch", "--set-upstream-to=origin/work", "work")
	run(wt, "fetch", "-q", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
	if got := run(wt, "rev-parse", "refs/heads/work"); got != testutil.Git(t, remote, "rev-parse", "refs/heads/work") {
		t.Errorf("work = %s, and the remote does not have it", got)
	}
	if got := testutil.Git(t, repo, "config", "branch.work.remote"); got != "origin" {
		t.Errorf("branch.work.remote = %q, want origin in the config of the repo", got)
	}
	if got := run(wt, "rev-parse", "--path-format=absolute", "--git-common-dir"); got != filepath.Join(repo, ".git") {
		t.Errorf("git-common-dir = %q", got)
	}
	run(repo, "worktree", "remove", "--force", wt)
	if strings.Contains(run(repo, "worktree", "list"), wt) {
		t.Error("the worktree is still in the list")
	}
}

// With GIT_DIR set, git does not look in dir, so the setting would name the
// wrong repo.
// Loam can inherit these variables from a git hook that starts it. Each command
// here names its folder, so git acts on that folder, with the setting that keeps
// out a commondir file. With GIT_DIR, -C does not choose the repo.
func TestEnvDropsTheRepoOfTheEnvironment(t *testing.T) {
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	git := real(t, filepath.Join(repo, ".git"))
	for _, k := range repoVars {
		t.Setenv(k, filepath.Join(other, ".git"))
	}
	env := gitcmd.Env(repo)
	for _, k := range repoVars {
		if k != "GIT_COMMON_DIR" && slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, k+"=") }) {
			t.Errorf("Env keeps %s", k)
		}
	}
	if !slices.Contains(env, "GIT_COMMON_DIR="+git) || slices.Contains(env, "GIT_COMMON_DIR="+filepath.Join(other, ".git")) {
		t.Errorf("Env does not set GIT_COMMON_DIR to %s", git)
	}
	if env := gitcmd.Env(t.TempDir()); slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, "GIT_COMMON_DIR=") }) {
		t.Error("Env keeps GIT_COMMON_DIR for a folder in no repo")
	}
	out, err := gitcmd.Command(context.Background(), repo, "rev-parse", "--absolute-git-dir").Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(out)); real(t, got) != git {
		t.Errorf("git acts on %s, want %s", got, git)
	}
}

func TestNoRepoEnvDropsTheRepoOfTheEnvironment(t *testing.T) {
	for _, k := range repoVars {
		t.Setenv(k, "/inherited")
	}
	env := gitcmd.NoRepoEnv()
	for _, k := range repoVars {
		if slices.Contains(env, k+"=/inherited") {
			t.Errorf("NoRepoEnv keeps %s", k)
		}
	}
	if !slices.Contains(env, "GIT_DIR="+gitcmd.NoRepoDir) {
		t.Errorf("no GIT_DIR=%s", gitcmd.NoRepoDir)
	}
}

// repoVars are the variables that choose a repo or a part of it.
var repoVars = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
	"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_PREFIX", "GIT_NAMESPACE",
}

// Each git of Loam goes through this package. session/run.go runs git config
// with --file, or with GIT_COMMON_DIR that it sets itself, from the root.
func TestLoamRunsGitOnlyThroughThisPackage(t *testing.T) {
	direct := regexp.MustCompile(`exec\.Command(Context)?\([^\n]*"git"`)
	root := filepath.Join("..")
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if slices.Contains([]string{filepath.Join("gitcmd", "gitcmd.go"), filepath.Join("session", "run.go"), filepath.Join("testutil", "git.go")}, rel) {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if m := direct.Find(b); m != nil {
			t.Errorf("%s runs git with no gitcmd: %s", rel, m)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// With [gitcmd.NoRepoEnv], git finds no repo, so it reads no config of the run
// and starts nothing in a nested repo. A .gitmodules entry cannot change this,
// though it can undo -c diff.ignoreSubmodules=all.
func TestNoRepoEnvStartsNoGitInANestedRepo(t *testing.T) {
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	sub := filepath.Join(repo, "sub")
	testutil.Git(t, repo, "init", "-q", "sub")
	testutil.Git(t, sub, "commit", "-q", "--allow-empty", "-m", "nested")
	marker := filepath.Join(t.TempDir(), "fsmonitor-ran")
	command := filepath.Join(t.TempDir(), "fsmonitor.sh")
	write(t, command, "#!/bin/sh\ntouch '"+marker+"'\n")
	if err := os.Chmod(command, 0o755); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, sub, "config", "core.fsmonitor", command)
	testutil.Git(t, repo, "add", "sub")
	write(t, filepath.Join(repo, ".gitmodules"), "[submodule \"sub\"]\n\tpath = sub\n\turl = ./sub\n\tignore = none\n")
	testutil.Git(t, repo, "add", ".gitmodules")

	testutil.Git(t, repo, "status", "--porcelain")
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("this test does not show the fault: git without the setting did not start the command: %v", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("git", "status", "--porcelain")
	cmd.Dir, cmd.Env = repo, gitcmd.NoRepoEnv()
	if err := cmd.Run(); err == nil {
		t.Error("git found a repo")
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("the command in the config of the nested repo ran")
	}
}

// Outside the sandbox, these commands of Loam start git in a nested repo unless
// they say not to, and that git reads the config of the nested repo.
func TestLoamGitStartsNoGitInANestedRepo(t *testing.T) {
	call := regexp.MustCompile(`(?:\bgit|gitContext|gitOut|gitcmd\.Command)\([^\n]*"(fetch|status|switch)"[^\n]*`)
	want := map[string]string{"fetch": `"--no-recurse-submodules"`, "status": `"--ignore-submodules=all"`, "switch": `"-q"`}
	seen := map[string]int{}
	root := filepath.Join("..")
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, m := range call.FindAllSubmatch(b, -1) {
			name := string(m[1])
			seen[name]++
			if !strings.Contains(string(m[0]), want[name]) {
				t.Errorf("%s: git %s has no %s: %s", path, name, want[name], m[0])
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for name := range want {
		if seen[name] == 0 {
			t.Errorf("the scan found no git %s, so it no longer reads the code", name)
		}
	}
}
