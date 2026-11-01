package claudebin

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/GregorMcC/loam/core/internal/gitcmd"
)

// Trusted reports whether Claude Code trusts a folder, from its config file
// (.claude.json in CLAUDE_CONFIG_DIR, else in the home folder). A missing or
// unreadable file means not trusted. Loam only reads the file.
//
// The rule follows what Claude Code 2.1 does. In a git checkout, a folder is
// trusted when you trusted it or a parent of it up to the top of the
// checkout, or the main checkout of the repo. So a worktree of a trusted repo
// is trusted, and a trusted parent of the repo does not count. Outside git, a
// trusted parent counts.
//
// A background session (claude --bg) cannot show the trust prompt, so it
// does not start in a folder that Claude Code does not trust.
func Trusted(dir string) bool {
	projects := trustedProjects()
	if len(projects) == 0 {
		return false
	}
	dir = filepath.Clean(dir)
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		dir = r
	}
	top, main := gitRoots(dir)
	for d := dir; ; d = filepath.Dir(d) {
		if projects[d] {
			return true
		}
		if d == top || filepath.Dir(d) == d {
			break
		}
	}
	return main != "" && projects[main]
}

// configFile returns the path of the Claude Code config file: .claude.json
// in CLAUDE_CONFIG_DIR, else in the home folder.
func configFile() (string, error) {
	h := os.Getenv("CLAUDE_CONFIG_DIR")
	if h == "" {
		var err error
		if h, err = os.UserHomeDir(); err != nil {
			return "", err
		}
	}
	return filepath.Join(h, ".claude.json"), nil
}

// trustedProjects returns the folders that the Claude Code config trusts.
func trustedProjects() map[string]bool {
	path, err := configFile()
	if err != nil {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var cfg struct {
		Projects map[string]struct {
			Trusted bool `json:"hasTrustDialogAccepted"`
		} `json:"projects"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return nil
	}
	// Keep each folder as written and as resolved, so that a folder under a
	// symlink, such as /var on macOS, matches either way.
	out := map[string]bool{}
	for k, p := range cfg.Projects {
		if !p.Trusted {
			continue
		}
		out[filepath.Clean(k)] = true
		if r, err := filepath.EvalSymlinks(k); err == nil {
			out[r] = true
		}
	}
	return out
}

// gitRoots returns the top of the git checkout that holds dir, and the
// folder of the repo's main checkout. Both are empty outside git.
func gitRoots(dir string) (top, main string) {
	out, err := gitcmd.Command(context.Background(), dir, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir").Output()
	if err != nil {
		return "", ""
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 {
		return "", ""
	}
	top, common := lines[0], lines[1]
	if filepath.Base(common) == ".git" {
		main = filepath.Dir(common)
	}
	return top, main
}
