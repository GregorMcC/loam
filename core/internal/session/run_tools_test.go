package session_test

import (
	"context"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/mcpserver"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// runReadTools and runDeniedTools are the rules of a run session, by name, so
// that a change shows in the diff. A new tool of the MCP server fails
// TestRunRulesCoverEachToolOfTheServer until it is in one of these lists.
var (
	runReadTools = []string{"get_changes", "get_plot", "list_plots", "list_worktrees"}

	runDeniedTools = []string{
		"add_link", "add_repo", "create_plot", "create_worktree", "remove_link", "remove_repo", "rename_plot",
		"set_main_repo", "set_what_why", "set_where_it_stands", "set_worktree_goal", "undo_change", "update_link",
		"update_repo", "work_in_worktree",
	}
)

// loamRules returns the rules of the Loam tools, with the prefix cut off.
func loamRules(in []string) []string {
	var out []string
	for _, r := range in {
		if t, ok := strings.CutPrefix(r, "mcp__loam__"); ok {
			out = append(out, t)
		}
	}
	return out
}

// TestRunSettingsDenyTheWriteToolsOfTheServer covers a new run and a resumed
// run: claude --resume does not keep the rules of the session.
func TestRunSettingsDenyTheWriteToolsOfTheServer(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	r := store.Run{ID: "r1", PlotID: p.ID, Folder: repo, SessionID: "s1"}
	plans := map[string]func() (*session.Plan, error){
		"new":     func() (*session.Plan, error) { return session.PrepareRun(e.store, r, "go", "loam", "", "") },
		"resumed": func() (*session.Plan, error) { return session.PrepareRunResume(e.store, r, "go", "loam", "", "") },
	}
	for name, prepare := range plans {
		t.Run(name, func(t *testing.T) {
			plan, err := prepare()
			if err != nil {
				t.Fatal(err)
			}
			allow, deny := runPermissions(t, plan)
			if got := loamRules(allow); !slices.Equal(got, runReadTools) {
				t.Errorf("allow %q, want %q", got, runReadTools)
			}
			if got := loamRules(deny); !slices.Equal(got, runDeniedTools) {
				t.Errorf("deny %q, want %q", got, runDeniedTools)
			}
			last := plan.Args[len(plan.Args)-1]
			if !strings.Contains(last, "only the read tools of the Loam MCP server") || !strings.Contains(last, "last message") {
				t.Errorf("prompt = %q, want the note about the Loam tools", last)
			}
			if strings.Contains(last, "set_where_it_stands") {
				t.Errorf("prompt = %q, names a tool that the run cannot call", last)
			}
		})
	}
}

// runPermissions returns the rules in the settings file of plan.
func runPermissions(t *testing.T, plan *session.Plan) (allow, deny []string) {
	t.Helper()
	files := argValues(plan.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("args %v have no one --settings", plan.Args)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Permissions struct{ Allow, Deny []string }
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	return got.Permissions.Allow, got.Permissions.Deny
}

// TestRunRulesCoverEachToolOfTheServer fails when the server registers a tool
// that is in neither list above, or when a list names a tool that it does not
// register.
func TestRunRulesCoverEachToolOfTheServer(t *testing.T) {
	tools, err := mcpserver.Tools(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) == 0 {
		t.Fatal("the server has no tools")
	}
	registered := map[string]bool{}
	for _, tl := range tools {
		registered[tl.Name] = true
		switch inRead, inDenied := slices.Contains(runReadTools, tl.Name), slices.Contains(runDeniedTools, tl.Name); {
		case !inRead && !inDenied:
			t.Errorf("tool %s is neither read nor denied: add it to a list above", tl.Name)
		case inRead != tl.ReadOnly:
			t.Errorf("tool %s: read-only %v, in the read list %v", tl.Name, tl.ReadOnly, inRead)
		}
	}
	for _, name := range slices.Concat(runReadTools, runDeniedTools) {
		if !registered[name] {
			t.Errorf("the server does not register %s", name)
		}
	}
}

// TestRunToolRulesDenyANewTool: a tool with no read-only marker is denied with
// no change to the session code.
func TestRunToolRulesDenyANewTool(t *testing.T) {
	allow, deny := session.RunToolRules([]mcpserver.Tool{{Name: "read_it", ReadOnly: true}, {Name: "new_tool"}})
	if !slices.Equal(allow, []string{"mcp__loam__read_it"}) {
		t.Errorf("allow %q", allow)
	}
	if !slices.Equal(deny, []string{"mcp__loam__new_tool"}) {
		t.Errorf("deny %q", deny)
	}
}
