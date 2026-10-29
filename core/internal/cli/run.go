package cli

import (
	"cmp"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newRunCmd)
}

func newRunCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "run",
		Short: "Start, list, and stop runs: goals that a background session works on until their checks pass",
		Long: "A run is one goal that a background Claude Code session (claude --bg) works on in a worktree of a plot.\n" +
			"Each time the session ends a turn, Loam runs the Done when checks of the run in the worktree. When a check fails, Loam sends the output back to the session as its next try.\n" +
			"When every check passes in a repo on GitHub, the run ships: loam run tick pushes its branch, opens its PR, and reads CI. A CI failure goes back to the session as a try.\n" +
			"A run stops when it is ready to land (Ready), when it uses all its tries (Stopped), or when you stop it. loam run land merges the PR of a Ready run, and the run is Landed.\n" +
			"loam run limits sets how many runs work at a time. A run that finds no free slot waits in Queued, and loam run tick starts it when a slot is free.\n" +
			"Runs are not in the change log.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newRunStartCmd(), newRunShapeCmd(), newRunRedraftCmd(), newRunApproveCmd(), newRunListCmd(), newRunStatusCmd(), newRunEventsCmd(), newRunStopCmd(), newRunDiffCmd(), newRunSendBackCmd(), newRunLandCmd(), newRunTickCmd(), newRunHookCmd(), newRunDefaultsCmd(), newRunLimitsCmd())
	return c
}

func newRunStartCmd() *cobra.Command {
	var o run.StartOptions
	var checks []string
	c := &cobra.Command{
		Use:   "start <plot> --title <text> [--goal <text>] [--check <name>=<command>]... [--worktree <name>] [--repo <repo>] [--base <branch>] [--link <link-id or URL> | --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>] [--approve-setup]",
		Short: "Start a run in a worktree of a plot",
		Long: "Start a run. Loam uses the worktree that --worktree names, or makes it. With no --worktree, Loam makes a new worktree with a name from the link key and the title.\n" +
			"--check adds one Done when check: a name, \"=\", and a shell command that passes when it exits 0 in the worktree. Give it once for each check.\n" +
			"Claude Code must trust the worktree folder, because a background session cannot ask. The setup command of the repo must be approved: --approve-setup approves it.\n" +
			"The session runs in auto mode. It commits its work on the branch of the worktree.",
		Args: cobra.ExactArgs(1),
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
			if o.DoneWhen, err = parseChecks(checks); err != nil {
				return err
			}
			if o.Loam, err = loamBinary(); err != nil {
				return err
			}
			o.PlotID = p.ID
			res, err := run.Start(cmd.Context(), s, o)
			if err != nil {
				return err
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run      store.Run      `json:"run"`
					Worktree store.Worktree `json:"worktree"`
				}{res.Run, res.Worktree})
			}
			out := cmd.OutOrStdout()
			printRun(out, res.Run)
			if res.Run.State == store.RunRunning {
				fmt.Fprintf(out, "Watch it: %s\n", strings.Join(run.AttachCommand(res.Run), " "))
			}
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&o.Title, "title", "", "the title of the run (required)")
	f.StringVar(&o.Goal, "goal", "", "what the run must do")
	f.StringArrayVar(&checks, "check", nil, "a Done when check, as <name>=<command> (repeatable)")
	f.StringVar(&o.Worktree, "worktree", "", "the worktree to work in: Loam makes it when it does not exist")
	f.StringVar(&o.Repo, "repo", "", "the repo of a new worktree (default: the repo of a GitHub issue link, else the main repo)")
	f.StringVar(&o.Base, "base", "", "start a new worktree's branch from this branch, not from the default branch of origin")
	f.StringVar(&o.Link, "link", "", "the link that the work starts from: a link ID of the plot, or the URL of an issue")
	f.StringVar(&o.Ticket, "ticket", "", "the ticket of a wayfinder map that the work starts from: the path of its file, as loam intake list gives it")
	f.IntVar(&o.MaxTries, "max-tries", store.DefaultMaxTries, "how many times the checks can fail before the run stops")
	f.StringVar(&o.Model, "model", "", "the Claude model of the session (default: the run defaults of the plot, then your Claude Code setting)")
	f.StringVar(&o.Effort, "effort", "", "the effort level of the session: "+strings.Join(store.Efforts, ", ")+" (default: the run defaults of the plot, then your Claude Code setting)")
	f.BoolVar(&o.ApproveSetup, "approve-setup", false, "approve the setup command of the repo when it is new or changed")
	must(c.MarkFlagRequired("title"))
	return c
}

func newRunShapeCmd() *cobra.Command {
	var o run.ShapeOptions
	c := &cobra.Command{
		Use:   "shape <plot> --title <text> [--repo <repo> | --split] [--base <branch>] [--link <link-id or URL> | --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>]",
		Short: "Have Claude draft a run, for you to approve",
		Long: "Record a run in Shaping and have Claude draft it: the goal, the Done when checks, the assumptions that the issue does not settle, a plan, and a size. " +
			"Claude reads the repo and the issue in print mode (claude -p) with read-only tools, and changes nothing.\n" +
			"Nothing starts until you approve the run with loam run approve. A draft that fails keeps the run, with the reason as its note: draft it again with loam run redraft.\n" +
			"With --split, Claude reads every repo of the plot and drafts one run for each repo that the issue needs changes in. The runs share a group, and you approve each one.\n" +
			"The flags are as for loam run start, and they apply when you approve the run.",
		Args: cobra.ExactArgs(1),
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
			o.PlotID = p.ID
			runs, err := run.Shape(cmd.Context(), s, o)
			if err != nil {
				return err
			}
			return printShapeResult(cmd, runs)
		},
	}
	f := c.Flags()
	f.StringVar(&o.Title, "title", "", "the title of the run (required)")
	f.StringVar(&o.Repo, "repo", "", "the repo of the run (default: the repo of a GitHub issue link, else the main repo)")
	f.BoolVar(&o.Split, "split", false, "draft one run for each repo of the plot that the issue needs changes in")
	f.StringVar(&o.Base, "base", "", "start the worktree's branch from this branch, not from the default branch of origin")
	f.StringVar(&o.Link, "link", "", "the link that the work starts from: a link ID of the plot, or the URL of an issue")
	f.StringVar(&o.Ticket, "ticket", "", "the ticket of a wayfinder map that the work starts from: the path of its file, as loam intake list gives it")
	f.IntVar(&o.MaxTries, "max-tries", store.DefaultMaxTries, "how many times the checks can fail before the run stops")
	f.StringVar(&o.Model, "model", "", "the Claude model of the draft and of the session (default: the run defaults of the plot, then your Claude Code setting)")
	f.StringVar(&o.Effort, "effort", "", "the effort level of the draft and of the session: "+strings.Join(store.Efforts, ", ")+" (default: the run defaults of the plot, then your Claude Code setting)")
	must(c.MarkFlagRequired("title"))
	return c
}

func newRunRedraftCmd() *cobra.Command {
	var change string
	c := &cobra.Command{
		Use:   "redraft <run> [--change <text>]",
		Short: "Have Claude draft a Shaping run again",
		Long:  "Have Claude draft a Shaping run again. --change says what you want changed, such as \"Add a check for two screens\": Claude sees its last draft and the change.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			runs, err := run.Redraft(cmd.Context(), s, args[0], change)
			if err != nil {
				return err
			}
			return printShapeResult(cmd, runs)
		},
	}
	c.Flags().StringVar(&change, "change", "", "what you want changed in the draft")
	return c
}

func newRunApproveCmd() *cobra.Command {
	var o run.ApproveOptions
	var goal string
	var checks, answers []string
	var noChecks bool
	c := &cobra.Command{
		Use:   "approve <run> [--goal <text>] [--check <name>=<command>]... [--no-checks] [--answer <n>=<text>]... [--approve-setup]",
		Short: "Start a Shaping run with your edits to its draft",
		Long: "Start a Shaping run: Loam makes its worktree and starts its session, as loam run start does.\n" +
			"--goal replaces the drafted goal. --check replaces the drafted checks: give it once for each check. --no-checks removes the drafted checks. " +
			"--answer changes assumption <n> (from 1) to your text. An assumption with no answer stays as Claude made it.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if cmd.Flags().Changed("goal") {
				o.Goal = &goal
			}
			var err error
			switch {
			case noChecks && len(checks) > 0:
				return fmt.Errorf("give --check or --no-checks, not both: %w", store.ErrInvalid)
			case noChecks:
				o.DoneWhen = []store.Check{}
			case len(checks) > 0:
				if o.DoneWhen, err = parseChecks(checks); err != nil {
					return err
				}
			}
			if o.Answers, err = parseAnswers(answers); err != nil {
				return err
			}
			if o.Loam, err = loamBinary(); err != nil {
				return err
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			res, err := run.Approve(cmd.Context(), s, args[0], o)
			if err != nil {
				return err
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run      store.Run      `json:"run"`
					Worktree store.Worktree `json:"worktree"`
				}{res.Run, res.Worktree})
			}
			out := cmd.OutOrStdout()
			printRun(out, res.Run)
			if res.Run.State == store.RunRunning {
				fmt.Fprintf(out, "Watch it: %s\n", strings.Join(run.AttachCommand(res.Run), " "))
			}
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&goal, "goal", "", "the goal, in place of the drafted goal")
	f.StringArrayVar(&checks, "check", nil, "a Done when check, as <name>=<command>, in place of the drafted checks (repeatable)")
	f.BoolVar(&noChecks, "no-checks", false, "remove the drafted checks: the run is done when its work is committed")
	f.StringArrayVar(&answers, "answer", nil, "your answer to an assumption, as <n>=<text> (repeatable)")
	f.BoolVar(&o.ApproveSetup, "approve-setup", false, "approve the setup command of the repo when it is new or changed")
	return c
}

// parseAnswers reads --answer values: the number of an assumption, "=", and
// your text.
func parseAnswers(vals []string) (map[int]string, error) {
	out := map[int]string{}
	for _, v := range vals {
		n, text, ok := strings.Cut(v, "=")
		num, err := strconv.Atoi(strings.TrimSpace(n))
		if !ok || err != nil || strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("--answer %q: give the number of an assumption, \"=\", and your text, such as \"1=Open it in a normal window\": %w", v, store.ErrInvalid)
		}
		out[num] = text
	}
	return out, nil
}

// printShapeResult prints the runs that a shape made: as {"run": ..., "runs":
// [...]} with --json, where run is the first run.
func printShapeResult(cmd *cobra.Command, runs []store.Run) error {
	if JSON(cmd) {
		return printJSON(cmd, struct {
			Run  store.Run   `json:"run"`
			Runs []store.Run `json:"runs"`
		}{runs[0], runs})
	}
	for i, r := range runs {
		if i > 0 {
			fmt.Fprintln(cmd.OutOrStdout())
		}
		printRun(cmd.OutOrStdout(), r)
	}
	return nil
}

// parseChecks reads --check values: a name, "=", and a command.
func parseChecks(vals []string) ([]store.Check, error) {
	var out []store.Check
	for _, v := range vals {
		name, command, ok := strings.Cut(v, "=")
		name, command = strings.TrimSpace(name), strings.TrimSpace(command)
		if !ok || name == "" || command == "" {
			return nil, fmt.Errorf("--check %q: give a name, \"=\", and a command, such as \"Go tests=go test ./...\": %w", v, store.ErrInvalid)
		}
		out = append(out, store.Check{Name: name, Command: command})
	}
	return out, nil
}

func newRunListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list [<plot>]",
		Short: "List the runs of a plot, or of every plot, newest first",
		Args:  cobra.MaximumNArgs(1),
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
			runs, err := s.ListRuns(plotID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, runs)
			}
			out := cmd.OutOrStdout()
			if len(runs) == 0 {
				fmt.Fprintln(out, "No runs.")
			}
			for _, r := range runs {
				group := ""
				if r.GroupID != "" {
					group = "  group " + r.GroupID
				}
				fmt.Fprintf(out, "%s  %-13s %d/%d  %s%s\n", r.ID, r.State, r.Tries, r.MaxTries, oneLine(r.Title), group)
			}
			return nil
		},
	}
}

func newRunStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status <run>",
		Short: "Show a run and its history",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			r, err := s.GetRun(args[0])
			if err != nil {
				return err
			}
			events, err := s.RunEvents(r.ID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run    store.Run        `json:"run"`
					Events []store.RunEvent `json:"events"`
				}{r, events})
			}
			out := cmd.OutOrStdout()
			printRun(out, r)
			for _, e := range events {
				fmt.Fprintf(out, "  %s  %-5s %s\n", e.At.Format("15:04:05"), e.Kind, oneLine(e.Detail))
			}
			return nil
		},
	}
}

func newRunEventsCmd() *cobra.Command {
	var since, plot string
	c := &cobra.Command{
		Use:   "events [--since <time>] [--plot <plot>]",
		Short: "List the run events of every plot, or of one plot, newest first",
		Long:  "Lists at most 200 events of the runs, newest first. --since takes an RFC 3339 time and lists only the events after it.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var after time.Time
			if since != "" {
				t, err := time.Parse(time.RFC3339, since)
				if err != nil {
					return fmt.Errorf("--since %q is not an RFC 3339 time: %w", since, store.ErrInvalid)
				}
				after = t
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			plotID := ""
			if plot != "" {
				p, err := resolvePlot(s, plot)
				if err != nil {
					return err
				}
				plotID = p.ID
			}
			events, err := s.RunFeed(plotID, after)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Events []store.FeedEvent `json:"events"`
				}{events})
			}
			out := cmd.OutOrStdout()
			if len(events) == 0 {
				fmt.Fprintln(out, "No events.")
			}
			for _, e := range events {
				fmt.Fprintf(out, "%s  %s  %-5s %s  %s\n", e.At.Format("2006-01-02 15:04:05"), e.RunID, e.Kind, oneLine(e.Detail), oneLine(e.RunTitle))
			}
			return nil
		},
	}
	c.Flags().StringVar(&since, "since", "", "list only the events after this RFC 3339 time")
	c.Flags().StringVar(&plot, "plot", "", "list only the events of the runs of this plot")
	return c
}

func newRunStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop <run>",
		Short: "Stop the background session of a run",
		Long:  "Stop the background session of a run. The run is Cancelled. The worktree and its work stay.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			r, warnings, err := run.Stop(cmd.Context(), s, args[0])
			if err != nil {
				return err
			}
			printWarnings(cmd, warnings)
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run store.Run `json:"run"`
				}{r})
			}
			printRun(cmd.OutOrStdout(), r)
			return nil
		},
	}
}

func newRunDiffCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "diff <run>",
		Short: "Show the work that a run committed",
		Long: "Show the work that a run committed on its branch: the change from the commit where the branch left its base to the head of its worktree. For a Ready run with a PR, it ends at the head that Loam pushed (origin/<branch>), so it is the work that a land merges. Work that is not committed is not in it.\n" +
			"With --json, each file has its hunks and lines, with the line numbers before and after. A file keeps at most 3000 lines, and is marked truncated.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			res, err := run.Diff(cmd.Context(), s, args[0])
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			for _, f := range res.Files {
				name := f.Path
				if f.OldPath != "" {
					name = f.OldPath + " -> " + f.Path
				}
				fmt.Fprintf(out, "%s %s +%d -%d\n", f.Status, name, f.Added, f.Deleted)
			}
			return nil
		},
	}
}

func newRunSendBackCmd() *cobra.Command {
	var texts []string
	c := &cobra.Command{
		Use:   "send-back <run> --note <text>...",
		Short: "Send your notes on the work of a run back to its session",
		Long: "Resume the session of a run that is Ready to land or Stopped, with your notes as its next prompt. A note is \"<file>:<line>: <text>\" for a line of a file, or text alone for the whole run.\n" +
			"The run goes back to Running. When the session ends its turn, the Done when checks run again, and a run on GitHub ships the changes to its PR.\n" +
			"A note is not a failure, so it uses no try. A run that has used all its tries gets one more.\n" +
			"When a note is like a note that you sent back on another run of the plot, Loam offers to make it a rule: a check that every run of the plot must pass.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var notes []run.Note
			for _, text := range texts {
				n, err := run.ParseNote(text)
				if err != nil {
					return err
				}
				notes = append(notes, n)
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			r, offer, err := run.SendBack(cmd.Context(), s, args[0], notes)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run       store.Run      `json:"run"`
					RuleOffer *run.RuleOffer `json:"rule_offer,omitempty"`
				}{r, offer})
			}
			printRun(cmd.OutOrStdout(), r)
			if offer != nil {
				fmt.Fprintf(cmd.OutOrStdout(), "You sent a note like this on %s: %q. Make it a rule with loam rule add %s --name <name> --command <check> --note %q\n",
					offer.EarlierRunID, offer.Earlier, r.PlotID, offer.Note)
			}
			return nil
		},
	}
	c.Flags().StringArrayVar(&texts, "note", nil, "a note: \"<file>:<line>: <text>\", or text alone (repeatable)")
	return c
}

func newRunLandCmd() *cobra.Command {
	var o run.LandOptions
	var where bool
	c := &cobra.Command{
		Use:   "land <run> [--head <commit>] [--keep-worktree] [--no-linear-done] [--where-it-stands] [--dry-run]",
		Short: "Merge the PR of a run that is ready to land",
		Long: "Merge the pull request (PR) of a run that is Ready to land, as loam worktree land does: the same checks, with the default merge method of the repo. The run is Landed, and its Linear issue moves to Done.\n" +
			"Loam stops the session of the run first, because the land removes its worktree. A send-back resumes it.\n" +
			"When GitHub merges later, as with a merge queue, the run stays Ready. loam run tick lands it when GitHub has merged the PR.\n" +
			"--where-it-stands sets Where it stands of the plot to the text of the ship notes of the run, as loam set does, when the run lands.\n" +
			"It exits with code 2 when the run is not Ready or has no PR, or with --where-it-stands when the run has no ship notes, with code 16 when a check blocks the merge, and with code 17 when gh is missing or signed out.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			if where {
				r, err := s.GetRun(args[0])
				if err != nil {
					return err
				}
				if r.Notes == nil || strings.TrimSpace(r.Notes.WhereItStands) == "" {
					return fmt.Errorf("the run has no ship notes with a Where it stands to set: %w", store.ErrInvalid)
				}
			}
			// Ctrl-C stops gh. A merge that GitHub has is not undone.
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			res, err := run.Land(ctx, s, args[0], o)
			if err != nil {
				return err
			}
			if where && !o.DryRun {
				res.Warnings = append(res.Warnings, setWhereFromNotes(cmd, s, res.Run)...)
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			if o.DryRun {
				printLandPlan(cmd.OutOrStdout(), res.Land)
				return nil
			}
			printRun(cmd.OutOrStdout(), res.Run)
			return nil
		},
	}
	c.Flags().StringVar(&o.Head, "head", "", "the PR head that you looked at. The merge stops with code 16 when the PR has another head")
	c.Flags().BoolVar(&o.KeepWorktree, "keep-worktree", false, "keep the worktree after the merge")
	c.Flags().BoolVar(&o.NoLinearDone, "no-linear-done", false, "leave the Linear issue where it is: this land does not move it to Done")
	c.Flags().BoolVar(&where, "where-it-stands", false, "set Where it stands of the plot to the text of the ship notes of the run")
	c.Flags().BoolVar(&o.DryRun, "dry-run", false, "change nothing, and print the plan and each check")
	c.Flags().StringArrayVar(&o.OpenPanes, "open-pane", nil, "the folder of an open pane (repeatable). The app passes its open panes.")
	return c
}

// setWhereFromNotes sets Where it stands of the plot of a landed run to the
// text of its ship notes, as loam set does: one change in the change log. A
// run that has not landed changes nothing. It returns the warnings.
func setWhereFromNotes(cmd *cobra.Command, s *store.Store, r store.Run) []string {
	if r.State != store.RunLanded {
		return []string{"The run has not landed yet, so Where it stands stays as it is"}
	}
	res, err := commit(s, store.Change{
		PlotID: r.PlotID, Actor: cliActor(cmd),
		Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: r.Notes.WhereItStands}},
	})
	if err != nil {
		return []string{"Could not set Where it stands: " + err.Error()}
	}
	return res.Warnings
}

func newRunTickCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "tick",
		Short: "Ship the runs whose checks passed, and start the queued runs",
		Long: "Move on each run in Shipping. Loam pushes the branch of the run and opens its PR. When CI passes on the PR, the run is Ready.\n" +
			"When CI fails, Loam sends the end of each failed log back to the session, and the failure counts a try. On the last try, the run stops.\n" +
			"Then start the Queued runs, oldest first, while a slot is free and the week's usage is under the hold of loam run limits.\n" +
			"A tick that waits on GitHub or for a slot changes nothing, so it is safe to run often. The app runs it while a run ships.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			loam, err := loamBinary()
			if err != nil {
				return err
			}
			res, err := run.Tick(cmd.Context(), s, loam)
			if err != nil {
				return err
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			for _, r := range res.Runs {
				printRun(cmd.OutOrStdout(), r)
			}
			return nil
		},
	}
}

func newRunHookCmd() *cobra.Command {
	return &cobra.Command{
		Use:    "hook <run>",
		Short:  "Answer a Claude Code hook of a run session (used by runs)",
		Hidden: true,
		Args:   cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return nil // a hook never fails the session for a missing store
			}
			defer s.Close()
			if code := run.Hook(s, args[0], cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr()); code != 0 {
				return exitCode(code)
			}
			return nil
		},
	}
}

// printRun prints the first lines of a run for a person.
func printRun(out io.Writer, r store.Run) {
	fmt.Fprintf(out, "Run %s: %s\n", r.ID, oneLine(r.Title))
	turns := fmt.Sprintf("%d turns", r.Turns)
	if r.Turns == 1 {
		turns = "1 turn"
	}
	fmt.Fprintf(out, "State: %s, try %d of %d, %s\n", r.State, r.Tries, r.MaxTries, turns)
	fmt.Fprintf(out, "Folder: %s\n", r.Folder)
	if r.GroupID != "" {
		fmt.Fprintf(out, "Group: %s\n", r.GroupID)
	}
	if n := oneLine(r.Note); n != "" {
		fmt.Fprintf(out, "Note: %s\n", n)
	}
}

// exitCode is an error that ends loam with its code and prints nothing. A
// hook uses it to block Claude Code with exit code 2.
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit code %d", int(e)) }

func newRunDefaultsCmd() *cobra.Command {
	var model, effort string
	c := &cobra.Command{
		Use:   "defaults <plot> [--model <model>] [--effort <level>]",
		Short: "Show or set the model and effort that runs of a plot use",
		Long: "A run, a Shape run, and a recurring run of the plot use these defaults when they name no model or effort. Empty means your Claude Code setting.\n" +
			"With no flag, this shows the defaults. A flag sets that default, and an empty value clears it. Run defaults are not in the change log.",
		Args: cobra.ExactArgs(1),
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
			d, err := s.GetRunDefaults(p.ID)
			if err != nil {
				return err
			}
			f := cmd.Flags()
			if f.Changed("model") || f.Changed("effort") {
				if f.Changed("model") {
					d.Model = model
				}
				if f.Changed("effort") {
					d.Effort = effort
				}
				if d, err = s.SetRunDefaults(d); err != nil {
					return err
				}
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"defaults": d})
			}
			fmt.Fprintf(cmd.OutOrStdout(), "model: %s\neffort: %s\n", cmp.Or(d.Model, "(Claude Code setting)"), cmp.Or(d.Effort, "(Claude Code setting)"))
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&model, "model", "", "set the default model; empty clears it")
	f.StringVar(&effort, "effort", "", "set the default effort level ("+strings.Join(store.Efforts, ", ")+"); empty clears it")
	return c
}

func newRunLimitsCmd() *cobra.Command {
	var l store.RunLimits
	c := &cobra.Command{
		Use:   "limits [--at-a-time <n>] [--max-turns <n>] [--hold-at <percent>]",
		Short: "Show or set the limits of every run: runs at a time, turns, and the usage hold",
		Long: "The run limits hold for every run of every plot.\n" +
			"--at-a-time is how many runs can work at once, 1 to " + strconv.Itoa(store.AtATimeLimit) + ". A run that starts with no free slot waits in Queued, and loam run tick starts it when a slot is free.\n" +
			"--max-turns is how many turns a run can take. A run whose checks still fail at the limit stops, and no try counts. 0 means no limit.\n" +
			"--hold-at is a percent of the 7-day usage of Claude Code. At or over it, a run that starts waits in Queued. 0 turns the hold off. loam usage shows the usage.\n" +
			"With no flag, this shows the limits. Run limits are not in the change log.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			cur, err := s.GetRunLimits()
			if err != nil {
				return err
			}
			f := cmd.Flags()
			if f.Changed("at-a-time") || f.Changed("max-turns") || f.Changed("hold-at") {
				if !f.Changed("at-a-time") {
					l.AtATime = cur.AtATime
				}
				if !f.Changed("max-turns") {
					l.MaxTurns = cur.MaxTurns
				}
				if !f.Changed("hold-at") {
					l.HoldAt = cur.HoldAt
				}
				if cur, err = s.SetRunLimits(l); err != nil {
					return err
				}
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"limits": cur})
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "At a time: %d runs\n", cur.AtATime)
			if cur.MaxTurns == 0 {
				fmt.Fprintln(out, "Each run: no turn limit")
			} else {
				fmt.Fprintf(out, "Each run: %d turns\n", cur.MaxTurns)
			}
			if cur.HoldAt == 0 {
				fmt.Fprintln(out, "Hold new runs: off")
			} else {
				fmt.Fprintf(out, "Hold new runs at: %d%% of the week\n", cur.HoldAt)
			}
			return nil
		},
	}
	f := c.Flags()
	f.IntVar(&l.AtATime, "at-a-time", 0, "how many runs can work at once")
	f.IntVar(&l.MaxTurns, "max-turns", 0, "how many turns a run can take; 0 means no limit")
	f.IntVar(&l.HoldAt, "hold-at", 0, "the percent of the 7-day usage at which new runs wait; 0 turns the hold off")
	return c
}
