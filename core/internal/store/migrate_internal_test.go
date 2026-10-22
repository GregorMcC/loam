package store

import (
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// A store from before the goal migration keeps its worktrees. Each one gets
// an empty goal and no link.
func TestMigrationAddsGoalAndLinkToOldWorktrees(t *testing.T) {
	// The test finds the step by its text, so it holds when the migrations
	// are numbered again. Migration n is migrations[n-1], so the schema just
	// before the step is version goalStep.
	goalStep := slices.IndexFunc(migrations, func(m string) bool { return strings.Contains(m, "ADD COLUMN goal") })
	if goalStep < 0 {
		t.Fatal("no migration adds the goal")
	}
	// Make the database as a Loam from before the step made it.
	all := migrations
	migrations, SchemaVersion = all[:goalStep], goalStep
	s, err := Open(testutil.Home(t))
	migrations, SchemaVersion = all, len(all)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, q := range []string{
		`INSERT INTO plots(id, name, created_at) VALUES ('oldplotaab', 'Old', 1)`,
		`INSERT INTO worktrees(id, plot_id, repo_path, name, branch, base, path, created_at)
VALUES ('oldwtreeab', 'oldplotaab', '/work/app', 'old', 'old', 'origin/main', '/home/w/app-old', 1)`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	if err := s.migrate(); err != nil {
		t.Fatal(err)
	}
	if v, err := s.readVersion(s.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	got, err := s.GetWorktree("oldwtreeab")
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "old" || got.Goal != "" || got.Link != nil || got.Version != 0 {
		t.Fatalf("%+v", got)
	}
}
