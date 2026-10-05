package mcpserver

import (
	"context"
	"errors"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type listWorktreesIn struct{ plotArg }

type createWorktreeIn struct {
	plotArg
	Name   string `json:"name" jsonschema:"name of the worktree. It is the branch name, for example the branch name of a Linear issue. If the branch exists, the worktree uses it."`
	RepoID string `json:"repo_id,omitempty" jsonschema:"ID of the repo, from get_plot. Default: the main repo."`
	Base   string `json:"base,omitempty" jsonschema:"branch that a new branch starts from. Default: the default branch of origin. Not for a branch that exists."`
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
	mcp.AddTool(srv, &mcp.Tool{
		Name: "list_worktrees",
		Description: "List the git worktrees of the plot. Each has its name, branch, folder, and repo, and three checks: " +
			"changed files, commits that are not pushed, and whether the branch is merged." + plotNote,
		Annotations: readOnly("List worktrees"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in listWorktreesIn) (*mcp.CallToolResult, any, error) {
		plotID, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		if _, err := s.loadPlot(plotID); err != nil {
			return fail(err)
		}
		list, err := worktree.List(s.st, plotID)
		if err != nil {
			return fail(err)
		}
		return reply(listWorktreesOut{Worktrees: list})
	})

	open := true
	no := false
	mcp.AddTool(srv, &mcp.Tool{
		Name: "create_worktree",
		Description: "Make a git worktree of a repo of the plot. The name is the branch name. If the branch exists, the worktree uses it. " +
			"Otherwise Loam fetches from origin and starts a new branch from base, or from the default branch of origin. " +
			"Loam copies the files that the repo settings and .worktreeinclude list. It does not run the setup command and it does not start a session. " +
			"The person starts a session in the worktree." + plotNote,
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
		res, err := worktree.Create(s.st, worktree.CreateOptions{PlotID: plotID, Repo: repo, Name: in.Name, Base: in.Base})
		if err != nil {
			return fail(err)
		}
		copied := res.Copied
		if copied == nil {
			copied = []string{}
		}
		return reply(createWorktreeOut{Worktree: res.Worktree, Copied: copied, Warnings: res.Warnings})
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
