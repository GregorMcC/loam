package cli

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"

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
		Short: "Make, list, land, or remove the git worktrees of a plot",
		Long: "A worktree is a separate checkout of one repo of a plot, on its own branch.\n" +
			"Loam keeps worktrees in <loam home>/worktrees/<plot-id>/<repo>-<name>/.\n" +
			"Making or removing a worktree is not a change in the change log. A goal edit is a change, and you can undo it.\n" +
			"The seed of the plot lists each worktree with its goal.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newWorktreeNewCmd(), newWorktreeEditCmd(), newWorktreeListCmd(), newWorktreeRmCmd(),
		newWorktreeLandCmd(), newWorktreeRerunCmd(), newWorktreeUpdateCmd())
	return c
}

func newWorktreeNewCmd() *cobra.Command {
	var base, goal, link string
	var dryRun bool
	c := &cobra.Command{
		Use:   "new <plot> <repo> <name> [--base <branch>] [--goal <text>] [--link <link-id or URL>] [--dry-run]",
		Short: "Make a worktree of a repo of a plot",
		Long: "Make a worktree. <repo> is a repo ID or a path. <name> is the branch name.\n" +
			"If the branch exists, the worktree uses it. Otherwise Loam fetches from origin and starts a new branch from --base, or from the default branch of origin. A local --base branch wins over origin/<branch>.\n" +
			"Loam copies the files of the repo settings (--copy) and the files that .worktreeinclude lists.\n" +
			"It does not run the setup command. loam start --worktree runs it.\n" +
			"--goal is one line that says what the worktree is for. The soft limit is 20 words.\n" +
			"--link is the link that the work starts from: the ID of a link of the plot, or the URL of a Linear issue or a GitHub issue. The link stays with the worktree. A URL does not go into the plot's links. Loam never fetches the issue.\n" +
			"--dry-run changes nothing and never asks origin: it reads the last fetched state. It reports whether the name is a good branch name, whether the branch exists, the default base, and the bases to choose from.",
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
			o := worktree.CreateOptions{PlotID: p.ID, Repo: args[1], Name: args[2], Base: base, Goal: goal, Link: link}
			if dryRun {
				return checkWorktree(cmd, s, o)
			}
			res, err := worktree.Create(s, o)
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
			if g := oneLine(res.Worktree.Goal); g != "" {
				fmt.Fprintf(out, "Goal: %s\n", g)
			}
			if l := res.Worktree.Link; l != nil {
				fmt.Fprintf(out, "Link: %s (%s)\n", oneLine(l.Key+" "+l.Label), noControl(l.Target))
			}
			if n := len(res.Copied); n > 0 {
				fmt.Fprintf(out, "Copied %d file(s).\n", n)
			}
			fmt.Fprintf(out, "Start a session there: loam start %s --worktree %s\n", p.ID, filepath.Base(res.Worktree.Path))
			return nil
		},
	}
	c.Flags().StringVar(&base, "base", "", "start a new branch from this branch, not from the default branch of origin")
	c.Flags().StringVar(&goal, "goal", "", "one line that says what the worktree is for")
	c.Flags().StringVar(&link, "link", "", "the ID of a link of the plot, or the URL of a Linear issue or a GitHub issue")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "change nothing and do not ask origin: check the name and list the bases")
	return c
}

// checkWorktree runs the dry run of worktree new and prints what it found.
func checkWorktree(cmd *cobra.Command, s *store.Store, o worktree.CreateOptions) error {
	res, err := worktree.Check(s, o)
	if err != nil {
		return err
	}
	if w := store.GoalWarning(o.Goal); w != "" {
		printWarnings(cmd, []string{w})
	}
	if JSON(cmd) {
		return printJSON(cmd, res)
	}
	out := cmd.OutOrStdout()
	switch {
	case !res.ValidName:
		fmt.Fprintf(out, "%s.\n", res.NameError)
	case res.WorktreeExists:
		fmt.Fprintf(out, "The plot already has the worktree %s.\n", res.Folder)
	case res.BranchExists && o.Base != "":
		fmt.Fprintf(out, "The worktree %s can use the branch %s, which exists, so --base does not apply.\n", res.Folder, res.Name)
	case res.BranchExists:
		fmt.Fprintf(out, "The worktree %s can use the branch %s, which exists.\n", res.Folder, res.Name)
	case res.DefaultBase != "":
		fmt.Fprintf(out, "The worktree %s can start a new branch %s from %s.\n", res.Folder, res.Name, res.DefaultBase)
	default:
		fmt.Fprintf(out, "The worktree %s can start a new branch %s. The last fetch did not record the default branch of origin, so give --base.\n", res.Folder, res.Name)
	}
	if len(res.Bases) > 0 {
		fmt.Fprintf(out, "Bases: %s\n", strings.Join(res.Bases, ", "))
	}
	return nil
}

func newWorktreeEditCmd() *cobra.Command {
	var goal, repo string
	var expect []string
	c := &cobra.Command{
		Use:   "edit <plot> <worktree> --goal <text> [--repo <repo>] [--expect worktree:<id>=<version>]",
		Short: "Set the goal of a worktree",
		Long: "Set the goal of a worktree: one line that says what it is for. <worktree> is an ID, a folder name, or a name.\n" +
			"A goal edit is a change in the change log, so loam undo can put the old goal back. An empty --goal clears the goal.\n" +
			"A goal over the soft limit of 20 words saves, with a warning.",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !cmd.Flags().Changed("goal") {
				return fmt.Errorf("give --goal: %w", store.ErrInvalid)
			}
			exp, err := parseExpect(expect)
			if err != nil {
				return err
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			p, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			w, err := worktree.Find(s, p.ID, repo, args[1])
			if err != nil {
				return err
			}
			res, err := commit(s, store.Change{PlotID: p.ID, Actor: cliActor(cmd), Expect: exp,
				Edits: []store.Edit{{Op: store.OpSetGoal, Item: store.WorktreeItem(w.ID), Value: goal}}})
			if err != nil {
				return staleDetail(err)
			}
			printWarnings(cmd, res.Warnings)
			if w, err = s.GetWorktree(w.ID); err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					ChangeID int64          `json:"change_id"`
					Plot     string         `json:"plot"`
					Worktree store.Worktree `json:"worktree"`
				}{res.ChangeID, p.ID, w})
			}
			if res.ChangeID == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "No change.")
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Set the goal of %s.\n", filepath.Base(w.Path))
			return nil
		},
	}
	c.Flags().StringVar(&goal, "goal", "", "the new goal: one line that says what the worktree is for")
	c.Flags().StringVar(&repo, "repo", "", "the repo of the worktree, when two repos have a worktree with that name")
	addExpectFlag(c, &expect)
	return c
}

func newWorktreeListCmd() *cobra.Command {
	var refresh bool
	var only, repo string
	c := &cobra.Command{
		Use:   "list [<plot>] [--refresh [--worktree <worktree>] [--repo <repo>]]",
		Short: "List worktrees with their checks and pull requests",
		Long: "List the worktrees of a plot, or of every plot. For each worktree, show the files with uncommitted changes, the commits that are not pushed, and whether the branch is merged into the default branch of origin. Also show the pull request (PR) of the branch on GitHub, and one stage, such as ready to merge.\n" +
			"The checks use the last fetched state. Without --refresh, the ship state comes from the last refresh, and the command does not use the network.\n" +
			"--refresh asks GitHub first, through the GitHub CLI (gh). Loam holds no credentials. A repo whose origin is not on GitHub gets no question. When GitHub does not answer, the list keeps the last ship state and says why.\n" +
			"--worktree refreshes only one worktree of the plot. It takes an ID, a folder name, or a name.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch {
			case only != "" && !refresh:
				return fmt.Errorf("--worktree works only with --refresh: %w", store.ErrInvalid)
			case only != "" && len(args) == 0:
				return fmt.Errorf("--worktree needs a plot: %w", store.ErrInvalid)
			case repo != "" && only == "":
				return fmt.Errorf("--repo works only with --worktree: %w", store.ErrInvalid)
			}
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
			if refresh {
				ws, err := s.ListWorktrees(plotID)
				if err != nil {
					return err
				}
				if only != "" {
					w, err := worktree.Find(s, plotID, repo, only)
					if err != nil {
						return err
					}
					ws = []store.Worktree{w}
				}
				// Ctrl-C stops gh, and the cache keeps its last state.
				ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
				err = worktree.RefreshPRs(ctx, s, ws)
				stop()
				if err != nil {
					return err
				}
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
				if about := goalText(st.Worktree); about != "" {
					fmt.Fprintf(out, "    %s\n", about)
				}
			}
			return nil
		},
	}
	c.Flags().BoolVar(&refresh, "refresh", false, "ask GitHub for the ship state through gh before the list")
	c.Flags().StringVar(&only, "worktree", "", "with --refresh, ask only about this worktree")
	c.Flags().StringVar(&repo, "repo", "", "the repo of --worktree, when two repos have a worktree with that name")
	return c
}

// describe is the checks and the ship state of a worktree as one line of text.
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
	switch {
	case st.PR != nil:
		text += fmt.Sprintf(", PR #%d %s", st.PR.Number, prStageText(st))
	case st.Stage == worktree.StagePushedNoPR:
		text += ", pushed, no PR"
	}
	if st.PRNote != "" {
		text += ", " + noteText[st.PRNote]
	}
	return text
}

// goalText is the goal of a worktree and its link key, such as "Link kinds
// for Figma (ENG-482)". A link that is not an issue shows its label. It is ""
// for a worktree with no goal and no link.
func goalText(w store.Worktree) string {
	ref := ""
	if w.Link != nil {
		ref = w.Link.Key
		if ref == "" {
			ref = oneLine(w.Link.Label)
		}
	}
	goal := oneLine(w.Goal)
	switch {
	case goal == "":
		return ref
	case ref == "":
		return goal
	}
	return fmt.Sprintf("%s (%s)", goal, ref)
}

// oneLine joins the lines of a text, such as a goal, so that it keeps the
// layout of the text output. It drops each control character first, so a
// terminal never acts on an escape sequence in the text. The JSON keeps the
// text as it is.
func oneLine(s string) string { return strings.Join(strings.Fields(noControl(s)), " ") }

// noControl turns each control character, such as ESC or NUL, into a space.
func noControl(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
}

// prStageText is the stage of a worktree with a PR, for the words after "PR #12".
func prStageText(st worktree.Status) string {
	if st.Stage == worktree.StageBehindBase {
		return "behind " + st.PR.Base
	}
	if text, ok := prStageWords[st.Stage]; ok {
		return text
	}
	return string(st.Stage)
}

// prStageWords holds the text of each stage of a PR. Behind base names the base.
var prStageWords = map[worktree.Stage]string{
	worktree.StageMerged:           "merged",
	worktree.StageClosed:           "closed without a merge",
	worktree.StageInMergeQueue:     "in the merge queue",
	worktree.StageConflicts:        "has conflicts",
	worktree.StageChangesRequested: "has changes requested",
	worktree.StageChecksFailed:     "has failed checks",
	worktree.StageApprovalNeeded:   "has a workflow that waits for approval",
	worktree.StageChecksRunning:    "has checks running",
	worktree.StageWaitingForReview: "waits for review",
	worktree.StageDraft:            "is a draft",
	worktree.StageBlocked:          "blocked by GitHub",
	worktree.StageReadyToMerge:     "ready to merge",
}

// noteText holds the text of each PR note.
var noteText = map[worktree.PRNote]string{
	worktree.NoteGHMissing:      "install gh to see PRs",
	worktree.NoteGHSignedOut:    "gh is signed out, run gh auth login",
	worktree.NoteNoAccess:       "gh cannot read this repo, run gh auth status",
	worktree.NoteNoGitHubRemote: "no GitHub remote",
	worktree.NoteOffline:        "could not reach GitHub",
	worktree.NoteRateLimited:    "GitHub rate limit, ship state is old",
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
			"It deletes the local branch with git branch -d, so a branch that is not merged stays. After a squash or rebase merge, git sees the branch as not merged. So when the last refresh says that the PR of the branch is merged, and the branch tip is the PR head, it uses git branch -D. It never deletes a branch on the remote.",
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
			printWarnings(cmd, res.Warnings)
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
