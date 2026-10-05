package mcpserver

import (
	"context"
	"errors"
	"path/filepath"

	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type linkIn struct {
	Label  string `json:"label" jsonschema:"short name of the link"`
	Target string `json:"target" jsonschema:"a URL, or an absolute path that starts with / or ~"`
	Note   string `json:"note,omitempty" jsonschema:"one line about why the link matters"`
}

type repoIn struct {
	Path string `json:"path" jsonschema:"absolute path of the repo folder"`
	Note string `json:"note,omitempty" jsonschema:"one line about the repo"`
}

type createPlotIn struct {
	Name  string   `json:"name" jsonschema:"name of the plot"`
	What  string   `json:"what" jsonschema:"What part of the brief: what the work is"`
	Why   string   `json:"why" jsonschema:"Why part of the brief: why the work matters"`
	Where string   `json:"where_it_stands,omitempty" jsonschema:"Where it stands: what is done, what is next"`
	Links []linkIn `json:"links,omitempty" jsonschema:"links to add"`
	Repos []repoIn `json:"repos,omitempty" jsonschema:"repos to add. The first repo is the main repo."`
}

type renamePlotIn struct {
	plotArg
	Name string `json:"name" jsonschema:"new name of the plot"`
}

type addRepoIn struct {
	plotArg
	Path  string   `json:"path" jsonschema:"absolute path of the repo folder"`
	Note  string   `json:"note,omitempty" jsonschema:"one line about the repo"`
	Setup *string  `json:"setup,omitempty" jsonschema:"command that runs in each new worktree of the repo, for example npm ci. Every plot that holds the repo shares it. The person approves it before it first runs."`
	Copy  []string `json:"copy,omitempty" jsonschema:"files or globs, relative to the repo, to copy into each new worktree, for example .env"`
}

type updateRepoIn struct {
	plotArg
	RepoID string    `json:"repo_id" jsonschema:"ID of the repo, from get_plot"`
	Note   *string   `json:"note,omitempty" jsonschema:"new note"`
	Setup  *string   `json:"setup,omitempty" jsonschema:"new setup command for worktrees of the repo. An empty string clears it. The person approves a new or changed command before it runs."`
	Copy   *[]string `json:"copy,omitempty" jsonschema:"new list of files or globs to copy into each new worktree. An empty list clears it."`
}

type removeRepoIn struct {
	plotArg
	RepoID        string `json:"repo_id" jsonschema:"ID of the repo, from get_plot"`
	NewMainRepoID string `json:"new_main_repo_id,omitempty" jsonschema:"ID of the repo that becomes the main repo. Needed when you remove the main repo and more than one other repo is left."`
}

type setMainRepoIn struct {
	plotArg
	RepoID string `json:"repo_id" jsonschema:"ID of the repo that becomes the main repo, from get_plot"`
}

type createOut struct {
	PlotID   string   `json:"plot_id"`
	ChangeID int64    `json:"change_id"`
	Warnings []string `json:"warnings,omitempty"`
}

// switchNote says what a repo add does to the checkout (ticket 91).
const switchNote = "Loam then switches the checkout to the default branch of origin, at its latest commit, unless it has uncommitted changes."

func (s *Server) registerPlotRepo(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "create_plot",
		Description: "Create a plot with a name, a What part, and a Why part. You can also give Where it stands, links, and repos. The first repo is the main repo. Each repo's git remote is added as a link, unless the links hold it. " + switchNote + " You do not need get_plot first. The result has the new plot ID.",
		Annotations: addOnly("Create a plot"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in createPlotIn) (*mcp.CallToolResult, any, error) {
		actor, err := s.actor()
		if err != nil {
			return fail(err)
		}
		pi := store.PlotInput{Name: in.Name, What: in.What, Why: in.Why, Where: in.Where}
		for _, l := range in.Links {
			pi.Links = append(pi.Links, store.LinkInput{Label: l.Label, Target: l.Target, Note: l.Note})
		}
		for _, r := range in.Repos {
			path := linkkind.Expand(r.Path) // A leading ~ is the home folder.
			if err := checkRepoFolder(path); err != nil {
				return fail(err)
			}
			pi.Repos = append(pi.Repos, store.RepoInput{Path: path, Note: r.Note})
		}
		// Each repo's remote comes as a link, unless the links hold it.
		pi.Links = gitremote.AddLinks(pi.Links, pi.Repos)
		res, err := s.st.CreatePlot(pi, actor)
		if err != nil {
			return fail(err)
		}
		// The creator knows the plot, so it can write to it at once.
		s.remember(res.Plot)
		seed.AfterChange(s.st, res)
		warnings := res.Warnings
		for _, r := range pi.Repos {
			warnings = append(warnings, worktree.SwitchToDefault(r.Path)...)
		}
		return reply(createOut{PlotID: res.Plot.ID, ChangeID: res.ChangeID, Warnings: warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "rename_plot",
		Description: "Change the name of the plot. Call get_plot first." + plotNote,
		Annotations: changes("Rename a plot"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in renamePlotIn) (*mcp.CallToolResult, any, error) {
		res, err := s.write(in.Plot, []string{store.ItemName}, nil, []store.Edit{{Op: store.OpSet, Item: store.ItemName, Value: in.Name}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name: "add_repo",
		Description: "Add a repo to the plot. The path must be absolute. The first repo of a plot is the main repo. " +
			"The repo's git remote is added as a link in the same change, unless the plot has it. " + switchNote + " " +
			"You can also set the setup command and the files to copy for worktrees of the repo. Call get_plot first." + plotNote,
		Annotations: addOnly("Add a repo"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in addRepoIn) (*mcp.CallToolResult, any, error) {
		in.Path = linkkind.Expand(in.Path) // A leading ~ is the home folder.
		if err := checkRepoFolder(in.Path); err != nil {
			return fail(err)
		}
		edits := []store.Edit{{Op: store.OpAddRepo, Path: store.S(in.Path), Note: store.S(in.Note)}}
		// The repo's remote comes as a link in the same change, so one undo removes both.
		if id, err := s.resolvePlot(in.Plot); err == nil {
			if p, err := s.loadPlot(id); err == nil {
				if link, ok := gitremote.LinkEdit(p, in.Path); ok {
					edits = append(edits, link)
				}
			}
		}
		res, err := s.write(in.Plot, nil, nil, edits)
		if err != nil {
			return fail(err)
		}
		id := repoID(res)
		// The switch comes before the settings, so a failed save cannot skip it.
		warnings := res.Warnings
		if res.ChangeID != 0 {
			warnings = append(warnings, worktree.SwitchToDefault(in.Path)...)
		}
		if in.Setup != nil || len(in.Copy) > 0 {
			var files *[]string
			if len(in.Copy) > 0 {
				files = &in.Copy
			}
			if err := s.saveSettings(res.Plot, id, in.Setup, files); err != nil {
				return fail(err)
			}
		}
		return reply(writeOut{ChangeID: res.ChangeID, RepoID: id, Warnings: warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name: "update_repo",
		Description: "Change the note of a repo, or its worktree settings: the setup command and the files to copy. " +
			"Call get_plot first to change the note." + plotNote,
		Annotations: changes("Update a repo"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in updateRepoIn) (*mcp.CallToolResult, any, error) {
		if in.RepoID == "" {
			return fail(errors.New("repo_id is required"))
		}
		if in.Note == nil && in.Setup == nil && in.Copy == nil {
			return fail(errors.New("give note, setup, or copy"))
		}
		item := store.RepoItem(in.RepoID)
		out := writeOut{}
		if in.Note != nil {
			res, err := s.write(in.Plot, []string{item}, nil, []store.Edit{{Op: store.OpUpdateRepo, Item: item, Note: in.Note}})
			if err != nil {
				return fail(err)
			}
			out = writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings}
		}
		if in.Setup != nil || in.Copy != nil {
			plotID, err := s.resolvePlot(in.Plot)
			if err != nil {
				return fail(err)
			}
			plot, err := s.loadPlot(plotID)
			if err != nil {
				return fail(err)
			}
			if err := s.saveSettings(plot, in.RepoID, in.Setup, in.Copy); err != nil {
				return fail(err)
			}
		}
		return reply(out)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name: "remove_repo",
		Description: "Remove a repo from the plot. If you remove the main repo and more than one other repo is left, " +
			"pass new_main_repo_id, or call set_main_repo first. Call get_plot first." + plotNote,
		Annotations: changes("Remove a repo"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in removeRepoIn) (*mcp.CallToolResult, any, error) {
		if in.RepoID == "" {
			return fail(errors.New("repo_id is required"))
		}
		plotID, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		cur, err := s.loadPlot(plotID)
		if err != nil {
			return fail(err)
		}
		var target *store.Repo
		for i := range cur.Repos {
			if cur.Repos[i].ID == in.RepoID {
				target = &cur.Repos[i]
			}
		}
		if target == nil {
			return fail(errors.New("no repo has the ID " + in.RepoID + " in this plot: call get_plot to see the repo IDs"))
		}
		item := store.RepoItem(in.RepoID)
		items := []string{item}
		var edits []store.Edit
		switch {
		case in.NewMainRepoID != "":
			if !target.Main {
				return fail(errors.New("new_main_repo_id is only for removing the main repo"))
			}
			if in.NewMainRepoID == in.RepoID {
				return fail(errors.New("new_main_repo_id must be another repo"))
			}
			nm := store.RepoItem(in.NewMainRepoID)
			items = append(items, nm)
			edits = append(edits, store.Edit{Op: store.OpSetMainRepo, Item: nm})
		case target.Main && len(cur.Repos) > 2:
			return fail(errors.New("this is the main repo and other repos are left: call set_main_repo for another repo first, or pass new_main_repo_id"))
		}
		edits = append(edits, store.Edit{Op: store.OpRemoveRepo, Item: item})
		res, err := s.write(plotID, items, []string{item}, edits)
		if err != nil {
			if errors.Is(err, store.ErrNeedMainRepo) {
				return fail(errors.New("this is the main repo and other repos are left: call set_main_repo for another repo first, or pass new_main_repo_id"))
			}
			return fail(err)
		}
		// With one other repo left, the store promotes it in this change.
		if m := res.Plot.MainRepo(); m != nil && target.Main {
			s.refresh(res, store.RepoItem(m.ID))
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_main_repo",
		Description: "Make a repo the main repo of the plot. A session starts in the main repo. Call get_plot first." + plotNote,
		Annotations: changes("Set the main repo"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in setMainRepoIn) (*mcp.CallToolResult, any, error) {
		if in.RepoID == "" {
			return fail(errors.New("repo_id is required"))
		}
		plotID, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		cur, err := s.loadPlot(plotID)
		if err != nil {
			return fail(err)
		}
		oldMain := ""
		if m := cur.MainRepo(); m != nil {
			oldMain = store.RepoItem(m.ID)
		}
		item := store.RepoItem(in.RepoID)
		res, err := s.write(plotID, []string{item}, nil, []store.Edit{{Op: store.OpSetMainRepo, Item: item}})
		if err != nil {
			return fail(err)
		}
		// The old main repo changed in this call too.
		if oldMain != "" {
			s.refresh(res, oldMain)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})
}

// checkRepoFolder fails for an absolute repo path that is not a folder. The
// store gives a relative path its own error.
func checkRepoFolder(path string) error {
	if !filepath.IsAbs(path) {
		return nil
	}
	return store.CheckRepoFolder(path)
}
