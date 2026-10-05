package testutil

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// GitEnv points git at a clean global config for the test, with an author and
// main as the default branch. Call it before you make a repo.
func GitEnv(t *testing.T) {
	t.Helper()
	cfg := filepath.Join(t.TempDir(), "gitconfig")
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
