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

// mcpSetup makes a Claude Code config with a server in each scope: user,
// local to a folder, and project (.mcp.json in the folder). Loam reads only
// the user scope.
func mcpSetup(t *testing.T) {
	t.Helper()
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := t.TempDir()
	server := func(cmd string) map[string]any {
		return map[string]any{"type": "stdio", "command": cmd, "args": []string{"mcp"}}
	}
	writeJSON(t, filepath.Join(cfg, ".claude.json"), map[string]any{
		"mcpServers": map[string]any{"user": server("user-cmd"), "other": server("other-cmd")},
		// A name in two scopes gets the user definition.
		"projects": map[string]any{dir: map[string]any{"mcpServers": map[string]any{"local": server("local-cmd"), "other": server("local-other")}}},
	})
	writeJSON(t, filepath.Join(dir, ".mcp.json"), map[string]any{"mcpServers": map[string]any{"project": server("project-cmd")}})
}

func TestMCPConfigWithNoNamesHoldsNoServers(t *testing.T) {
	// No config file is needed for no servers.
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	got, err := claudebin.MCPConfig(nil)
	if err != nil || got != `{"mcpServers":{}}` {
		t.Fatalf("got %s, %v", got, err)
	}
}

func TestMCPConfigCopiesTheUserScope(t *testing.T) {
	mcpSetup(t)
	got, err := claudebin.MCPConfig([]string{"user", "other"})
	if err != nil {
		t.Fatal(err)
	}
	if s := mcpServers(t, got); len(s) != 2 || s["user"] != "user-cmd" || s["other"] != "other-cmd" {
		t.Fatalf("servers %v", s)
	}
	// The whole definition is copied, not only the command.
	if !strings.Contains(got, `"args":["mcp"]`) || !strings.Contains(got, `"type":"stdio"`) {
		t.Fatalf("config %s", got)
	}
}

// A server of a local scope or of .mcp.json is missing: the session of a run
// can write both from its worktree, and --mcp-config skips the approval of a
// project server.
func TestMCPConfigReadsOnlyTheUserScope(t *testing.T) {
	mcpSetup(t)
	for _, name := range []string{"local", "project", "slack"} {
		_, err := claudebin.MCPConfig([]string{"user", name})
		if err == nil || !strings.Contains(err.Error(), `"`+name+`"`) || !strings.Contains(err.Error(), "--scope user") {
			t.Errorf("%s: %v", name, err)
		}
	}
}
