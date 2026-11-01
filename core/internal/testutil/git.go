package testutil

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// packageDir is the folder of the package under test: the folder that go test
// starts the test binary in, before any test changes it.
var packageDir, _ = os.Getwd()

// GitEnv points git at a clean global config for the test, with an author and
// main as the default branch. Call it before you make a repo. The config is not
// in the temporary folder: a run can write that folder, so a run does not start
// with its global config there. Git names the file of the config for the rules
// of a run, so a run in a test goes through the same check as a real one.
func GitEnv(t *testing.T) {
	t.Helper()
	dir, err := os.MkdirTemp(packageDir, ".gitenv-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	cfg := filepath.Join(dir, "gitconfig")
	body := "[user]\n\tname = Loam Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n"
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", cfg)
	t.Setenv("GIT_CONFIG_SYSTEM", os.DevNull)
	t.Setenv("GIT_TERMINAL_PROMPT", "0")
}

// Git runs git in dir and returns its trimmed output. It fails the test on error.
func Git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	b, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, b)
	}
	return strings.TrimSpace(string(b))
}

// GitRepo makes a bare remote and a clone of it, with one commit on main that
// is pushed. It returns the clone and the remote. Call [GitEnv] first.
func GitRepo(t *testing.T) (repo, remote string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return GitRepoAt(t, filepath.Join(root, "remote.git"), filepath.Join(root, "repos", "app"))
}

// GitRepoAt is [GitRepo] with the paths of the remote and the clone.
func GitRepoAt(t *testing.T, remote, repo string) (string, string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(repo), 0o755); err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(remote)
	Git(t, root, "init", "--bare", "-b", "main", remote)
	Git(t, root, "clone", remote, repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	Git(t, repo, "add", ".")
	Git(t, repo, "commit", "-m", "first")
	Git(t, repo, "push", "-u", "origin", "main")
	Git(t, repo, "remote", "set-head", "origin", "main")
	return repo, remote
}

// GitHubOrigin is the origin of a made-up GitHub repo, example/widgets, over
// SSH. [FakeGitHub] makes git reach it with no network.
const GitHubOrigin = "git@github.com:example/widgets.git"

// FakeGitHub makes git reach every repo on github.com over SSH through a fake
// ssh that serves the local bare repo remote. A repo whose origin is
// [GitHubOrigin] is then on GitHub for Loam, and git can still fetch from it
// and push to it. Call it before you run a command that fetches.
func FakeGitHub(t *testing.T, remote string) {
	t.Helper()
	ssh := filepath.Join(t.TempDir(), "fake-ssh")
	// With the simple variant, git runs: <ssh> <host> "<git program> '<repo>'".
	script := "#!/bin/sh\nprog=${2%% *}\nexec git \"${prog#git-}\" '" + remote + "'\n"
	if err := os.WriteFile(ssh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_SSH_COMMAND", ssh)
	t.Setenv("GIT_SSH_VARIANT", "simple")
}
