package cli

import (
	"fmt"
	"strconv"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newMoveCmd)
	Register(newExportCmd)
}

func newMoveCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "move <plot> <position>",
		Short: "Move a plot to a position in the plot order (1 is the first)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			pos, err := strconv.Atoi(args[1])
			if err != nil {
				return fmt.Errorf("position %q is not a number: %w", args[1], store.ErrInvalid)
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
			if err := s.MovePlot(p.ID, pos); err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Plot     string `json:"plot"`
					Position int    `json:"position"`
				}{p.ID, pos})
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s is now plot %d\n", p.Name, pos)
			return nil
		},
	}
}

func newExportCmd() *cobra.Command {
	var changes bool
	c := &cobra.Command{
		Use:   "export",
		Short: "Write the plots, and with --changes the change log, as JSON",
		Long: "Write every plot in the plot order as JSON on stdout. With --changes, also write the change log, oldest first.\n" +
			"The output is always JSON.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			summaries, err := s.ListPlots()
			if err != nil {
				return err
			}
			out := struct {
				Plots   []plotOut            `json:"plots"`
				Changes []store.ChangeRecord `json:"changes,omitempty"`
			}{Plots: []plotOut{}}
			vaults := linkkind.Vaults()
			for _, sm := range summaries {
				p, err := s.GetPlot(sm.ID)
				if err != nil {
					return err
				}
				out.Plots = append(out.Plots, newPlotOut(p, vaults))
			}
			if !changes {
				return printJSON(cmd, out)
			}
			recs, err := s.ListChanges(store.ChangeQuery{})
			if err != nil {
				return err
			}
			return printJSON(cmd, struct {
				Plots   []plotOut            `json:"plots"`
				Changes []store.ChangeRecord `json:"changes"`
			}{out.Plots, recs})
		},
	}
	c.Flags().BoolVar(&changes, "changes", false, "also write the change log")
	return c
}
