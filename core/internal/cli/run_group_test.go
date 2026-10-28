package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Linked runs: one issue that needs changes in two repos is shaped into one
// run in each repo, and the runs share a group.

type shapeOut struct {
	Run  store.Run   `json:"run"`
	Runs []store.Run `json:"runs"`
}

// splitCLI is a plot with two repos that Claude Code trusts: app, the main
// repo, and docs. It returns the plot and the repos.
func splitCLI(t *testing.T) (*store.Store, store.Plot, store.Repo, store.Repo) {
	t.Helper()
	testutil.GitEnv(t)
	app, _ := testutil.GitRepo(t)
	root := realPath(t, t.TempDir())
	docs, _ := testutil.GitRepoAt(t, filepath.Join(root, "docs.git"), filepath.Join(root, "repos", "docs"))
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: app}, {Path: docs}}})
	testutil.FakeClaude(t)
	testutil.FakeGH(t, `{}`)
	trustFolder(t, app, docs)
	return s, p, plotRepo(t, p, app), plotRepo(t, p, docs)
}

func plotRepo(t *testing.T, p store.Plot, path string) store.Repo {
	t.Helper()
	for _, r := range p.Repos {
		if r.Path == path {
			return r
		}
	}
	t.Fatalf("no repo %s in %+v", path, p.Repos)
	return store.Repo{}
}

// splitDraft is what claude -p prints for a split draft: one run for each
// repo, in order.
func splitDraft(repos ...string) string {
	var runs []string
	for i, id := range repos {
		runs = append(runs, fmt.Sprintf(`{"repo": %q, "goal": "Part %d of the change.",
  "checks": [{"name": "Tests %d", "command": "true"}], "assumptions": ["The other part lands first."],
  "plan": ["Change it."], "size": "Small."}`, id, i+1, i+1))
	}
	return `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"runs": [` + strings.Join(runs, ", ") + `]}}`
}

func shapeRuns(t *testing.T, args ...string) shapeOut {
	t.Helper()
	out, errOut, err := lrRun(t, "", append([]string{"run"}, append(args, "--json")...)...)
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var got shapeOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if len(got.Runs) == 0 || got.Runs[0].ID != got.Run.ID {
		t.Fatalf("runs do not start with run: %s", out)
	}
	return got
}

// printCalls returns the claude -p calls, besides the usage probes (see
// [usageProbes]): a run start probes a usage that Loam never read.
func printCalls(t *testing.T) [][]string {
	t.Helper()
	return slices.DeleteFunc(testutil.FakeClaudeCalls(t), func(c []string) bool {
		return !slices.Contains(c, "-p") || slices.Contains(c, "Reply with ok")
	})
}

func TestRunShapeSplitMakesALinkedRunInEachRepo(t *testing.T) {
	s, _, app, docs := splitCLI(t)
	// The first entry is docs, so the run that the shape recorded moves there.
	testutil.FakeClaudePrint(t, splitDraft(docs.ID, app.ID))
	got := shapeRuns(t, "shape", "alpha", "--title", "Rename the setting", "--split", "--base", "dev",
		"--model", "opus", "--effort", "high", "--max-tries", "5")
	if len(got.Runs) != 2 {
		t.Fatalf("runs %+v", got.Runs)
	}
	first, second := got.Runs[0], got.Runs[1]
	if first.GroupID != first.ID || second.GroupID != first.ID {
		t.Fatalf("groups %q %q, want %q", first.GroupID, second.GroupID, first.ID)
	}
	if first.Folder != docs.Path || first.Shape.Repo != docs.ID || first.Shape.Base != "" || first.Goal != "Part 1 of the change." ||
		first.Shape.Split || first.Shape.DraftedAt == nil || first.Note != "" {
		t.Fatalf("first %+v %+v", first, first.Shape)
	}
	// The base is for the main repo.
	if second.Folder != app.Path || second.Shape.Repo != app.ID || second.Shape.Base != "dev" || second.Goal != "Part 2 of the change." ||
		second.State != store.RunShaping || second.Shape.DraftedAt == nil || second.Title != "Rename the setting" ||
		second.MaxTries != 5 || second.Shape.Model != "opus" || second.Shape.Effort != "high" ||
		!slices.Equal(second.DoneWhen, []store.Check{{Name: "Tests 2", Command: "true"}}) {
		t.Fatalf("second %+v %+v", second, second.Shape)
	}
	if stored, _ := s.GetRun(second.ID); stored.GroupID != first.ID {
		t.Fatalf("stored %+v", stored)
	}
	for _, r := range got.Runs {
		if e := events(t, s, r.ID, "shape"); !slices.Equal(e, []string{"Claude drafted the goal and 1 check"}) {
			t.Errorf("run %s: shape events %q", r.ID, e)
		}
	}

	// One claude -p, in the main repo, reads both repos.
	calls := printCalls(t)
	inv := testutil.FakeClaudeInvocation(t)
	if len(calls) != 1 || realPath(t, inv.Cwd) != app.Path || !containsRun(inv.Args, []string{"--add-dir", docs.Path}) ||
		!containsRun(inv.Args, []string{"--model", "opus"}) {
		t.Fatalf("calls %q, args %q in %s", calls, inv.Args, inv.Cwd)
	}
	if schema := argAfter(inv.Args, "--json-schema"); !json.Valid([]byte(schema)) || !strings.Contains(schema, `"runs"`) {
		t.Fatalf("schema %s", schema)
	}
	prompt := argAfter(inv.Args, "-p")
	for _, want := range []string{app.ID, docs.ID, docs.Path, "Rename the setting", "any order"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}

	// The list and the status show the group.
	out, _, err := lrRun(t, "", "run", "list", "alpha")
	if err != nil || strings.Count(out, "group "+first.ID) != 2 {
		t.Fatalf("list %v:\n%s", err, out)
	}
	if out, _, err := lrRun(t, "", "run", "status", second.ID); err != nil || !strings.Contains(out, "Group: "+first.ID) {
		t.Fatalf("status %v:\n%s", err, out)
	}
}

func TestRunShapeSplitWithOneRunMakesNoGroup(t *testing.T) {
	_, _, _, docs := splitCLI(t)
	testutil.FakeClaudePrint(t, splitDraft(docs.ID))
	got := shapeRuns(t, "shape", "alpha", "--title", "Fix the docs", "--split")
	r := got.Run
	if len(got.Runs) != 1 || r.GroupID != "" || r.Folder != docs.Path || r.Shape.Repo != docs.ID || r.Shape.Split || r.Shape.DraftedAt == nil {
		t.Fatalf("runs %+v", got.Runs)
	}
}

// A run for a repo that the plot does not have, or two runs for one repo,
// fail the whole draft: Loam makes no part of the split.
func TestRunShapeSplitWithABadRepoFailsTheWholeDraft(t *testing.T) {
	s, p, app, docs := splitCLI(t)
	for _, c := range []struct{ draft, want string }{
		{splitDraft(app.ID, "nosuchrepo"), `"nosuchrepo"`},
		{splitDraft(docs.ID, docs.ID), "more than one run for the repo " + docs.ID},
	} {
		testutil.FakeClaudePrint(t, c.draft)
		got := shapeRuns(t, "shape", "alpha", "--title", "Rename the setting", "--split")
		r := got.Run
		if len(got.Runs) != 1 || r.State != store.RunShaping || r.Shape.DraftedAt != nil || r.GroupID != "" ||
			!strings.Contains(r.Note, "Claude could not draft the run") || !strings.Contains(r.Note, c.want) {
			t.Fatalf("runs %+v", got.Runs)
		}
	}
	if runs, _ := s.ListRuns(p.ID); len(runs) != 2 {
		t.Fatalf("runs %+v", runs)
	}

	// A redraft of a split that failed splits again.
	runs, _ := s.ListRuns(p.ID)
	testutil.FakeClaudePrint(t, splitDraft(app.ID, docs.ID))
	got := shapeRuns(t, "redraft", runs[0].ID)
	if len(got.Runs) != 2 || got.Runs[1].GroupID != runs[0].ID {
		t.Fatalf("runs %+v", got.Runs)
	}
}

func TestRunShapeSplitWithRepoExits2(t *testing.T) {
	s, p, _, docs := splitCLI(t)
	if _, _, err := lrRun(t, "", "run", "shape", "alpha", "--title", "X", "--split", "--repo", docs.ID); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("--split with --repo: %v", err)
	}
	if runs, _ := s.ListRuns(p.ID); len(runs) != 0 || len(printCalls(t)) != 0 {
		t.Fatalf("runs %+v", runs)
	}
}

func TestRunShapeSplitInAPlotWithOneRepoIsANormalShape(t *testing.T) {
	shapeCLI(t)
	got := shapeRuns(t, "shape", "alpha", "--title", "Remember the window size per plot", "--split")
	if len(got.Runs) != 1 || got.Run.GroupID != "" || got.Run.Goal != "Loam remembers the window size of each plot." {
		t.Fatalf("runs %+v", got.Runs)
	}
	if args := testutil.FakeClaudeInvocation(t).Args; slices.Contains(args, "--add-dir") || strings.Contains(argAfter(args, "--json-schema"), `"runs"`) {
		t.Fatalf("args %q", args)
	}
}

// Claude reads every repo, so Claude Code must trust each one.
func TestRunShapeSplitNeedsEveryRepoTrusted(t *testing.T) {
	_, _, app, docs := splitCLI(t)
	trustFolder(t, app.Path)
	got := shapeRuns(t, "shape", "alpha", "--title", "Rename the setting", "--split")
	if r := got.Run; r.Shape.DraftedAt != nil || !strings.Contains(r.Note, "does not trust") || !strings.Contains(r.Note, docs.Path) {
		t.Fatalf("run %+v", r)
	}
	if calls := printCalls(t); len(calls) != 0 {
		t.Fatalf("claude calls %q", calls)
	}
}

func TestRunRedraftOfAGroupedRunRedraftsItAlone(t *testing.T) {
	s, _, app, docs := splitCLI(t)
	testutil.FakeClaudePrint(t, splitDraft(app.ID, docs.ID))
	split := shapeRuns(t, "shape", "alpha", "--title", "Rename the setting", "--split")
	first, second := split.Runs[0], split.Runs[1]

	testutil.FakeClaudePrint(t, shapeDraft)
	got := shapeRuns(t, "redraft", second.ID, "--change", "Add a check for the docs build")
	r := got.Run
	if len(got.Runs) != 1 || r.ID != second.ID || r.GroupID != first.ID || r.Folder != docs.Path || r.Shape.Repo != docs.ID ||
		r.Goal != "Loam remembers the window size of each plot." {
		t.Fatalf("runs %+v", got.Runs)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realPath(t, inv.Cwd) != docs.Path || slices.Contains(inv.Args, "--add-dir") || strings.Contains(argAfter(inv.Args, "--json-schema"), `"runs"`) {
		t.Fatalf("args %q in %s", inv.Args, inv.Cwd)
	}
	// Claude knows that the run is one part of the issue.
	if prompt := argAfter(inv.Args, "-p"); !strings.Contains(prompt, "Add a check for the docs build") || !strings.Contains(prompt, "app") {
		t.Fatalf("prompt:\n%s", prompt)
	}
	if f, _ := s.GetRun(first.ID); f.Goal != "Part 1 of the change." {
		t.Fatalf("the redraft changed the other run: %+v", f)
	}
}

// A run from a GitHub issue works in the repo of the issue, unless --repo
// names another.
func TestRunTakesTheRepoOfItsGitHubIssue(t *testing.T) {
	_, _, app, docs := splitCLI(t)
	testutil.FakeGitHub(t, filepath.Join(filepath.Dir(filepath.Dir(docs.Path)), "docs.git"))
	testutil.Git(t, docs.Path, "remote", "set-url", "origin", testutil.GitHubOrigin)
	testutil.FakeGH(t, intakeIssues)
	issue := "https://github.com/example/widgets/issues/52"

	// The intake names the repo of each GitHub issue.
	res := intakeList(t)
	if len(res.Items) != 2 || res.Items[0].Repo != docs.ID || res.Items[1].Repo != docs.ID {
		t.Fatalf("items %+v", res.Items)
	}

	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Paste a long prompt", "--link", issue, "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var started runStartOut
	if err := json.Unmarshal([]byte(out), &started); err != nil {
		t.Fatal(err)
	}
	if started.Worktree.Repo != docs.Path || started.Run.Source == nil || started.Run.Source.Key != "#52" {
		t.Fatalf("started %+v", started)
	}

	testutil.FakeClaudePrint(t, shapeDraft)
	r := shapeRun(t, "shape", "alpha", "--title", "Paste a long prompt", "--link", issue)
	if r.Shape.Repo != docs.ID || r.Folder != docs.Path {
		t.Fatalf("shape %+v", r)
	}
	r = shapeRun(t, "shape", "alpha", "--title", "Paste a long prompt", "--link", issue, "--repo", app.ID)
	if r.Shape.Repo != app.ID || r.Folder != app.Path {
		t.Fatalf("shape with --repo %+v", r)
	}
}

// linearGroup gives the run r a Linear issue, and a second run of the issue
// in the state. It returns the second run.
func linearGroup(t *testing.T, s *store.Store, r store.Run, state store.RunState) store.Run {
	t.Helper()
	src := &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Source, r.GroupID = src, r.ID
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	other, err := s.AddRun(store.Run{PlotID: r.PlotID, Folder: r.Folder, Title: r.Title, Source: src, GroupID: r.ID})
	if err != nil {
		t.Fatal(err)
	}
	if other, err = s.UpdateRun(other.ID, func(o *store.Run) error { o.State = state; return nil }); err != nil {
		t.Fatal(err)
	}
	return other
}

func linearMoves(f *testutil.FakeLinearServer) int {
	n := 0
	for _, c := range f.Calls() {
		if strings.Contains(c.Query, "issueUpdate") {
			n++
		}
	}
	return n
}

// The issue moves to Done only when its last run lands.
func TestRunLandOfAGroupKeepsTheIssueInProgressUntilTheLastRunLands(t *testing.T) {
	s, r, _ := readyRun(t)
	lin := testutil.FakeLinear(t)
	linearGroup(t, s, r, store.RunRunning)
	got, code, out := runLand(t, r.ID)
	if code != 0 || got.Run.State != store.RunLanded {
		t.Fatalf("exit %d: %s", code, out)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"ENG-523 stays In Progress: 1 more run of the issue has not landed"}) {
		t.Fatalf("linear events %q", e)
	}
	if n := linearMoves(lin); n != 0 {
		t.Fatalf("%d moves in Linear", n)
	}
}

// On the tick path too: here the other run has landed, so the issue moves.
func TestRunTickOfTheLastRunOfAGroupMovesTheIssueToDone(t *testing.T) {
	s, r, w := readyRun(t)
	testutil.FakeLinear(t)
	linearGroup(t, s, r, store.RunLanded)
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS")
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	if res := tick(t); len(res.Runs) != 1 || res.Runs[0].State != store.RunLanded {
		t.Fatalf("%+v", res)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"Moved ENG-523 to Done"}) {
		t.Fatalf("linear events %q", e)
	}
}

func TestRunTickOfAGroupWithARunLeftKeepsTheIssueInProgress(t *testing.T) {
	s, r, w := readyRun(t)
	lin := testutil.FakeLinear(t)
	linearGroup(t, s, r, store.RunShaping)
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS")
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	tick(t)
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"ENG-523 stays In Progress: 1 more run of the issue has not landed"}) {
		t.Fatalf("linear events %q", e)
	}
	if n := linearMoves(lin); n != 0 {
		t.Fatalf("%d moves in Linear", n)
	}
}

// When you stop the last run of a group, and another run landed, the issue
// is done.
func TestRunStopOfTheLastRunOfAGroupMovesTheIssueToDone(t *testing.T) {
	s, p, repo := wtCLI(t)
	testutil.FakeLinear(t)
	r, err := s.AddRun(store.Run{PlotID: p.ID, Folder: repo, Title: "Rename the setting", State: store.RunShaping})
	if err != nil {
		t.Fatal(err)
	}
	linearGroup(t, s, r, store.RunLanded)
	r = shapeRun(t, "stop", r.ID)
	if r.State != store.RunCancelled {
		t.Fatalf("run %+v", r)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"Moved ENG-523 to Done"}) {
		t.Fatalf("linear events %q", e)
	}
}

// A lone run that you stop leaves its issue as it is.
func TestRunStopOfALoneRunLeavesTheIssue(t *testing.T) {
	s, p, repo := wtCLI(t)
	lin := testutil.FakeLinear(t)
	r, err := s.AddRun(store.Run{PlotID: p.ID, Folder: repo, Title: "Rename the setting", State: store.RunShaping,
		Source: &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}})
	if err != nil {
		t.Fatal(err)
	}
	shapeRun(t, "stop", r.ID)
	if n := linearMoves(lin); n != 0 || len(events(t, s, r.ID, "linear")) != 0 {
		t.Fatalf("%d moves in Linear", n)
	}
}

// The second run of the issue to start finds it In Progress, which is fine.
func TestRunApproveOfTheSecondRunOfAGroupDoesNotWarn(t *testing.T) {
	s, _, app, docs := splitCLI(t)
	testutil.FakeLinear(t)
	testutil.FakeClaudePrint(t, splitDraft(app.ID, docs.ID))
	split := shapeRuns(t, "shape", "alpha", "--title", "Rename the setting", "--split",
		"--link", "https://linear.app/acme/issue/ENG-523/plot-panel-drag")
	for i, r := range split.Runs {
		_, errOut, err := lrRun(t, "", "run", "approve", r.ID, "--json")
		if err != nil || errOut != "" {
			t.Fatalf("approve %d: %v %s", i, err, errOut)
		}
	}
	if e := events(t, s, split.Runs[0].ID, "linear"); !slices.Equal(e, []string{"Moved ENG-523 to In Progress"}) {
		t.Fatalf("first: linear events %q", e)
	}
	if e := events(t, s, split.Runs[1].ID, "linear"); !slices.Equal(e, []string{"ENG-523 has started or ended, so Loam did not move it"}) {
		t.Fatalf("second: linear events %q", e)
	}
}
