// Package claudebin finds the claude binary.
//
// Loam.app starts each pane with "$SHELL -lc", which reads .zprofile but not
// .zshrc. Claude Code's installer adds ~/.local/bin to PATH in .zshrc, so
// claude is often not on that PATH. Find then looks in the folders that the
// installer uses.
package claudebin

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
)

// ErrNotFound is the error when claude is not on PATH or in an install folder.
var ErrNotFound = errors.New("claude is not on PATH")

// installPaths are the places Claude Code installs claude, relative to HOME:
// the native installer, then the older local install.
var installPaths = []string{".local/bin/claude", ".claude/local/claude"}

// Find returns the absolute path of claude: from PATH first, else from an
// install folder.
func Find() (string, error) {
	if p, err := exec.LookPath("claude"); err == nil {
		return filepath.Abs(p)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", ErrNotFound
	}
	for _, rel := range installPaths {
		p := filepath.Join(home, rel)
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p, nil
		}
	}
	return "", ErrNotFound
}
