package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/GregorMcC/loam/core/internal/intake"
)

func init() {
	Register(newIntakeCmd)
}

func newIntakeCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "intake",
		Short: "List the work that a plot can start runs from",
		Long: "The intake of a plot is the open issues of its GitHub repos (through gh) and the open tickets of the wayfinder maps in its links.\n" +
			"A map is a local link to a file called map.md, with one file for each ticket in the issues folder next to it.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newIntakeListCmd())
	return c
}

func newIntakeListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list <plot>",
		Short: "List the open issues and tickets of a plot, and the run that started from each",
		Args:  cobra.ExactArgs(1),
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
			res, err := intake.List(cmd.Context(), s, p.ID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			out := cmd.OutOrStdout()
			for _, src := range res.Sources {
				if src.Error != "" {
					fmt.Fprintf(cmd.ErrOrStderr(), "%s: %s\n", src.Label, src.Error)
				}
			}
			if len(res.Items) == 0 {
				fmt.Fprintln(out, "No open issues or tickets.")
			}
			for _, i := range res.Items {
				run := ""
				if i.RunID != "" {
					run = "  run " + i.RunID
				}
				fmt.Fprintf(out, "%-10s %-16s %s%s\n", i.Key, i.Status, oneLine(i.Title), run)
			}
			return nil
		},
	}
}
