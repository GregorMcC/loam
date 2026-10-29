package claudebin_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/claudebin"
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
// to the folder, user, and project (.mcp.json in the folder). The name
// "both" is in each scope. It returns the folder.
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
	for name, want := range map[string]string{"local": "local-cmd", "user": "user-cmd", "project": "project-cmd", "both": "local-both"} {
		got, err := claudebin.MCPConfig(dir, []string{name})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if s := mcpServers(t, got); len(s) != 1 || s[name] != want {
			t.Errorf("%s: servers %v, want %s", name, s, want)
		}
	}
	got, err := claudebin.MCPConfig(dir, []string{"user", "project"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); len(s) != 2 || s["user"] != "user-cmd" || s["project"] != "project-cmd" {
		t.Fatalf("servers %v", s)
	}
	// The whole definition is copied, not only the command.
	if !strings.Contains(got, `"args":["mcp"]`) || !strings.Contains(got, `"type":"stdio"`) {
		t.Fatalf("config %s", got)
	}
}

func TestMCPConfigUserScopeWinsOverTheProjectFile(t *testing.T) {
	dir := mcpSetup(t)
	// With no local scope for the folder, the user scope comes next.
	other := t.TempDir()
	if err := os.Rename(filepath.Join(dir, ".mcp.json"), filepath.Join(other, ".mcp.json")); err != nil {
		t.Fatal(err)
	}
	got, err := claudebin.MCPConfig(other, []string{"both", "project"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); s["both"] != "user-both" || s["project"] != "project-cmd" {
		t.Fatalf("servers %v", s)
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
