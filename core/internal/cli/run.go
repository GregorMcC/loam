package cli

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/GregorMcC/loam/core/internal/claudebin"
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
		Short: "Start, list, and cancel runs: goals that a background session works on until their checks pass",
		Long: "A run is one goal that a background Claude Code session (claude --bg) works on in a worktree of a plot.\n" +
			"Each time the session ends a turn, Loam runs the Done when checks of the run in the worktree. When a check fails, Loam sends the output back to the session as its next try.\n" +
			"When every check passes in a repo on GitHub, the run ships: loam run tick pushes its branch, opens its PR, and reads CI. A CI failure goes back to the session as a try.\n" +
			"A run stops when it is ready to land (Ready), when it uses all its tries (Stopped), or when you cancel it (Cancelled). loam run land merges the PR of a Ready run, and the run is Landed.\n" +
			"loam run limits sets how many runs work at a time. A run that finds no free slot waits in Queued, and loam run tick starts it when a slot is free.\n" +
			"Runs are not in the change log.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newRunStartCmd(), newRunShapeCmd(), newRunRedraftCmd(), newRunApproveCmd(), newRunListCmd(), newRunStatusCmd(), newRunEventsCmd(), newRunCancelCmd(), newRunStopCmd(), newRunDiffCmd(), newRunSendBackCmd(), newRunSendReviewCmd(), newRunLandCmd(), newRunTickCmd(), newRunHookCmd(), newRunDefaultsCmd(), newRunMCPServersCmd(), newRunLimitsCmd(), newRunMetricsCmd(), newRunSandboxCmd())
	return c
}

func newRunStartCmd() *cobra.Command {
	var o run.StartOptions
	var checks []string
	c := &cobra.Command{
		Use:   "start <plot> --title <text> [--goal <text>] [--check <name>=<command>]... [--worktree <name>] [--repo <repo>] [--base <branch>] [--link <link-id or URL> | --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>] [--approve-setup <sha256>] [--fixes <run>]",
		Short: "Start a run in a worktree of a plot",
		Long: "Start a run. Loam uses the worktree that --worktree names, or makes it. With no --worktree, Loam makes a new worktree with a name from the link key and the title.\n" +
			"--check adds one Done when check: a name, \"=\", and a shell command that passes when it exits 0 in the worktree. Give it once for each check.\n" +
			"Claude Code must trust the worktree folder, because a background session cannot ask. The setup command of the repo must be approved: --approve-setup with the SHA-256 hash of the command approves it, and Loam refuses a hash of another command.\n" +
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
	f.Var(setupHashFlag{&o.ApproveSetup}, "approve-setup", "approve the setup command of the repo when it is new or changed: the SHA-256 hash of the command that you read")
	f.StringVar(&o.Fixes, "fixes", "", "the ID of the landed run of the plot that this run fixes")
	must(c.MarkFlagRequired("title"))
	return c
}

func newRunShapeCmd() *cobra.Command {
	var o run.ShapeOptions
	c := &cobra.Command{
		Use:   "shape <plot> --title <text> [--repo <repo> | --split] [--base <branch>] [--link <link-id or URL> | --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>] [--fixes <run>]",
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
	f.StringVar(&o.Fixes, "fixes", "", "the ID of the landed run of the plot that this run fixes")
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
		Use:   "approve <run> [--goal <text>] [--check <name>=<command>]... [--no-checks] [--answer <n>=<text>]... [--drop-follow-up <n>]... [--approve-setup <sha256>]",
		Short: "Start a Shaping run with your edits to its draft",
		Long: "Start a Shaping run: Loam makes its worktree and starts its session, as loam run start does.\n" +
			"--goal replaces the drafted goal. --check replaces the drafted checks: give it once for each check. --no-checks removes the drafted checks. " +
			"--answer changes assumption <n> (from 1) to your text. An assumption with no answer stays as Claude made it.\n" +
			"Loam files each follow-up of the draft as an issue, and --drop-follow-up <n> (from 1) drops follow-up <n> instead. " +
			"A follow-up that Loam cannot file is a warning, and the run starts anyway.",
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
	f.IntSliceVar(&o.DropFollowUps, "drop-follow-up", nil, "drop follow-up <n> of the draft, so Loam files no issue for it (repeatable)")
	f.Var(setupHashFlag{&o.ApproveSetup}, "approve-setup", "approve the setup command of the repo when it is new or changed: the SHA-256 hash of the command that you read")
	return c
}

// setupHashPattern is the form of a hash for --approve-setup: lowercase hex.
var setupHashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// setupHashFlag is the value of --approve-setup: the [run.SetupHash] of the
// setup command that you read. The flag has no bare form, because a bare flag
// would approve a command that nobody named.
type setupHashFlag struct{ hash *string }

func (f setupHashFlag) String() string {
	if f.hash == nil {
		return ""
	}
	return *f.hash
}

func (f setupHashFlag) Type() string { return "sha256" }

func (f setupHashFlag) Set(v string) error {
	if !setupHashPattern.MatchString(v) {
		return errors.New("give the lowercase hex SHA-256 hash of the setup command that you read. The refusal of the run names it")
	}
	*f.hash = v
	return nil
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
			failed := slices.DeleteFunc(run.LastGate(events), func(c store.RunCheckResult) bool { return c.Passed })
			if failed == nil {
				failed = []store.RunCheckResult{}
			}
			review := run.LastCodeReview(events)
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Run          store.Run                 `json:"run"`
					Events       []store.RunEvent          `json:"events"`
					FailedChecks []store.RunCheckResult    `json:"failed_checks"`
					CodeReview   *store.RunCodeReviewRound `json:"code_review"`
				}{r, events, failed, review})
			}
			out := cmd.OutOrStdout()
			printRun(out, r)
			if line := run.CodeReviewRounds(r); line != "" {
				fmt.Fprintln(out, line)
			}
			for _, e := range events {
				fmt.Fprintf(out, "  %s  %-5s %s\n", e.At.Format("15:04:05"), e.Kind, oneLine(e.Detail))
			}
			printFailedChecks(out, failed)
			printFindings(out, review)
			return nil
		},
	}
}

// statusTail is how many lines of the output of a failed check run status
// shows. The JSON has all that Loam stored.
const statusTail = 20

// printFailedChecks prints each check that failed in the last gate: its name,
// its exit code, and the end of its output.
func printFailedChecks(out io.Writer, failed []store.RunCheckResult) {
	if len(failed) == 0 {
		return
	}
	fmt.Fprintln(out, "Failed checks of the last gate:")
	for _, c := range failed {
		fmt.Fprintf(out, "  %s (exit %d)\n", oneLine(c.Name), c.Exit)
		text := strings.TrimSpace(c.Output)
		if text == "" {
			fmt.Fprintln(out, "    The check gave no output.")
			continue
		}
		for _, line := range strings.Split(run.Tail(text, statusTail), "\n") {
			fmt.Fprintln(out, strings.TrimRight("    "+noControl(line), " "))
		}
	}
}

// printFindings prints the findings of the last code review, most severe
// first.
func printFindings(out io.Writer, review *store.RunCodeReviewRound) {
	if review == nil || len(review.Findings) == 0 {
		return
	}
	fmt.Fprintln(out, "Findings of the last code review:")
	for _, f := range review.Findings {
		place := oneLine(f.File)
		if place != "" && f.Line > 0 {
			place += fmt.Sprintf(":%d", f.Line)
		}
		if place != "" {
			place += ": "
		}
		needs := ""
		if f.NeedsYou != "" {
			needs = " (needs you: " + oneLine(f.NeedsYou) + ")"
		}
		fmt.Fprintf(out, "  %s: %s%s%s\n", run.SeverityLabel(f.Severity), place, oneLine(f.Text), needs)
	}
	if review.More > 0 {
		fmt.Fprintf(out, "  and %d more\n", review.More)
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

func newRunCancelCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cancel <run>",
		Short: "Cancel a run",
		Long:  "Cancel a run: Loam stops its background session, and the run is Cancelled. A Cancelled run cannot go back to its session. The worktree and its work stay.",
		Args:  cobra.ExactArgs(1),
		RunE:  runCancel,
	}
}

// stopWarning is what loam run stop prints: the verb stop is not the state
// Stopped, which can go back to its session.
const stopWarning = "loam run stop cancels the run. Use loam run cancel."

// newRunStopCmd is the old name of loam run cancel, for older callers. It
// prints [stopWarning] to stderr, and its JSON is the JSON of run cancel.
func newRunStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:    "stop <run>",
		Short:  "Cancel a run (old name of loam run cancel)",
		Long:   "The old name of loam run cancel. The run is Cancelled, not Stopped.",
		Args:   cobra.ExactArgs(1),
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Fprintln(cmd.ErrOrStderr(), stopWarning)
			return runCancel(cmd, args)
		},
	}
}

func runCancel(cmd *cobra.Command, args []string) error {
	s, err := openStore()
	if err != nil {
		return err
	}
	defer s.Close()
	r, warnings, err := run.Cancel(cmd.Context(), s, args[0])
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
		Long: "Resume the session of a run that is Ready to land, Shipping, or Stopped, with your notes as its next prompt. A note is \"<file>:<line>: <text>\" for a line of a file, or text alone for the whole run.\n" +
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

func newRunSendReviewCmd() *cobra.Command {
	var dryRun bool
	c := &cobra.Command{
		Use:   "send-review <run> [--dry-run]",
		Short: "Send the review of the PR of a run back to its session",
		Long: "Resume the session of a run that is Ready to land, with the review of its pull request (PR) as its next prompt: each thread that is not resolved, and each review that requests changes and that Loam has not sent. This is what loam run tick sends when the review requests changes, but here you choose to send it, so the review decision does not matter.\n" +
			"The prompt leaves out the text of a comment whose author cannot push to the repo. The run goes back to Running. When the session ends its turn, the Done when checks run again, and Loam ships the fix to the PR. You choose this send, so it uses no review try.\n" +
			"--dry-run changes nothing. It reads the PR and says what Loam would send, which can be nothing.\n" +
			"It exits with code 2 when the run is not Ready to land, has no PR, or when the PR has no review to send, and with code 17 when gh is missing or signed out.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			// Ctrl-C stops gh.
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			res, err := run.SendReview(ctx, s, args[0], dryRun)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			if dryRun {
				fmt.Fprintf(out, "#%d: %d threads and %d reviews to send\n", res.PR.Number, res.Threads, res.Reviews)
				return nil
			}
			printRun(out, res.Run)
			return nil
		},
	}
	c.Flags().BoolVar(&dryRun, "dry-run", false, "change nothing, and say what Loam would send")
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
	if r.Fixes != "" {
		fmt.Fprintf(out, "Fixes: %s\n", r.Fixes)
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
	var model, effort, mcp, review, reviewEffort string
	var checks []string
	var noChecks bool
	c := &cobra.Command{
		Use:   "defaults <plot> [--model <model>] [--effort <level>] [--mcp <names>] [--review on|off] [--review-effort <level>] [--check <name>=<command>]... [--no-checks]",
		Short: "Show or set the model, the effort, the MCP servers, and the code review that runs of a plot use",
		Long: "A run, a Shape run, and a recurring run of the plot use these defaults when they name no model or effort. Empty means your Claude Code setting.\n" +
			"--mcp names the MCP servers, comma-separated, that claude -p loads when it drafts a run, writes the PR text, or reviews the code. Loam copies each one from the user scope of your Claude Code config " +
			"(claude mcp add --scope user). It does not read .mcp.json, which a PR or a run can change and whose approval --mcp-config skips, or a local scope, which is keyed by folder while a run works in a worktree. " +
			"A server with a headersHelper cannot be selected, because claude -p would run the helper in the worktree. " +
			"claude.ai connectors are not in a local config file, so you cannot select them. " +
			"The tools of a selected server run as your Claude Code permissions allow, so a tool that your settings allow can write. " +
			"Empty means no MCP server. A name that Loam cannot find stops the draft.\n" +
			"--review turns on or off the code review that Loam runs before it pushes a run of the plot. It is on by default. " +
			"--review-effort is the effort level of that review. Empty means your Claude Code setting.\n" +
			"--check sets the Done when checks of a run of the plot that names none: a name, \"=\", and a shell command, as for loam run start. --no-checks clears them. A run that names a check uses only its own.\n" +
			"With no flag, this shows the defaults. A flag sets that default. An empty --model, --effort, --mcp, or --review-effort clears it. Run defaults are not in the change log.",
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
			if f.Changed("model") || f.Changed("effort") || f.Changed("mcp") || f.Changed("review") || f.Changed("review-effort") || f.Changed("check") || f.Changed("no-checks") {
				if f.Changed("model") {
					d.Model = model
				}
				if f.Changed("effort") {
					d.Effort = effort
				}
				if f.Changed("mcp") {
					d.MCPServers = strings.Split(mcp, ",")
				}
				if f.Changed("review") {
					switch review {
					case "on":
						d.Review = true
					case "off":
						d.Review = false
					default:
						return fmt.Errorf("--review takes on or off, not %q: %w", review, store.ErrInvalid)
					}
				}
				if f.Changed("review-effort") {
					d.ReviewEffort = reviewEffort
				}
				if noChecks && f.Changed("check") {
					return fmt.Errorf("--no-checks and --check cannot go together: %w", store.ErrInvalid)
				}
				if noChecks {
					d.Checks = []store.Check{}
				}
				if f.Changed("check") {
					if d.Checks, err = parseChecks(checks); err != nil {
						return err
					}
				}
				if d, err = s.SetRunDefaults(d); err != nil {
					return err
				}
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"defaults": d})
			}
			state := "off"
			if d.Review {
				state = "on"
			}
			fmt.Fprintf(cmd.OutOrStdout(), "model: %s\neffort: %s\nmcp servers: %s\nreview: %s\nreview effort: %s\n", cmp.Or(d.Model, "(Claude Code setting)"),
				cmp.Or(d.Effort, "(Claude Code setting)"), cmp.Or(strings.Join(d.MCPServers, ", "), "(none)"), state, cmp.Or(d.ReviewEffort, "(Claude Code setting)"))
			if len(d.Checks) == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "checks: (none)")
			}
			for _, c := range d.Checks {
				fmt.Fprintf(cmd.OutOrStdout(), "check: %s=%s\n", c.Name, c.Command)
			}
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&model, "model", "", "set the default model; empty clears it")
	f.StringVar(&effort, "effort", "", "set the default effort level ("+strings.Join(store.Efforts, ", ")+"); empty clears it")
	f.StringVar(&mcp, "mcp", "", "set the MCP servers that drafts, PR texts, and code reviews load, comma-separated, by name in the user scope of the Claude Code config (not claude.ai connectors); empty clears it")
	f.StringVar(&review, "review", "", "on or off: the code review before each push")
	f.StringArrayVar(&checks, "check", nil, "a default Done when check, as <name>=<command> (repeatable): the flags replace the checks")
	f.BoolVar(&noChecks, "no-checks", false, "clear the default checks")
	f.StringVar(&reviewEffort, "review-effort", "", "set the effort level of the code review ("+strings.Join(store.Efforts, ", ")+"); empty clears it")
	return c
}

func newRunMCPServersCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "mcp-servers",
		Short: "List the MCP servers that loam run defaults --mcp can select",
		Long: "List the MCP servers in the user scope of your Claude Code config (claude mcp add --scope user), by name. Each one has its scope, which is always user for now.\n" +
			"The list leaves out a server with a headersHelper, because --mcp rejects it, and a server whose name has a comma or edge spaces, because --mcp cannot keep the name. It has no .mcp.json server and no local-scope server, and no claude.ai connector, because --mcp cannot select them.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			servers, err := claudebin.MCPServers()
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"servers": servers})
			}
			out := cmd.OutOrStdout()
			if len(servers) == 0 {
				fmt.Fprintln(out, "No MCP servers in the user scope.")
			}
			for _, s := range servers {
				fmt.Fprintf(out, "%s (%s)\n", s.Name, s.Scope)
			}
			return nil
		},
	}
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

func newRunSandboxCmd() *cobra.Command {
	var read, write, hosts []string
	c := &cobra.Command{
		Use:   "sandbox [<plot>] [--read <path>]... [--write <path>]... [--host <host>]...",
		Short: "Show or set the paths and hosts that you add to the sandbox of a run",
		Long: "A run session works in a sandbox (see the Sandbox section of docs/contract.md). The stack presets give it the caches and hosts that builds need. This command adds more.\n" +
			"With a plot, the settings hold for the runs of that plot. With no plot, they hold for the runs of every plot, which suits a toolchain folder such as ~/.nvm.\n" +
			"--read and --write are paths, absolute or starting with ~/. A write path is also a read path. --host is a DNS name or *. and a name, such as *.example.com. " +
			"Repeat a flag to add more than one item. A flag sets the whole list of its kind, and an empty value empties it.\n" +
			"Loam refuses a path that opens your home folder: the home folder, a folder above it, the root, a credential folder such as ~/.ssh, or a folder that holds one. It refuses * as a host and a URL.\n" +
			"Only you can set these, with this command and the app. The MCP tools cannot, so a run session cannot widen its own sandbox. With no flag, this shows the settings. They are not in the change log.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			scope := ""
			if len(args) == 1 {
				p, err := resolvePlot(s, args[0])
				if err != nil {
					return err
				}
				scope = p.ID
			}
			f := cmd.Flags()
			var cur store.SandboxSettings
			if f.Changed("read") || f.Changed("write") || f.Changed("host") {
				// Only the lists of a flag change, in one transaction.
				var change store.SandboxChange
				if f.Changed("read") {
					change.Read = &read
				}
				if f.Changed("write") {
					change.Write = &write
				}
				if f.Changed("host") {
					change.Hosts = &hosts
				}
				if cur, err = s.UpdateSandboxSettings(scope, change); err != nil {
					return err
				}
			} else if cur, err = s.GetSandboxSettings(scope); err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"sandbox": cur})
			}
			list := func(items []string) string { return cmp.Or(strings.Join(items, ", "), "(none)") }
			fmt.Fprintf(cmd.OutOrStdout(), "read paths: %s\nwrite paths: %s\nhosts: %s\n", list(cur.Read), list(cur.Write), list(cur.Hosts))
			return nil
		},
	}
	f := c.Flags()
	f.StringArrayVar(&read, "read", nil, "set the paths that the sandbox can read; repeat the flag for more than one; empty empties the list")
	f.StringArrayVar(&write, "write", nil, "set the paths that the sandbox can write and read; repeat the flag for more than one; empty empties the list")
	f.StringArrayVar(&hosts, "host", nil, "set the hosts that the sandbox can reach, such as example.com or *.example.com; repeat the flag for more than one; empty empties the list")
	return c
}
