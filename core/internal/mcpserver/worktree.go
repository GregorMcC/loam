package mcpserver

import (
	"context"
	"errors"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type listWorktreesIn struct {
	plotArg
	Refresh bool `json:"refresh,omitempty" jsonschema:"set to true to ask GitHub for the pull request of each worktree first, through the gh CLI. It takes a few seconds. The default reads the state of the last refresh."`
}

type createWorktreeIn struct {
	plotArg
	Name   string `json:"name" jsonschema:"name of the worktree. It is the branch name, for example the branch name of a Linear issue. If the branch exists, the worktree uses it."`
	RepoID string `json:"repo_id,omitempty" jsonschema:"ID of the repo, from get_plot. Default: the main repo."`
	Base   string `json:"base,omitempty" jsonschema:"branch that a new branch starts from. Default: the default branch of origin. Not for a branch that exists."`
	Goal   string `json:"goal,omitempty" jsonschema:"one line that says what the worktree is for. The soft limit is 20 words."`
	Link   string `json:"link,omitempty" jsonschema:"the link that the work starts from: the ID of a link of the plot, from get_plot, or the URL of a Linear issue or a GitHub issue. A URL does not go into the links of the plot."`
}

type setWorktreeGoalIn struct {
	plotArg
	WorktreeID string `json:"worktree_id" jsonschema:"ID of the worktree, from list_worktrees"`
	Goal       string `json:"goal" jsonschema:"new goal: one line that says what the worktree is for. The soft limit is 20 words. An empty goal clears it."`
}

type listWorktreesOut struct {
	Worktrees []worktree.Status `json:"worktrees"`
}

type createWorktreeOut struct {
	Worktree store.Worktree `json:"worktree"`
	Copied   []string       `json:"copied"`
	Warnings []string       `json:"warnings,omitempty"`
}

func (s *Server) registerWorktrees(srv *mcp.Server) {
	open := true
	// list_worktrees stays read-only with refresh: the refresh writes only
	// Loam's internal PR cache, and the plot does not change.
	mcp.AddTool(srv, &mcp.Tool{
		Name: "list_worktrees",
		Description: "List the git worktrees of the plot. Each has its name, branch, folder, repo, goal, and link (or null), and three checks: " +
			"changed files, commits that are not pushed, and whether the branch is merged. " +
			"Each also has its pull request on GitHub (pr, or null), its stage (such as checks_failed or ready_to_merge), " +
			"pr_note (why the ship state is missing or old), and pr_checked_at (when it came from GitHub)." + plotNote,
		Annotations: &mcp.ToolAnnotations{Title: "List worktrees", ReadOnlyHint: true, OpenWorldHint: &open},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in listWorktreesIn) (*mcp.CallToolResult, any, error) {
		plotID, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		if _, err := s.loadPlot(plotID); err != nil {
			return fail(err)
		}
		if in.Refresh {
			ws, err := s.st.ListWorktrees(plotID)
			if err != nil {
				return fail(err)
			}
			if err := worktree.RefreshPRs(ctx, s.st, ws); err != nil { // a cancelled call stops gh
				return fail(err)
			}
		}
		list, err := worktree.List(s.st, plotID)
		if err != nil {
			return fail(err)
		}
		ws := make([]store.Worktree, len(list))
		for i, st := range list {
			ws[i] = st.Worktree
		}
		s.rememberGoals(plotID, ws...)
		return reply(listWorktreesOut{Worktrees: list})
	})

	no := false
	mcp.AddTool(srv, &mcp.Tool{
		Name: "create_worktree",
		Description: "Make a git worktree of a repo of the plot. The name is the branch name. If the branch exists, the worktree uses it. " +
			"Otherwise Loam fetches from origin and starts a new branch from base, or from the default branch of origin. " +
			"Loam copies the files that the repo settings and .worktreeinclude list. It does not run the setup command and it does not start a session. " +
			"The person starts a session in the worktree. " +
			"Give a goal and the link the work starts from when you know them. The seed of the plot lists each worktree with its goal." + plotNote,
		Annotations: &mcp.ToolAnnotations{Title: "Create a worktree", DestructiveHint: &no, OpenWorldHint: &open},
	}, func(_ context.Context, _ *mcp.CallToolRequest, in createWorktreeIn) (*mcp.CallToolResult, any, error) {
		plotID, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		plot, err := s.loadPlot(plotID)
		if err != nil {
			return fail(err)
		}
		repo := in.RepoID
		if repo == "" {
			m := plot.MainRepo()
			if m == nil {
				return fail(errors.New("the plot has no repo: add a repo with add_repo first"))
			}
			repo = m.ID
		}
		res, err := worktree.Create(s.st, worktree.CreateOptions{PlotID: plotID, Repo: repo, Name: in.Name, Base: in.Base, Goal: in.Goal, Link: in.Link})
		if err != nil {
			return fail(err)
		}
		s.rememberGoals(plotID, res.Worktree)
		copied := res.Copied
		if copied == nil {
			copied = []string{}
		}
		return reply(createWorktreeOut{Worktree: res.Worktree, Copied: copied, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name: "set_worktree_goal",
		Description: "Set the goal of a worktree: one line that says what it is for. The goal is a change in the change log, and the seed of the plot lists it. " +
			"Call list_worktrees first." + plotNote,
		Annotations: changes("Set a worktree goal"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in setWorktreeGoalIn) (*mcp.CallToolResult, any, error) {
		if in.WorktreeID == "" {
			return fail(errors.New("worktree_id is required: call list_worktrees to see the IDs"))
		}
		item := store.WorktreeItem(in.WorktreeID)
		res, err := s.write(in.Plot, []string{item}, nil, []store.Edit{{Op: store.OpSetGoal, Item: item, Value: in.Goal}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})
}

// saveSettings sets the worktree settings of a repo of the plot. The settings
// belong to the repo path and are not a change.
func (s *Server) saveSettings(plot store.Plot, repoID string, setup *string, files *[]string) error {
	for _, r := range plot.Repos {
		if r.ID == repoID {
			return s.st.SetRepoSettings(r.Path, setup, files)
		}
	}
	return errors.New("no repo has the ID " + repoID + " in this plot: call get_plot to see the repo IDs")
}
