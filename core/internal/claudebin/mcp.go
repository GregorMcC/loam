package claudebin

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// MCPConfig returns an MCP config for claude --mcp-config that holds only
// the servers that names gives, as {"mcpServers": {...}}. Loam copies each
// definition from the Claude Code config. It looks for a name in this order:
// the local scope of dir and the user scope in .claude.json (in
// CLAUDE_CONFIG_DIR, else in the home folder), then .mcp.json in dir. No
// names gives a config with no servers. A name that Loam cannot find is an
// error that names it. claude.ai connectors are not in a local file, so no
// name selects one.
func MCPConfig(dir string, names []string) (string, error) {
	servers := map[string]json.RawMessage{}
	if len(names) > 0 {
		scopes, err := mcpScopes(dir)
		if err != nil {
			return "", err
		}
		for _, n := range names {
			for _, scope := range scopes {
				if def, ok := scope[n]; ok {
					servers[n] = def
					break
				}
			}
			if _, ok := servers[n]; !ok {
				return "", fmt.Errorf("the MCP server %q is not in the Claude Code config of %s. Add it with claude mcp add, or change loam run defaults --mcp", n, dir)
			}
		}
	}
	b, err := json.Marshal(map[string]any{"mcpServers": servers})
	if err != nil { // raw JSON from a parsed file always encodes
		panic(err)
	}
	return string(b), nil
}

// mcpScopes returns the MCP servers of each scope that Claude Code reads for
// dir, first scope first. A file that does not exist adds no scope.
func mcpScopes(dir string) ([]map[string]json.RawMessage, error) {
	type servers struct {
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	}
	var cfg struct {
		servers
		Projects map[string]servers `json:"projects"`
	}
	path, err := configFile()
	if err != nil {
		return nil, err
	}
	if err := readJSON(path, &cfg); err != nil {
		return nil, err
	}
	// The config keeps each folder as written, so match dir as given and as
	// resolved, such as /var and /private/var on macOS.
	dir = filepath.Clean(dir)
	keys := map[string]bool{dir: true}
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		keys[r] = true
	}
	var local map[string]json.RawMessage
	for k, p := range cfg.Projects {
		r, err := filepath.EvalSymlinks(k)
		if keys[filepath.Clean(k)] || (err == nil && keys[r]) {
			local = p.MCPServers
			break
		}
	}
	var project servers
	if err := readJSON(filepath.Join(dir, ".mcp.json"), &project); err != nil {
		return nil, err
	}
	return []map[string]json.RawMessage{local, cfg.MCPServers, project.MCPServers}, nil
}

// readJSON decodes the JSON file at path into v. A file that does not exist
// leaves v as it is.
func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	return nil
}
