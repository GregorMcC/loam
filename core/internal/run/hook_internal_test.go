package run

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// A worktree that the store does not have is not on GitHub. A store that
// cannot read the worktree sends the run to Ship, which reads it again.
func TestOnGitHubTellsAGoneWorktreeFromAStoreError(t *testing.T) {
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := store.Run{WorktreeID: "gone"}
	if onGitHub(s, r) {
		t.Fatal("a gone worktree is on GitHub")
	}
	s.Close()
	if !onGitHub(s, r) {
		t.Fatal("a store error means no GitHub")
	}
}
