package run

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/gitcmd"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// wantNoRepo checks that the fake claude ran in folder with a GIT_DIR that
// names no repo. The git that Claude Code starts then reads no config of the
// run, and starts nothing in a nested repo.
func wantNoRepo(t *testing.T, folder string) {
	t.Helper()
	inv := testutil.FakeClaudeInvocation(t)
	got, err := filepath.EvalSymlinks(inv.Cwd)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(folder)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("claude ran in %q, want %q", got, want)
	}
	if got := inv.Env["GIT_DIR"]; got != gitcmd.NoRepoDir {
		t.Errorf("claude ran in the run folder with GIT_DIR %q, want %q", got, gitcmd.NoRepoDir)
	}
}

// The code review and the PR text run claude -p outside the sandbox in the run
// folder, and no new check runs before them.
func TestRunPrintRunsClaudeWithNoRepo(t *testing.T) {
	folder := t.TempDir()
	testutil.FakeClaude(t)
	testutil.FakeClaudePrint(t, `{"structured_output":{"ok":true}}`)
	out, why := runPrint(context.Background(), "claude", folder, []string{"-p", "ask", "--json-schema", "{}"}, "text")
	if why != "" {
		t.Fatal(why)
	}
	if !json.Valid(out) {
		t.Errorf("output %q", out)
	}
	wantNoRepo(t, folder)
}

// A draft of a run runs claude -p outside the sandbox in a folder that an
// earlier run of the worktree could write.
func TestAskClaudeRunsClaudeWithNoRepo(t *testing.T) {
	folder := t.TempDir()
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
	wantNoRepo(t, folder)
}
