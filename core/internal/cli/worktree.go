package cli

import (
	"fmt"
	"path/filepath"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/spf13/cobra"
)

func init() {
	Register(newWorktreeCmd)
}

func newWorktreeCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "worktree",
		Short: "Make, list, or remove the git worktrees of a plot",
		Long: "A worktree is a separate checkout of one repo of a plot, on its own branch.\n" +
			"Loam keeps worktrees in <loam home>/worktrees/<plot-id>/<repo>-<name>/.\n" +
			"Making or removing a worktree is not a change in the change log.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newWorktreeNewCmd(), newWorktreeListCmd(), newWorktreeRmCmd())
	return c
}

func newWorktreeNewCmd() *cobra.Command {
	var base string
	c := &cobra.Command{
		Use:   "new <plot> <repo> <name> [--base <branch>]",
		Short: "Make a worktree of a repo of a plot",
		Long: "Make a worktree. <repo> is a repo ID or a path. <name> is the branch name.\n" +
			"If the branch exists, the worktree uses it. Otherwise Loam fetches from origin and starts a new branch from --base, or from the default branch of origin. A local --base branch wins over origin/<branch>.\n" +
			"Loam copies the files of the repo settings (--copy) and the files that .worktreeinclude lists.\n" +
			"It does not run the setup command. loam start --worktree runs it.",
		Args: cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			p, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			res, err := worktree.Create(s, worktree.CreateOptions{PlotID: p.ID, Repo: args[1], Name: args[2], Base: base})
			if err != nil {
				return err
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				copied := res.Copied
				if copied == nil {
					copied = []string{}
				}
				return printJSON(cmd, struct {
					Worktree store.Worktree `json:"worktree"`
					Copied   []string       `json:"copied"`
				}{res.Worktree, copied})
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "Worktree %s on branch %s: %s\n", filepath.Base(res.Worktree.Path), res.Worktree.Branch, res.Worktree.Path)
			if n := len(res.Copied); n > 0 {
				fmt.Fprintf(out, "Copied %d file(s).\n", n)
			}
			fmt.Fprintf(out, "Start a session there: loam start %s --worktree %s\n", p.ID, filepath.Base(res.Worktree.Path))
			return nil
		},
	}
	c.Flags().StringVar(&base, "base", "", "start a new branch from this branch, not from the default branch of origin")
	return c
}

func newWorktreeListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list [<plot>]",
		Short: "List worktrees with their checks",
		Long: "List the worktrees of a plot, or of every plot. For each worktree, show the files with uncommitted changes, the commits that are not pushed, and whether the branch is merged into the default branch of origin.\n" +
			"The checks use the last fetched state. They do not use the network.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			plotID := ""
			if len(args) == 1 {
				p, err := resolvePlot(s, args[0])
				if err != nil {
					return err
				}
				plotID = p.ID
			}
			list, err := worktree.List(s, plotID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, list)
			}
			out := cmd.OutOrStdout()
			for _, st := range list {
				fmt.Fprintf(out, "%s  %s  %s\n", filepath.Base(st.Worktree.Path), st.Worktree.Branch, describe(st))
			}
			return nil
		},
	}
}

// describe is the checks of a worktree as one line of text.
func describe(st worktree.Status) string {
	text := ""
	switch {
	case st.Missing:
		text = "folder is gone"
	case st.Changed > 0:
		text = fmt.Sprintf("%d changed", st.Changed)
	default:
		text = "clean"
	}
	text += fmt.Sprintf(", %d unpushed", st.Unpushed)
	switch {
	case st.MergedInto == "":
		text += ", merge state unknown"
	case st.Merged:
		text += ", merged into " + st.MergedInto
	default:
		text += ", not merged into " + st.MergedInto
	}
	if st.Error != "" {
		text += ", check failed: " + st.Error
	}
	return text
}

func newWorktreeRmCmd() *cobra.Command {
	var force bool
	var panes []string
	var repo string
	c := &cobra.Command{
		Use:   "rm <plot> <worktree> [--repo <repo>] [--force]",
		Short: "Remove a worktree",
		Long: "Remove a worktree. <worktree> is an ID, a folder name, or a name.\n" +
			"The command refuses while a pane is open in the worktree. It reads the panes of state.json in ~/Library/Application Support/Loam, and the folders of each --open-pane. --force does not skip this check.\n" +
			"It also refuses a worktree with uncommitted changes or commits that are not pushed, unless you give --force.\n" +
			"It deletes the local branch with git branch -d, so a branch that is not merged stays. It never deletes a branch on the remote.",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			p, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			res, err := worktree.Remove(s, p.ID, args[1], worktree.RemoveOptions{Force: force, OpenPanes: panes, Repo: repo})
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "Removed the worktree %s.\n", filepath.Base(res.Worktree.Path))
			if res.BranchDeleted {
				fmt.Fprintf(out, "Deleted the local branch %s.\n", res.Worktree.Branch)
			} else if res.BranchNote != "" {
				fmt.Fprintln(out, res.BranchNote)
			}
			return nil
		},
	}
	c.Flags().BoolVar(&force, "force", false, "remove a worktree that has uncommitted changes or unpushed commits")
	c.Flags().StringVar(&repo, "repo", "", "the repo of the worktree, when two repos have a worktree with that name")
	c.Flags().StringArrayVar(&panes, "open-pane", nil, "the folder of an open pane (repeatable). The app passes its open panes.")
	return c
}
