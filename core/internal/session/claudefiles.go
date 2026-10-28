package session

import (
	"os"
	"path/filepath"
)

// hasConversation reports whether Claude Code keeps a conversation for the
// session: a file <id>.jsonl in a folder of projects in CLAUDE_CONFIG_DIR,
// else in ~/.claude. A session ID is a UUID, so the file names the session in
// any project folder. Claude Code writes the file at the first prompt, so a
// session that never had a prompt has none, and claude --resume fails.
func hasConversation(sessionID string) bool {
	root := os.Getenv("CLAUDE_CONFIG_DIR")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return false
		}
		root = filepath.Join(home, ".claude")
	}
	found, err := filepath.Glob(filepath.Join(root, "projects", "*", sessionID+".jsonl"))
	return err == nil && len(found) > 0
}
