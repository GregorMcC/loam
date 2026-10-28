package run

import (
	"encoding/json"
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestShipNotesKeepTheChangedFilesInTheOrderOfClaude(t *testing.T) {
	a := shipAnswer{
		Walkthrough: " Moves the rule. ",
		Files: []store.NoteFile{{Path: "b.go", Role: "Tests"}, {Path: "gone.go", Role: "Old"}, {Path: "a.go", Role: "The rule"},
			{Path: "b.go", Role: "Twice"}},
		Risk: store.NoteRisk{Level: "Extreme", Reasons: []string{"Small."}},
	}
	n := shipNotes(store.Run{}, a, []string{"a.go", "b.go", "c.go"})
	want := []store.NoteFile{{Path: "b.go", Role: "Tests"}, {Path: "a.go", Role: "The rule"}, {Path: "c.go", Role: alsoChanged}}
	if !slices.Equal(n.Files, want) || n.Walkthrough != "Moves the rule." {
		t.Fatalf("notes %+v", n)
	}
	// A level that is not low, medium, or high is medium.
	if n.Risk.Level != store.RiskMedium || !slices.Equal(n.Risk.Reasons, []string{"Small."}) {
		t.Fatalf("risk %+v", n.Risk)
	}
	// When git cannot say what changed, the files of Claude stay.
	if n := shipNotes(store.Run{}, a, nil); len(n.Files) != 3 {
		t.Fatalf("files %+v", n.Files)
	}
	// The JSON has arrays, not null.
	b, _ := json.Marshal(shipNotes(store.Run{}, shipAnswer{}, nil))
	var m map[string]any
	json.Unmarshal(b, &m)
	if m["files"] == nil || m["risk"].(map[string]any)["reasons"] == nil {
		t.Fatalf("json %s", b)
	}
}

func TestRiskFactsNameFilesOutOfThePlanMigrationsAndDependencies(t *testing.T) {
	r := store.Run{Shape: &store.RunShape{Plan: []string{"Change core/run/land.go.", "Add a test in land_test.go."}}}
	changed := []string{"core/run/land.go", "core/run/land_test.go", "db/migrations/0002_add.sql", "go.sum", "app/Package.resolved"}
	want := []string{
		"3 changed files are not in the plan: db/migrations/0002_add.sql, go.sum and app/Package.resolved.",
		"The diff changes a store migration: db/migrations/0002_add.sql.",
		"The diff changes dependency files: go.sum and app/Package.resolved.",
	}
	if got := riskFacts(r, changed); !slices.Equal(got, want) {
		t.Fatalf("facts %q", got)
	}
	// A plan that names no changed file gets no plan fact, and a schema file
	// is not a migration.
	r = store.Run{Shape: &store.RunShape{Plan: []string{"Add the search field to the API.", "Test it."}}}
	if got := riskFacts(r, []string{"graphql/schema.ts", "openapi/schema.py"}); len(got) != 0 {
		t.Fatalf("facts %q", got)
	}
	// A run with no plan gets no plan fact, and a small change gets none.
	if got := riskFacts(store.Run{}, []string{"README.md"}); len(got) != 0 {
		t.Fatalf("facts %q", got)
	}
}

func TestFileKinds(t *testing.T) {
	for p, want := range map[string]bool{
		"db/migrations/0001_init.sql": true, "core/internal/store/schema.go": false, "prisma/schema.prisma": false,
		"graphql/schema.ts": false, "openapi/schema.py": false, "contract/schema/defs.json": false, "schema.json": false,
		"app/migrate.go": true, "Migrations/V2.swift": true, "README.md": false,
	} {
		if isMigration(p) != want {
			t.Errorf("isMigration(%q) is %v", p, !want)
		}
	}
	for p, want := range map[string]bool{
		"go.mod": true, "core/go.sum": true, "app/Package.swift": true, "Package.resolved": true, "web/package.json": true,
		"yarn.lock": true, "package-lock.json": true, "pnpm-lock.yaml": true, "bun.lockb": true, "Cargo.lock": true,
		"lockfile.md": false, "main.go": false,
	} {
		if isDependencyFile(p) != want {
			t.Errorf("isDependencyFile(%q) is %v", p, !want)
		}
	}
}

func TestNameFilesCountsTheRest(t *testing.T) {
	if got := nameFiles([]string{"a", "b", "c", "d", "e", "f", "g"}); got != "a, b, c, d, e and 2 more" {
		t.Fatalf("%q", got)
	}
}

func TestShipTextSchemaAsksForTheTemplateOnlyWithOne(t *testing.T) {
	var with, without struct {
		Required []string `json:"required"`
	}
	json.Unmarshal([]byte(shipTextSchema(true)), &with)
	json.Unmarshal([]byte(shipTextSchema(false)), &without)
	if !slices.Contains(with.Required, "body") || slices.Contains(without.Required, "title") || !slices.Contains(without.Required, "where_it_stands") {
		t.Fatalf("with %v without %v", with.Required, without.Required)
	}
}
