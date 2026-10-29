package claudebin

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"
)

// ScopeUser is the scope of the MCP servers that Loam can copy: the user
// scope of the Claude Code config.
const ScopeUser = "user"

// MCPServer is an MCP server that [MCPConfig] can copy.
type MCPServer struct {
	Name  string `json:"name"`
	Scope string `json:"scope"`
}

// MCPServers lists the MCP servers that [MCPConfig] can copy, by name. It
// leaves out a server that MCPConfig rejects, one with a headersHelper, so
// each name in the list is one that loam run defaults --mcp accepts. A
// config file that does not exist gives an empty list.
func MCPServers() ([]MCPServer, error) {
	user, err := userServers()
	if err != nil {
		return nil, err
	}
	servers := []MCPServer{}
	for name, def := range user {
		if !hasHelper(def) {
			servers = append(servers, MCPServer{Name: name, Scope: ScopeUser})
		}
	}
	slices.SortFunc(servers, func(a, b MCPServer) int { return strings.Compare(a.Name, b.Name) })
	return servers, nil
}

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
//
// A server with a headersHelper is an error. Claude Code 2.1.238 and later
// runs the headersHelper of a user-scope server in the config folder, but
// that of an --mcp-config server in the folder of the session (see "Where
// the helper runs" in the Claude Code MCP docs). The session folder is the
// repo folder for a draft and the worktree of the run for the PR text, so a
// relative path in a copied helper could run a file that a PR or the run
// wrote. A helper is a shell command, so Loam cannot tell whether it has a
// relative path. The command and args of a stdio server run in the session
// folder from either scope, so --mcp-config changes nothing for them.
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
			if hasHelper(def) {
				return "", fmt.Errorf("the MCP server %q has a headersHelper, which claude -p would run in the folder of the run, not in the Claude Code config folder. "+
					"Loam does not copy a server with a headersHelper. Leave it out of loam run defaults --mcp", n)
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

// hasHelper reports whether the server definition def has a headersHelper.
// It fails closed on the key: a key that is headersHelper in any case, with
// any value but null, counts. A definition that is not an object has no
// keys, so it has no helper, and Claude Code rejects it as it would anyway.
func hasHelper(def json.RawMessage) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal(def, &fields) != nil {
		return false
	}
	for k, v := range fields {
		if strings.EqualFold(k, "headersHelper") && strings.TrimSpace(string(v)) != "null" {
			return true
		}
	}
	return false
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
