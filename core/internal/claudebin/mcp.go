package claudebin

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// MCPConfig returns an MCP config for claude --mcp-config that holds only
// the servers that names gives, as {"mcpServers": {...}}. Loam copies each
// definition from the user scope of the Claude Code config: mcpServers in
// .claude.json (in CLAUDE_CONFIG_DIR, else in the home folder). No names
// gives a config with no servers. A name that Loam cannot find is an error
// that names it. claude.ai connectors are not in a local file, so no name
// selects one.
//
// Loam reads only the user scope, which you write with claude mcp add
// --scope user. It does not copy a project server from .mcp.json: that file
// is in the repo, so a PR or the session of a run can change it as it changes
// any file of its worktree, and Claude Code asks you to approve a project
// server, which --mcp-config skips. It does not read a local scope either: a
// local scope is keyed by folder, a run works in a worktree, and git has
// more than one layout of a worktree and its main checkout. The user scope is
// the same for each folder.
func MCPConfig(names []string) (string, error) {
	chosen := map[string]json.RawMessage{}
	if len(names) > 0 {
		user, err := userServers()
		if err != nil {
			return "", err
		}
		for _, n := range names {
			def, ok := user[n]
			if !ok {
				return "", fmt.Errorf("the MCP server %q is not in the user scope of the Claude Code config, the only scope that Loam reads. "+
					"Add it with claude mcp add --scope user, or change loam run defaults --mcp", n)
			}
			chosen[n] = def
		}
	}
	b, err := json.Marshal(map[string]any{"mcpServers": chosen})
	if err != nil { // raw JSON from a parsed file always encodes
		panic(err)
	}
	return string(b), nil
}

// userServers returns the MCP servers of the user scope. A config file that
// does not exist gives no servers.
func userServers() (map[string]json.RawMessage, error) {
	var cfg struct {
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	}
	path, err := configFile()
	if err != nil {
		return nil, err
	}
	if err := readJSON(path, &cfg); err != nil {
		return nil, err
	}
	return cfg.MCPServers, nil
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
