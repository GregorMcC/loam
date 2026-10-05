package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// Ticket 78: `loam link add <plot> <target>` takes the label from the target.
func TestLinkAddWithNoLabel(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	if _, _, err := lrRun(t, "", "link", "add", "alpha", "https://linear.app/acme/issue/ENG-4/fix"); err != nil {
		t.Fatal(err)
	}
	if l := lrPlot(t, s, p.ID).Links; len(l) != 1 || l[0].Label != "ENG-4" || l[0].Target != "https://linear.app/acme/issue/ENG-4/fix" {
		t.Fatalf("links %+v", l)
	}
	if _, _, err := lrRun(t, "", "link", "add", "alpha"); err == nil {
		t.Fatal("link add with no target worked")
	}
}

// Ticket 78: a repo path that does not exist, or is a file, fails with a message that names it.
func TestRepoAddRejectsAPathThatIsNotAFolder(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	dir := lrRepoDirs(t, 1)[0]
	file := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{filepath.Join(dir, "gone"), file} {
		_, _, err := lrRun(t, "", "repo", "add", "alpha", path)
		if !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), path) {
			t.Errorf("repo add %s: %v", path, err)
		}
	}
	if r := lrPlot(t, s, p.ID).Repos; len(r) != 0 {
		t.Fatalf("repos %+v", r)
	}
}
