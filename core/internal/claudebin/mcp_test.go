package claudebin_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// writeJSON writes v as JSON to path.
func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// mcpServers returns the servers of an MCP config, each as its command.
func mcpServers(t *testing.T, config string) map[string]string {
	t.Helper()
	var c struct {
		MCPServers map[string]struct {
			Command string `json:"command"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(config), &c); err != nil || c.MCPServers == nil {
		t.Fatalf("config %s: %v", config, err)
	}
	out := map[string]string{}
	for n, s := range c.MCPServers {
		out[n] = s.Command
	}
	return out
}

// mcpSetup makes a Claude Code config with a server in each scope: local
// to the folder, user, and project (.mcp.json in the folder, which Loam does
// not read). The name "both" is in each scope. It returns the folder.
func mcpSetup(t *testing.T) string {
	t.Helper()
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := t.TempDir()
	server := func(cmd string) map[string]any {
		return map[string]any{"type": "stdio", "command": cmd, "args": []string{"mcp"}}
	}
	writeJSON(t, filepath.Join(cfg, ".claude.json"), map[string]any{
		"mcpServers": map[string]any{"user": server("user-cmd"), "both": server("user-both")},
		"projects": map[string]any{
			dir:         map[string]any{"mcpServers": map[string]any{"local": server("local-cmd"), "both": server("local-both")}},
			t.TempDir(): map[string]any{"mcpServers": map[string]any{"other": server("other-cmd")}},
		},
	})
	writeJSON(t, filepath.Join(dir, ".mcp.json"), map[string]any{
		"mcpServers": map[string]any{"project": server("project-cmd"), "both": server("project-both")},
	})
	return dir
}

func TestMCPConfigWithNoNamesHoldsNoServers(t *testing.T) {
	// No config file is needed for no servers.
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	got, err := claudebin.MCPConfig(t.TempDir(), nil)
	if err != nil || got != `{"mcpServers":{}}` {
		t.Fatalf("got %s, %v", got, err)
	}
}

func TestMCPConfigCopiesEachScope(t *testing.T) {
	dir := mcpSetup(t)
	for name, want := range map[string]string{"local": "local-cmd", "user": "user-cmd", "both": "local-both"} {
		got, err := claudebin.MCPConfig(dir, []string{name})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if s := mcpServers(t, got); len(s) != 1 || s[name] != want {
			t.Errorf("%s: servers %v, want %s", name, s, want)
		}
	}
	got, err := claudebin.MCPConfig(dir, []string{"user", "local"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); len(s) != 2 || s["user"] != "user-cmd" || s["local"] != "local-cmd" {
		t.Fatalf("servers %v", s)
	}
	// The whole definition is copied, not only the command.
	if !strings.Contains(got, `"args":["mcp"]`) || !strings.Contains(got, `"type":"stdio"`) {
		t.Fatalf("config %s", got)
	}
}

func TestMCPConfigUserScopeComesAfterTheLocalScope(t *testing.T) {
	mcpSetup(t)
	// A folder with no local scope gets the user scope.
	got, err := claudebin.MCPConfig(t.TempDir(), []string{"both"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); s["both"] != "user-both" {
		t.Fatalf("servers %v", s)
	}
}

func TestMCPConfigSkipsTheProjectFile(t *testing.T) {
	dir := mcpSetup(t)
	// A server that only .mcp.json has is missing: Loam does not copy a
	// project server, because --mcp-config skips its approval.
	if _, err := claudebin.MCPConfig(dir, []string{"project"}); err == nil || !strings.Contains(err.Error(), `"project"`) {
		t.Fatalf("project: %v", err)
	}
	// With no local or user scope, a name in .mcp.json is missing too.
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	if _, err := claudebin.MCPConfig(dir, []string{"both"}); err == nil {
		t.Fatal("both: no error")
	}
}

func TestMCPConfigIgnoresABadProjectFile(t *testing.T) {
	dir := mcpSetup(t)
	// Loam does not read .mcp.json, so a file that does not parse stops nothing.
	if err := os.WriteFile(filepath.Join(dir, ".mcp.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := claudebin.MCPConfig(dir, []string{"user"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); len(s) != 1 || s["user"] != "user-cmd" {
		t.Fatalf("servers %v", s)
	}
}

// A run works in a git worktree. Its local scope is that of the main
// checkout, where you run claude mcp add, and not that of the worktree,
// which the session of the run can write.
func TestMCPConfigInAWorktreeReadsTheMainCheckout(t *testing.T) {
	testutil.GitEnv(t)
	root, _ := filepath.EvalSymlinks(t.TempDir())
	repo := filepath.Join(root, "app")
	wt := filepath.Join(root, "app-fix")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, repo, "init", "-q", "-b", "main")
	testutil.Git(t, repo, "commit", "-q", "--allow-empty", "-m", "first")
	testutil.Git(t, repo, "worktree", "add", "-q", "-b", "fix", wt)
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	server := func(cmd string) map[string]any { return map[string]any{"type": "stdio", "command": cmd} }
	writeJSON(t, filepath.Join(cfg, ".claude.json"), map[string]any{
		"projects": map[string]any{
			repo: map[string]any{"mcpServers": map[string]any{"linear": server("main-cmd")}},
			wt:   map[string]any{"mcpServers": map[string]any{"linear": server("wt-cmd"), "added": server("added-cmd")}},
		},
	})
	got, err := claudebin.MCPConfig(wt, []string{"linear"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); s["linear"] != "main-cmd" {
		t.Fatalf("servers %v", s)
	}
	if _, err := claudebin.MCPConfig(wt, []string{"added"}); err == nil || !strings.Contains(err.Error(), `"added"`) {
		t.Fatalf("added: %v", err)
	}
}

func TestMCPConfigNamesAMissingServer(t *testing.T) {
	dir := mcpSetup(t)
	// A server of another folder is not in the scopes of this one.
	for _, name := range []string{"slack", "other"} {
		_, err := claudebin.MCPConfig(dir, []string{"local", name})
		if err == nil || !strings.Contains(err.Error(), `"`+name+`"`) {
			t.Errorf("%s: %v", name, err)
		}
	}
}
