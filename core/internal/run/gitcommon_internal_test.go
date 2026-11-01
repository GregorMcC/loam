package run

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// gitWorktree returns a worktree of a new repo, and the git folder of that
// repo with its links resolved.
func gitWorktree(t *testing.T) (folder, git string) {
	t.Helper()
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	folder = filepath.Join(t.TempDir(), "wt")
	testutil.Git(t, repo, "worktree", "add", "-q", "-b", "work", folder)
	git, err := filepath.EvalSymlinks(filepath.Join(repo, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	return folder, git
}

// wantGitCommonDir checks that the fake claude ran in folder with
// GIT_COMMON_DIR set to git. Git then takes neither the config nor the hooks
// of a folder that a commondir file in the worktree metadata names.
func wantGitCommonDir(t *testing.T, folder, git string) {
	t.Helper()
	inv := testutil.FakeClaudeInvocation(t)
	if got, want := resolvedPath(t, inv.Cwd), resolvedPath(t, folder); got != want {
		t.Errorf("claude ran in %q, want %q", got, want)
	}
	got, ok := inv.Env["GIT_COMMON_DIR"]
	if !ok {
		t.Fatal("claude ran in the run folder with no GIT_COMMON_DIR, so the git that it starts follows a commondir file")
	}
	if got := resolvedPath(t, got); got != git {
		t.Errorf("GIT_COMMON_DIR is %q, want %q", got, git)
	}
}

func resolvedPath(t *testing.T, path string) string {
	t.Helper()
	got, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// The code review and the PR text run claude -p outside the sandbox in the
// run folder, and no new check runs before them.
func TestRunPrintSetsGitCommonDir(t *testing.T) {
	folder, git := gitWorktree(t)
	testutil.FakeClaude(t)
	testutil.FakeClaudePrint(t, `{"structured_output":{"ok":true}}`)
	out, why := runPrint(context.Background(), "claude", folder, []string{"-p", "ask", "--json-schema", "{}"}, "text")
	if why != "" {
		t.Fatal(why)
	}
	if !json.Valid(out) {
		t.Errorf("output %q", out)
	}
	wantGitCommonDir(t, folder, git)
}

// A draft of a run runs claude -p outside the sandbox in a folder that an
// earlier run of the worktree could write.
func TestAskClaudeSetsGitCommonDir(t *testing.T) {
	folder, git := gitWorktree(t)
	testutil.FakeClaude(t)
	trust := map[string]any{"projects": map[string]any{folder: map[string]bool{"hasTrustDialogAccepted": true}}}
	b, err := json.Marshal(trust)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), ".claude.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	testutil.FakeClaudePrint(t, `{"structured_output":{"ok":true}}`)
	r := store.Run{ID: "r", Folder: folder, Shape: &store.RunShape{}}
	prompt := func(context.Context) string { return "ask" }
	askClaude(context.Background(), r, nil, nil, prompt, "{}", func(string) {}, func(store.Usage) {})
	wantGitCommonDir(t, folder, git)
}
