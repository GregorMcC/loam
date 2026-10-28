package cli

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newRecurringCmd)
}

func newRecurringCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "recurring",
		Short: "Add, list, and remove runs that start on a timetable",
		Long: "A recurring run starts on a timetable, such as weekdays at 06:30, when its precheck finds work. loam tick starts it when it is due.\n" +
			"A Shape run has Claude draft a run for you to approve. A chore starts a run, which works to its gate and then waits for you to land it.\n" +
			"A run whose precheck finds no work is Skipped, and starts no session. The next run waits until the last one ends, so runs never stack.\n" +
			"Recurring runs are not in the change log, as runs are not.",
		Args: cobra.NoArgs,
	}
	c.AddCommand(newRecurringAddCmd(), newRecurringListCmd(), newRecurringRmCmd(), newRecurringRunCmd())
	return c
}

func newRecurringAddCmd() *cobra.Command {
	var r store.Recurring
	var kind, days, ifAsleep string
	var checks []string
	var approve bool
	c := &cobra.Command{
		Use:   "add <plot> --title <text> --prompt <text> --kind shape|chore --days <days> --at <HH:MM> [--precheck <command>] [--if-asleep once|skip] [--repo <repo>] [--check <name>=<command>]... [--max-tries <n>] [--model <model>] [--effort <level>] [--approve-setup]",
		Short: "Add a run that starts on a timetable",
		Long: "Add a recurring run to a plot. --days is daily, weekdays, weekends, or days such as mon,wed,fri. --at is the time on the clock of the Mac.\n" +
			"--precheck is a shell command that runs in the repo: the run starts only when it exits 0, and Claude gets what it prints.\n" +
			"--if-asleep says what happens to a time that the Mac slept through: once runs it once when the Mac wakes, and skip skips it.\n" +
			"A chore cannot ask to approve the setup command of the repo when it starts: --approve-setup approves it now.",
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
			r.PlotID, r.Kind, r.IfAsleep = p.ID, store.RecurringKind(kind), store.IfAsleep(ifAsleep)
			if r.Days, err = parseDays(days); err != nil {
				return err
			}
			if r.DoneWhen, err = parseChecks(checks); err != nil {
				return err
			}
			if approve {
				if err := run.ApproveRepoSetup(s, p.ID, r.Repo); err != nil {
					return err
				}
			}
			added, err := s.AddRecurring(r, time.Now())
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"recurring": added})
			}
			printRecurring(cmd.OutOrStdout(), added)
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&r.Title, "title", "", "the title of each run (required)")
	f.StringVar(&r.Prompt, "prompt", "", "what Claude does: the goal of a chore, or the brief of a Shape run (required)")
	f.StringVar(&kind, "kind", "", "shape: Claude drafts a run for you to approve. chore: a run starts and works to its gate (required)")
	f.StringVar(&days, "days", "", "daily, weekdays, weekends, or days such as mon,wed,fri (required)")
	f.StringVar(&r.At, "at", "", "the time of day, HH:MM, on the clock of the Mac (required)")
	f.StringVar(&r.Precheck, "precheck", "", "a shell command in the repo: the run starts only when it exits 0")
	f.StringVar(&ifAsleep, "if-asleep", string(store.AsleepRunOnce), "once: run once when the Mac wakes. skip: skip the time that the Mac slept through")
	f.StringVar(&r.Repo, "repo", "", "the repo of the runs (default: the main repo)")
	f.StringArrayVar(&checks, "check", nil, "a Done when check of a chore, as <name>=<command>")
	f.IntVar(&r.MaxTries, "max-tries", store.DefaultMaxTries, "how many times the checks can fail before a run stops")
	f.StringVar(&r.Model, "model", "", "the Claude model of the runs (default: the run defaults of the plot, then your Claude Code setting)")
	f.StringVar(&r.Effort, "effort", "", "the effort level of the runs: "+strings.Join(store.Efforts, ", ")+" (default: the run defaults of the plot, then your Claude Code setting)")
	f.BoolVar(&approve, "approve-setup", false, "approve the setup command of the repo now, for a chore")
	for _, name := range []string{"title", "prompt", "kind", "days", "at"} {
		c.MarkFlagRequired(name)
	}
	return c
}

// parseDays reads --days: daily, weekdays, weekends, or a list of days.
func parseDays(arg string) ([]string, error) {
	switch strings.ToLower(strings.TrimSpace(arg)) {
	case "daily":
		return []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}, nil
	case "weekdays":
		return []string{"mon", "tue", "wed", "thu", "fri"}, nil
	case "weekends":
		return []string{"sat", "sun"}, nil
	}
	var out []string
	for d := range strings.SplitSeq(arg, ",") {
		if d = strings.ToLower(strings.TrimSpace(d)); d != "" {
			out = append(out, d)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("--days needs daily, weekdays, weekends, or days such as mon,wed,fri: %w", store.ErrInvalid)
	}
	return out, nil
}

func newRecurringListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list [<plot>]",
		Short: "List the recurring runs of a plot, or of every plot",
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
			list, err := s.ListRecurring(plotID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"recurring": list})
			}
			for _, r := range list {
				printRecurring(cmd.OutOrStdout(), r)
			}
			return nil
		},
	}
}

func newRecurringRmCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "rm <recurring>",
		Short: "Remove a recurring run. Its runs stay",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			r, err := s.GetRecurring(args[0])
			if err != nil {
				return err
			}
			if err := s.RemoveRecurring(r.ID); err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"recurring": r})
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Removed %s: %s\n", r.ID, oneLine(r.Title))
			return nil
		},
	}
}

func newRecurringRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run <recurring>",
		Short: "Start a recurring run now, with its precheck. Its next time stays",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			loam, err := loamBinary()
			if err != nil {
				return err
			}
			res, err := run.RunRecurringNow(cmd.Context(), s, args[0], time.Now(), loam)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			printRecurringResult(cmd.OutOrStdout(), res)
			return nil
		},
	}
}

func printRecurring(out io.Writer, r store.Recurring) {
	fmt.Fprintf(out, "Recurring %s: %s (%s)\n", r.ID, oneLine(r.Title), r.Kind)
	fmt.Fprintf(out, "When: %s at %s. Next: %s\n", strings.Join(r.Days, ","), r.At, r.NextAt.Format("Mon 2 Jan 15:04"))
	if r.Precheck != "" {
		fmt.Fprintf(out, "Precheck: %s\n", oneLine(r.Precheck))
	}
	if r.LastAt != nil {
		fmt.Fprintf(out, "Last: %s. %s\n", r.LastAt.Format("Mon 2 Jan 15:04"), oneLine(r.LastNote))
	}
}

func printRecurringResult(out io.Writer, res run.RecurringResult) {
	fmt.Fprintf(out, "%s: %s\n", oneLine(res.Recurring.Title), oneLine(res.Note))
	if res.Run != nil {
		printRun(out, *res.Run)
	}
}
