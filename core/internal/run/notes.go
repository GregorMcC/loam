package run

import (
	"fmt"
	"path"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// alsoChanged is the role of a changed file that Claude left out of the
// notes.
const alsoChanged = "Also changed"

// factNames is how many files a risk fact names before it counts the rest.
const factNames = 5

// shipNotes makes the notes of the run from the answer of Claude. changed
// are the files that the branch changed, or nil when git cannot say. With
// them, Loam drops a file that the branch did not change, and adds each
// changed file that Claude left out. Loam adds its own facts to the reasons
// of the risk (see [riskFacts]).
func shipNotes(r store.Run, a shipAnswer, changed []string) *store.RunNotes {
	n := &store.RunNotes{
		Walkthrough:   strings.TrimSpace(a.Walkthrough),
		Files:         []store.NoteFile{},
		Risk:          store.NoteRisk{Level: strings.ToLower(strings.TrimSpace(a.Risk.Level)), Reasons: []string{}},
		WhereItStands: strings.TrimSpace(a.WhereItStands),
		WrittenAt:     time.Now(),
	}
	var seen []string
	for _, f := range a.Files {
		p := strings.TrimPrefix(strings.TrimSpace(f.Path), "./")
		if p == "" || slices.Contains(seen, p) || (changed != nil && !slices.Contains(changed, p)) {
			continue
		}
		seen = append(seen, p)
		n.Files = append(n.Files, store.NoteFile{Path: p, Role: strings.TrimSpace(f.Role)})
	}
	for _, p := range changed {
		if !slices.Contains(seen, p) {
			n.Files = append(n.Files, store.NoteFile{Path: p, Role: alsoChanged})
		}
	}
	if !slices.Contains([]string{store.RiskLow, store.RiskMedium, store.RiskHigh}, n.Risk.Level) {
		n.Risk.Level = store.RiskMedium
	}
	for _, reason := range a.Risk.Reasons {
		if reason = strings.TrimSpace(reason); reason != "" {
			n.Risk.Reasons = append(n.Risk.Reasons, reason)
		}
	}
	n.Risk.Reasons = append(n.Risk.Reasons, riskFacts(r, changed)...)
	return n
}

// riskFacts are the facts that Loam adds to the risk of a change, not
// Claude: the changed files that the plan of the shape does not name, a
// store migration in the diff, and changed dependency files. The plan fact
// is there only when the plan names a changed file, by its path or its base
// name: most plans name no paths, and then every file would be out of it.
func riskFacts(r store.Run, changed []string) []string {
	var facts []string
	if r.Shape != nil && len(r.Shape.Plan) > 0 {
		plan := strings.ToLower(strings.Join(r.Shape.Plan, "\n"))
		var out []string
		named := false
		for _, p := range changed {
			if strings.Contains(plan, strings.ToLower(p)) || strings.Contains(plan, strings.ToLower(path.Base(p))) {
				named = true
			} else {
				out = append(out, p)
			}
		}
		if !named {
			out = nil
		}
		switch len(out) {
		case 0:
		case 1:
			facts = append(facts, fmt.Sprintf("1 changed file is not in the plan: %s.", out[0]))
		default:
			facts = append(facts, fmt.Sprintf("%d changed files are not in the plan: %s.", len(out), nameFiles(out)))
		}
	}
	migrations := slices.DeleteFunc(slices.Clone(changed), func(p string) bool { return !isMigration(p) })
	switch len(migrations) {
	case 0:
	case 1:
		facts = append(facts, fmt.Sprintf("The diff changes a store migration: %s.", migrations[0]))
	default:
		facts = append(facts, fmt.Sprintf("The diff changes store migrations: %s.", nameFiles(migrations)))
	}
	deps := slices.DeleteFunc(slices.Clone(changed), func(p string) bool { return !isDependencyFile(p) })
	switch len(deps) {
	case 0:
	case 1:
		facts = append(facts, fmt.Sprintf("The diff changes a dependency file: %s.", deps[0]))
	default:
		facts = append(facts, fmt.Sprintf("The diff changes dependency files: %s.", nameFiles(deps)))
	}
	return facts
}

// nameFiles names the files as "a, b and c", and counts the files after the
// first few.
func nameFiles(files []string) string {
	if len(files) <= factNames {
		return joinAnd(files)
	}
	return strings.Join(files[:factNames], ", ") + fmt.Sprintf(" and %d more", len(files)-factNames)
}

// isMigration reports whether the path is a store migration: a path with a
// folder or a file named for migrations, such as db/migrations/0001.sql or
// app/migrate.go. A file named schema is not one: it is as often a GraphQL
// or an API schema.
func isMigration(p string) bool {
	for _, part := range strings.Split(strings.ToLower(p), "/") {
		if strings.Contains(part, "migrat") {
			return true
		}
	}
	return false
}

// dependencyFiles are the names of the files that pin the dependencies of a
// repo, besides lock files.
var dependencyFiles = []string{"go.mod", "go.sum", "Package.swift", "Package.resolved", "package.json", "npm-shrinkwrap.json"}

// isDependencyFile reports whether the path is a dependency file: one of
// [dependencyFiles], or a lock file such as yarn.lock or package-lock.json.
func isDependencyFile(p string) bool {
	base := path.Base(p)
	if slices.Contains(dependencyFiles, base) {
		return true
	}
	ext := path.Ext(base)
	return ext == ".lock" || ext == ".lockb" || strings.HasSuffix(strings.TrimSuffix(base, ext), "-lock")
}
