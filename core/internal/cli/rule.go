package cli

import (
	"fmt"
	"io"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newRuleCmd)
}

func newRuleCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "rule",
		Short: "Add, list, and remove the rules of a plot",
		Long: "A rule is a check that every run of a plot must pass, such as \"Views use the colour tokens\". The gate runs the rules after the checks of the run.\n" +
			"When you send back a note like a note that you sent back on another run of the plot, Loam offers to make it a rule.\n" +
			"Loam keeps the rules outside the worktree, so a run cannot change them. Rules are not in the change log, as runs are not.",
		Args: cobra.NoArgs,
	}
	c.AddCommand(newRuleAddCmd(), newRuleListCmd(), newRuleRmCmd())
	return c
}

func newRuleAddCmd() *cobra.Command {
	var r store.Rule
	c := &cobra.Command{
		Use:   "add <plot> --name <name> --command <command> [--note <text>]",
		Short: "Add a rule: a check that every run of the plot must pass",
		Long: "Add a rule to a plot. --command is a shell command that runs in the folder of each run, and it passes when it exits 0.\n" +
			"--note is the note that the rule came from. Loam offers no rule for a note like it again.",
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
			r.PlotID = p.ID
			added, err := s.AddRule(r)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"rule": added})
			}
			printRule(cmd.OutOrStdout(), added)
			return nil
		},
	}
	f := c.Flags()
	f.StringVar(&r.Name, "name", "", "the name of the rule (required)")
	f.StringVar(&r.Command, "command", "", "the check: a shell command that exits 0 when the rule holds (required)")
	f.StringVar(&r.Note, "note", "", "the note that the rule came from")
	return c
}

func newRuleListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list [<plot>]",
		Short: "List the rules of a plot, or of every plot",
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
			list, err := s.ListRules(plotID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"rules": list})
			}
			for _, r := range list {
				printRule(cmd.OutOrStdout(), r)
			}
			return nil
		},
	}
}

func newRuleRmCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "rm <rule>",
		Short: "Remove a rule. The gate stops running it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			r, err := s.GetRule(args[0])
			if err != nil {
				return err
			}
			if err := s.RemoveRule(r.ID); err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"rule": r})
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Removed %s: %s\n", r.ID, oneLine(r.Name))
			return nil
		},
	}
}

func printRule(w io.Writer, r store.Rule) {
	fmt.Fprintf(w, "Rule %s: %s\n", r.ID, oneLine(r.Name))
	fmt.Fprintf(w, "Check: %s\n", oneLine(r.Command))
	if r.Note != "" {
		fmt.Fprintf(w, "From the note: %s\n", oneLine(r.Note))
	}
}
