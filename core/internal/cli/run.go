package cli

import (
	"fmt"
	"io"
	"strings"

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
			"A run stops when it is ready to land (Ready), when it uses all its tries (Stopped), or when you stop it.\n" +
			"Runs are not in the change log.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newRunStartCmd(), newRunListCmd(), newRunStatusCmd(), newRunStopCmd(), newRunTickCmd(), newRunHookCmd())
	return c
}

func newRunStartCmd() *cobra.Command {
	var o run.StartOptions
	var checks []string
	c := &cobra.Command{
		Use:   "start <plot> --title <text> [--goal <text>] [--check <name>=<command>]... [--worktree <name>] [--repo <repo>] [--base <branch>] [--link <link-id or URL> | --ticket <file>] [--max-tries <n>] [--model <model>] [--approve-setup]",
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
	f.StringVar(&o.Repo, "repo", "", "the repo of a new worktree (default: the main repo)")
	f.StringVar(&o.Base, "base", "", "start a new worktree's branch from this branch, not from the default branch of origin")
	f.StringVar(&o.Link, "link", "", "the link that the work starts from: a link ID of the plot, or the URL of an issue")
	f.StringVar(&o.Ticket, "ticket", "", "the ticket of a wayfinder map that the work starts from: the path of its file, as loam intake list gives it")
	f.IntVar(&o.MaxTries, "max-tries", store.DefaultMaxTries, "how many times the checks can fail before the run stops")
	f.StringVar(&o.Model, "model", "", "the Claude model of the session (default: your Claude Code setting)")
	f.BoolVar(&o.ApproveSetup, "approve-setup", false, "approve the setup command of the repo when it is new or changed")
	c.MarkFlagRequired("title")
	return c
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
				fmt.Fprintf(out, "%s  %-13s %d/%d  %s\n", r.ID, r.State, r.Tries, r.MaxTries, oneLine(r.Title))
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

func newRunTickCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "tick",
		Short: "Ship the runs whose checks passed: push, open the PR, and read CI",
		Long: "Move on each run in Shipping. Loam pushes the branch of the run and opens its PR. When CI passes on the PR, the run is Ready.\n" +
			"When CI fails, Loam sends the end of each failed log back to the session, and the failure counts a try. On the last try, the run stops.\n" +
			"A tick that waits on GitHub changes nothing, so it is safe to run often. The app runs it while a run ships.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			res, err := run.Tick(cmd.Context(), s)
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
	fmt.Fprintf(out, "State: %s, try %d of %d\n", r.State, r.Tries, r.MaxTries)
	fmt.Fprintf(out, "Folder: %s\n", r.Folder)
	if n := oneLine(r.Note); n != "" {
		fmt.Fprintf(out, "Note: %s\n", n)
	}
}

// exitCode is an error that ends loam with its code and prints nothing. A
// hook uses it to block Claude Code with exit code 2.
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit code %d", int(e)) }
