package store

import (
	"reflect"
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

// A store from before the after merge migration keeps its repo settings. Each
// repo path gets Ask, and so does a path that has no settings record.
func TestMigrationGivesOldReposAsk(t *testing.T) {
	step := slices.IndexFunc(migrations, func(m string) bool { return strings.Contains(m, "ADD COLUMN after_merge") })
	if step < 0 {
		t.Fatal("no migration adds after_merge")
	}
	all := migrations
	migrations, SchemaVersion = all[:step], step
	s, err := Open(testutil.Home(t))
	migrations, SchemaVersion = all, len(all)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, q := range []string{
		`INSERT INTO plots(id, name, created_at) VALUES ('oldplotaab', 'Old', 1)`,
		`INSERT INTO repos(id, plot_id, path, is_main) VALUES ('oldrepoaab', 'oldplotaab', '/work/app', 1)`,
		`INSERT INTO repos(id, plot_id, path, is_main) VALUES ('oldrepoaac', 'oldplotaab', '/work/site', 0)`,
		`INSERT INTO repo_settings(path, setup) VALUES ('/work/app', 'make setup')`,
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
	p, err := s.GetPlot("oldplotaab")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Repos) != 2 {
		t.Fatalf("%+v", p.Repos)
	}
	for _, r := range p.Repos {
		if r.AfterMerge != AfterMergeAsk {
			t.Fatalf("%+v", r)
		}
	}
	if p.Repos[0].Setup != "make setup" {
		t.Fatalf("%+v", p.Repos[0])
	}
}

// A store from before the code review migration keeps its run defaults, and
// each plot gets the review on, with the effort of the Claude Code setting.
func TestMigrationTurnsTheCodeReviewOnForOldRunDefaults(t *testing.T) {
	step := slices.IndexFunc(migrations, func(m string) bool { return strings.Contains(m, "ADD COLUMN review ") })
	if step < 0 {
		t.Fatal("no migration adds the review")
	}
	all := migrations
	migrations, SchemaVersion = all[:step], step
	s, err := Open(testutil.Home(t))
	migrations, SchemaVersion = all, len(all)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, q := range []string{
		`INSERT INTO plots(id, name, created_at) VALUES ('oldplotaab', 'Old', 1)`,
		`INSERT INTO run_defaults(plot_id, model, effort, updated_at) VALUES ('oldplotaab', 'opus', 'high', 1)`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	if err := s.migrate(); err != nil {
		t.Fatal(err)
	}
	d, err := s.GetRunDefaults("oldplotaab")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(d, RunDefaults{PlotID: "oldplotaab", Model: "opus", Effort: "high", MCPServers: []string{}, Review: true, Checks: []Check{}}) {
		t.Fatalf("%+v", d)
	}
}

// A store from before the metrics migration keeps its try events. A try
// after a Shipping state is a CI try, and the others are gate tries. Its
// runs fix no run.
func TestMigrationGivesOldTriesTheirStage(t *testing.T) {
	step := slices.IndexFunc(migrations, func(m string) bool { return strings.Contains(m, "ADD COLUMN stage ") })
	if step < 0 {
		t.Fatal("no migration adds the stage")
	}
	all := migrations
	migrations, SchemaVersion = all[:step], step
	s, err := Open(testutil.Home(t))
	migrations, SchemaVersion = all, len(all)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, q := range []string{
		`INSERT INTO plots(id, name, created_at) VALUES ('oldplotaab', 'Old', 1)`,
		`INSERT INTO runs(id, plot_id, folder, title, state, max_tries, created_at, updated_at)
  VALUES ('oldrunaaab', 'oldplotaab', '/tmp/x', 'Old run', 'landed', 3, 1, 1)`,
		`INSERT INTO run_events(run_id, at, kind, detail) VALUES
  ('oldrunaaab', 1, 'state', 'starting'), ('oldrunaaab', 2, 'state', 'running'), ('oldrunaaab', 3, 'try', 'Try 1 failed: Go tests'),
  ('oldrunaaab', 4, 'state', 'shipping'), ('oldrunaaab', 5, 'ci', 'CI failed on #3: core'),
  ('oldrunaaab', 5, 'try', 'CI failed on #3: core'), ('oldrunaaab', 5, 'state', 'running')`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	if err := s.migrate(); err != nil {
		t.Fatal(err)
	}
	events, err := s.RunEvents("oldrunaaab")
	if err != nil {
		t.Fatal(err)
	}
	var stages []string
	for _, e := range events {
		stages = append(stages, e.Kind+":"+e.Stage)
	}
	want := []string{"state:", "state:", "try:gate", "state:", "ci:", "try:ci", "state:"}
	if !slices.Equal(stages, want) {
		t.Fatalf("stages %q, want %q", stages, want)
	}
	if r, err := s.GetRun("oldrunaaab"); err != nil || r.Fixes != "" {
		t.Fatalf("run %+v, %v", r, err)
	}
}
