package claudebin

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Trusted reports whether Claude Code trusts a folder: its config file
// (.claude.json in CLAUDE_CONFIG_DIR, else in the home folder) records that
// you accepted the trust prompt for the folder or for a parent of it. A
// missing or unreadable file means not trusted. Loam only reads the file.
//
// A background session (claude --bg) cannot show the trust prompt, so it
// does not start in a folder that Claude Code does not trust.
func Trusted(dir string) bool {
	h := os.Getenv("CLAUDE_CONFIG_DIR")
	if h == "" {
		var err error
		if h, err = os.UserHomeDir(); err != nil {
			return false
		}
	}
	b, err := os.ReadFile(filepath.Join(h, ".claude.json"))
	if err != nil {
		return false
	}
	var cfg struct {
		Projects map[string]struct {
			Trusted bool `json:"hasTrustDialogAccepted"`
		} `json:"projects"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return false
	}
	starts := []string{filepath.Clean(dir)}
	if r, err := filepath.EvalSymlinks(dir); err == nil && r != starts[0] {
		starts = append(starts, r)
	}
	for _, d := range starts {
		for {
			if cfg.Projects[d].Trusted {
				return true
			}
			up := filepath.Dir(d)
			if up == d {
				break
			}
			d = up
		}
	}
	return false
}
