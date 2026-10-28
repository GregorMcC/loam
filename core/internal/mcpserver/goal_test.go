package mcpserver_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

const githubIssue = "https://github.com/example/widgets/issues/57"

type createdWorktree struct {
	Worktree store.Worktree `json:"worktree"`
	Warnings []string       `json:"warnings"`
}

func TestCreateWorktreeWithGoalAndLink(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	withGitRepo(t, e)
	var c createdWorktree
	out := e.ok("create_worktree", map[string]any{"name": "fix-57", "goal": "Fix the login form", "link": githubIssue})
	if err := json.Unmarshal([]byte(out), &c); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	// The origin of the repo is a folder, not GitHub, so the key names the
	// repo of the issue.
	want := store.WorktreeLink{Target: githubIssue, Label: "widgets#57", Key: "example/widgets#57"}
	if c.Worktree.Goal != "Fix the login form" || c.Worktree.Link == nil || *c.Worktree.Link != want || len(c.Warnings) != 0 {
		t.Fatalf("%+v %+v", c, c.Worktree.Link)
	}
	if links := e.plotNow(e.plot.ID).Links; len(links) != 0 { // the URL stays out of the plot links
		t.Fatalf("links %+v", links)
	}
	// A plot link by its ID copies its target and label.
	const linearIssue = "https://linear.app/example/issue/ENG-482/link-kinds-for-figma"
	res, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("Link kinds for Figma"), Target: store.S(linearIssue)}}})
	if err != nil {
		t.Fatal(err)
	}
	linkID := res.Plot.Links[0].ID
	if err := json.Unmarshal([]byte(e.ok("create_worktree", map[string]any{"name": "eng-482", "link": linkID})), &c); err != nil {
		t.Fatal(err)
	}
	want = store.WorktreeLink{Target: linearIssue, Label: "Link kinds for Figma", Key: "ENG-482", LinkID: linkID}
	if c.Worktree.Link == nil || *c.Worktree.Link != want {
		t.Fatalf("%+v %+v", c.Worktree, c.Worktree.Link)
	}
	// A URL that is not an issue fails. A long goal saves with a warning.
	if out := e.fail("create_worktree", map[string]any{"name": "bad", "link": "https://github.com/example/widgets/pull/57"}); !strings.Contains(out, "issue") {
		t.Fatalf("%s", out)
	}
	if err := json.Unmarshal([]byte(e.ok("create_worktree", map[string]any{"name": "long", "goal": strings.Repeat("word ", 24)})), &c); err != nil {
		t.Fatal(err)
	}
	if len(c.Warnings) != 1 || c.Warnings[0] != "The goal has 24 words. The soft limit is 20 words. Shorten it." {
		t.Fatalf("warnings %q", c.Warnings)
	}
	// list_worktrees shows the goal and the link.
	if out := e.ok("list_worktrees", nil); !strings.Contains(out, `"goal": "Fix the login form"`) || !strings.Contains(out, `"key": "example/widgets#57"`) {
		t.Fatalf("%s", out)
	}
	// The seed lists the worktrees.
	b, err := os.ReadFile(seed.Path(e.s, e.plot.ID))
	if err != nil || !strings.Contains(string(b), ": Fix the login form (example/widgets#57, from origin/main)") {
		t.Fatalf("seed: %v\n%s", err, b)
	}
}

func TestSetWorktreeGoal(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA", session: "sess-env"})
	withGitRepo(t, e)
	var c createdWorktree
	if err := json.Unmarshal([]byte(e.ok("create_worktree", map[string]any{"name": "fix-login"})), &c); err != nil {
		t.Fatal(err)
	}
	id := c.Worktree.ID

	// create_worktree counts as a read of the new worktree.
	out := e.ok("set_worktree_goal", map[string]any{"worktree_id": id, "goal": "Fix the login form"})
	if !strings.Contains(out, "change_id") {
		t.Fatalf("%s", out)
	}
	last := e.lastChange()
	if last.Actor.Kind != store.ActorSession || last.Actor.SessionID != "sess-env" || len(last.Entries) != 1 ||
		last.Entries[0].Item != store.WorktreeItem(id) || last.Entries[0].Field != "goal" {
		t.Fatalf("%+v", last)
	}
	if w, _ := e.s.GetWorktree(id); w.Goal != "Fix the login form" {
		t.Fatalf("goal %q", w.Goal)
	}
	b, _ := os.ReadFile(seed.Path(e.s, e.plot.ID))
	if !strings.Contains(string(b), "-fix-login: Fix the login form (from origin/main)") {
		t.Fatalf("seed:\n%s", b)
	}

	// Another writer sets the goal. The next write is stale until Claude reads again.
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorApp},
		Edits: []store.Edit{{Op: store.OpSetGoal, Item: store.WorktreeItem(id), Value: "Theirs"}}}); err != nil {
		t.Fatal(err)
	}
	out = e.fail("set_worktree_goal", map[string]any{"worktree_id": id, "goal": "Mine"})
	if !strings.Contains(out, "Theirs") || !strings.Contains(out, "stale") {
		t.Fatalf("%s", out)
	}
	if w, _ := e.s.GetWorktree(id); w.Goal != "Theirs" {
		t.Fatalf("a stale write went through: %q", w.Goal)
	}
	e.ok("list_worktrees", nil)
	out = e.ok("set_worktree_goal", map[string]any{"worktree_id": id, "goal": strings.Repeat("word ", 21)})
	if !strings.Contains(out, "The goal has 21 words. The soft limit is 20 words. Shorten it.") {
		t.Fatalf("%s", out)
	}
	// The undo of a goal edit puts the goal back.
	e.ok("undo_change", map[string]any{"change_id": e.lastChange().ID})
	if w, _ := e.s.GetWorktree(id); w.Goal != "Theirs" {
		t.Fatalf("goal %q", w.Goal)
	}

	e.fail("set_worktree_goal", map[string]any{"goal": "x"})                                      // no worktree
	e.fail("set_worktree_goal", map[string]any{"worktree_id": "nosuchwtre", "goal": "x"})         // not read
	e.fail("set_worktree_goal", map[string]any{"worktree_id": id, "goal": "x", "plot": "nosuch"}) // no such plot
}

func TestSetWorktreeGoalNeedsARead(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo := withGitRepo(t, e)
	// The worktree comes from outside this session, so Claude has not read it.
	w, err := e.s.AddWorktree(store.Worktree{PlotID: e.plot.ID, Repo: repo, Name: "outside", Branch: "outside", Path: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if out := e.fail("set_worktree_goal", map[string]any{"worktree_id": w.ID, "goal": "x"}); !strings.Contains(out, "list_worktrees") {
		t.Fatalf("%s", out)
	}
	// get_plot does not show the goals, so it is not a read of them.
	e.ok("get_plot", nil)
	if out := e.fail("set_worktree_goal", map[string]any{"worktree_id": w.ID, "goal": "x"}); !strings.Contains(out, "list_worktrees") {
		t.Fatalf("%s", out)
	}
	e.ok("list_worktrees", nil)
	e.ok("set_worktree_goal", map[string]any{"worktree_id": w.ID, "goal": "x"})
}

// list_worktrees is not a read of the plot, so a plot write still needs get_plot.
func TestListWorktreesIsNotAReadOfThePlot(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	withGitRepo(t, e)
	e.ok("list_worktrees", nil)
	e.ok("create_worktree", map[string]any{"name": "fix-login"})
	if out := e.fail("add_link", map[string]any{"label": "Spec", "target": "https://example.com/spec"}); !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
}

// A get_plot after list_worktrees keeps the goal version that Claude read, so
// a goal that changed after that read is still stale.
func TestGetPlotKeepsTheGoalVersionThatClaudeRead(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	withGitRepo(t, e)
	var c createdWorktree
	if err := json.Unmarshal([]byte(e.ok("create_worktree", map[string]any{"name": "fix-login", "goal": "Mine"})), &c); err != nil {
		t.Fatal(err)
	}
	e.ok("list_worktrees", nil)
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorApp},
		Edits: []store.Edit{{Op: store.OpSetGoal, Item: store.WorktreeItem(c.Worktree.ID), Value: "Theirs"}}}); err != nil {
		t.Fatal(err)
	}
	e.ok("get_plot", nil)
	out := e.fail("set_worktree_goal", map[string]any{"worktree_id": c.Worktree.ID, "goal": "Mine again"})
	if !strings.Contains(out, "stale") || !strings.Contains(out, "Theirs") || !strings.Contains(out, "Call list_worktrees") {
		t.Fatalf("%s", out)
	}
	// An undo makes Claude read the worktrees again.
	e.ok("list_worktrees", nil)
	e.ok("set_worktree_goal", map[string]any{"worktree_id": c.Worktree.ID, "goal": "Mine again"})
	e.ok("undo_change", map[string]any{"change_id": e.lastChange().ID})
	if out := e.fail("set_worktree_goal", map[string]any{"worktree_id": c.Worktree.ID, "goal": "x"}); !strings.Contains(out, "call list_worktrees") {
		t.Fatalf("%s", out)
	}
}
