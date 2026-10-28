package cli

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/spf13/cobra"
)

func newWorktreeLandCmd() *cobra.Command {
	var o worktree.LandOptions
	var method string
	c := &cobra.Command{
		Use:   "land <plot> <worktree> [--method squash|merge|rebase] [--auto] [--keep-worktree] [--keep-remote-branch] [--dry-run] [--head <commit>]",
		Short: "Merge the PR of a worktree, then delete its branches and remove it",
		Long: "Merge the pull request (PR) of a worktree on GitHub, through the GitHub CLI (gh). <worktree> is an ID, a folder name, or a name.\n" +
			"The command asks GitHub for the PR first, and stops when GitHub does not answer. It reads the merge methods that the repo allows, the default method, and the merge queue of the base branch.\n" +
			"Then it runs the checks: checks, review, behind_base, conflicts, github, local_changes, and unpushed_commits. It exits with code 16 when a check blocks: a failed check, changes requested, conflicts, a draft, uncommitted changes, or commits that are not pushed. Behind base blocks when the base branch needs the PR up to date. When GitHub blocks the merge for another reason, the github check blocks a merge now, but not --auto.\n" +
			"The merge names the PR head that Loam checked, so GitHub refuses it when the PR has a new commit. With --head <commit>, the command also stops before it merges, with code 16, when the PR head is not that commit: the caller looked at another commit, such as the plan that the app showed. After the merge, the command deletes the branch on GitHub, then removes the worktree as loam worktree rm does. It refuses while a pane is open in the worktree. When gh merges at once with --auto and a pane is open, it deletes nothing and removes nothing, and records the land.\n" +
			"With --auto, or a merge queue, GitHub merges later. The command records the land on the worktree and keeps the worktree. A later land of the same PR keeps what the recorded land keeps. A recorded land of another PR is stale, and the command clears it.\n" +
			"For a PR that is merged, the command skips the merge and does what comes after it. When the local repo does not have the PR head, it fetches it from GitHub first. It exits with code 16 when the worktree has work that is not in the PR, or when it cannot fetch the PR head.\n" +
			"--dry-run changes nothing. It prints the plan and each check. It exits with code 0 when a check blocks.\n" +
			"It exits with code 17 when gh is missing or signed out, or the origin of the repo is not on GitHub.",
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
			o.Method = github.MergeMethod(method)
			// Ctrl-C stops gh. A merge that GitHub has is not undone.
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			res, err := worktree.Land(ctx, s, p.ID, args[1], o)
			if err != nil {
				return err
			}
			// A merge ends the runs of the worktree at once, so a land from
			// the sidebar does not leave them waiting for a tick.
			var landed []store.Run
			var warnings []string
			if !o.DryRun && res.Merged && res.PR != nil {
				landed, warnings = run.LandWorktree(cmd.Context(), s, p.ID, res.Worktree.ID, res.PR.Number, run.MergedNote(res))
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			if o.DryRun {
				printLandPlan(cmd.OutOrStdout(), res)
				return nil
			}
			printLand(cmd.OutOrStdout(), res)
			for _, r := range landed {
				fmt.Fprintf(cmd.OutOrStdout(), "Landed the run %s.\n", r.Title)
			}
			for _, w := range warnings {
				fmt.Fprintln(cmd.ErrOrStderr(), w)
			}
			return nil
		},
	}
	c.Flags().StringVar(&method, "method", "", "the merge method: squash, merge, or rebase. The default is the default method of the repo")
	c.Flags().BoolVar(&o.Auto, "auto", false, "turn on auto merge: GitHub merges the PR when its checks pass")
	c.Flags().BoolVar(&o.KeepWorktree, "keep-worktree", false, "keep the worktree after the merge")
	c.Flags().BoolVar(&o.KeepRemoteBranch, "keep-remote-branch", false, "keep the branch on GitHub after the merge")
	c.Flags().BoolVar(&o.DryRun, "dry-run", false, "change nothing, and print the plan and each check")
	c.Flags().StringVar(&o.Head, "head", "", "the PR head that you looked at. A merge stops with code 16 when the PR has another head. A dry run ignores it")
	c.Flags().StringVar(&o.Repo, "repo", "", "the repo of the worktree, when two repos have a worktree with that name")
	c.Flags().StringArrayVar(&o.OpenPanes, "open-pane", nil, "the folder of an open pane (repeatable). The app passes its open panes.")
	return c
}

// printLandPlan prints the plan of a dry run.
func printLandPlan(out io.Writer, res *worktree.LandResult) {
	fmt.Fprintf(out, "PR #%d %s: %s\n", res.PR.Number, res.PR.Title, stageWord(res.Stage))
	if res.LandNote != "" {
		fmt.Fprintln(out, res.LandNote)
	}
	switch {
	case res.Merged:
		fmt.Fprintln(out, "The PR is merged. Land does what comes after the merge.")
	default:
		fmt.Fprintf(out, "Methods: %s (default %s)\n", joinStrings(res.Methods), res.DefaultMethod)
		if res.MergeQueue {
			fmt.Fprintf(out, "The base branch %s has a merge queue.\n", res.PR.Base)
		}
	}
	for _, c := range res.Checks {
		line := fmt.Sprintf("  %s: %s", c.Name, c.State)
		if c.Blocks {
			line += " (blocks)"
		}
		fmt.Fprintln(out, line)
	}
	switch {
	case !res.Ready:
		fmt.Fprintln(out, "Not ready to land.")
	case res.Merged:
		fmt.Fprintln(out, "Ready to land.")
	case res.MergeQueue:
		fmt.Fprintln(out, "Ready to land: Loam adds the PR to the merge queue.")
	default:
		fmt.Fprintf(out, "Ready to land with %s.\n", res.Method)
	}
}

// printLand prints what a land did.
func printLand(out io.Writer, res *worktree.LandResult) {
	pr := res.PR
	if res.LandNote != "" {
		fmt.Fprintln(out, res.LandNote)
	}
	switch {
	case res.Merged && pr.State == "MERGED":
		fmt.Fprintf(out, "PR #%d is merged.\n", pr.Number)
	case res.Merged:
		fmt.Fprintf(out, "Merged PR #%d with %s.\n", pr.Number, res.Method)
	case res.MergeNote != "":
		fmt.Fprintln(out, res.MergeNote)
	case res.MergeQueue:
		fmt.Fprintf(out, "Added PR #%d to the merge queue of %s. Loam keeps the worktree until the merge.\n", pr.Number, pr.Base)
	default:
		fmt.Fprintf(out, "GitHub merges PR #%d when it can. Loam keeps the worktree until the merge.\n", pr.Number)
	}
	if res.RemoteBranchDeleted {
		fmt.Fprintf(out, "Deleted the branch %s on GitHub.\n", pr.Head)
	}
	for _, note := range []string{res.RemoteBranchNote, res.WorktreeNote} {
		if note != "" {
			fmt.Fprintln(out, note)
		}
	}
	if res.WorktreeRemoved {
		fmt.Fprintf(out, "Removed the worktree %s.\n", filepath.Base(res.Worktree.Path))
		if res.BranchDeleted {
			fmt.Fprintf(out, "Deleted the local branch %s.\n", res.Worktree.Branch)
		} else if res.BranchNote != "" {
			fmt.Fprintln(out, res.BranchNote)
		}
	}
}

// stageWord is the text of a stage of a PR.
func stageWord(s worktree.Stage) string {
	if text, ok := prStageWords[s]; ok {
		return text
	}
	return string(s)
}

func joinStrings[T ~string](items []T) string {
	names := make([]string, len(items))
	for i, it := range items {
		names[i] = string(it)
	}
	return strings.Join(names, ", ")
}

func newWorktreeRerunCmd() *cobra.Command {
	var repo string
	c := &cobra.Command{
		Use:   "rerun <plot> <worktree> [--repo <repo>]",
		Short: "Run the failed checks of the PR of a worktree again",
		Long: "Run the failed jobs of the pull request (PR) of a worktree again, through the GitHub CLI (gh): one gh run rerun --failed for each GitHub Actions run with a failed check.\n" +
			"The command asks GitHub for the PR first. The PR must be open. A failed check that is not a job of GitHub Actions stays as it is. The result lists it.\n" +
			"The command tries each run, and says why GitHub did not start a run. It exits with code 1 when no run started.\n" +
			"It exits with code 17 when gh is missing or signed out, or the origin of the repo is not on GitHub.",
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
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			res, err := worktree.Rerun(ctx, s, p.ID, repo, args[1])
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			started := 0
			for _, r := range res.Runs {
				if r.Started {
					started++
				}
			}
			if len(res.Runs) == 0 {
				fmt.Fprintf(out, "PR #%d has no failed GitHub Actions run.\n", res.PR.Number)
			} else {
				fmt.Fprintf(out, "Started the failed jobs of %d run(s) again for PR #%d.\n", started, res.PR.Number)
			}
			for _, r := range res.Runs {
				if !r.Started {
					fmt.Fprintln(out, r.Note)
				}
			}
			if len(res.SkippedChecks) > 0 {
				fmt.Fprintf(out, "Loam cannot run these failed checks again: %s. Run them again where they ran.\n", strings.Join(res.SkippedChecks, ", "))
			}
			return nil
		},
	}
	c.Flags().StringVar(&repo, "repo", "", "the repo of the worktree, when two repos have a worktree with that name")
	return c
}

func newWorktreeUpdateCmd() *cobra.Command {
	var repo string
	c := &cobra.Command{
		Use:   "update <plot> <worktree> [--repo <repo>]",
		Short: "Bring the PR of a worktree up to date with its base branch",
		Long: "Bring the pull request (PR) of a worktree up to date with its base branch on GitHub, through the GitHub CLI (gh pr update-branch). GitHub adds a merge commit to the branch. Then the command fetches the branch, so the local repo has the new PR head.\n" +
			"The command asks GitHub for the PR first. The PR must be open. It does not change the branch of the worktree. Pull to get the merge commit.\n" +
			"It exits with code 17 when gh is missing or signed out, or the origin of the repo is not on GitHub.",
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
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			res, err := worktree.Update(ctx, s, p.ID, repo, args[1])
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			text := fmt.Sprintf("GitHub brought PR #%d up to date with %s.", res.PR.Number, res.PR.Base)
			if res.Fetched {
				text += fmt.Sprintf(" Fetched %s.", res.Worktree.Branch)
			}
			fmt.Fprintln(out, text)
			if res.FetchNote != "" {
				fmt.Fprintln(out, res.FetchNote)
			}
			return nil
		},
	}
	c.Flags().StringVar(&repo, "repo", "", "the repo of the worktree, when two repos have a worktree with that name")
	return c
}
