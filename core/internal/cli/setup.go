package cli

import (
	"fmt"

	"github.com/GregorMcC/loam/core/internal/setup"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command {
		var yes, check bool
		c := &cobra.Command{
			Use:   "setup",
			Short: "Register the Loam MCP server and trust the plots folder",
			Long: "Check each setup step and ask before you do it. The command is safe to run again.\n" +
				"It registers the MCP server at user scope, starts claude in the plots folder so you accept trust once,\n" +
				"and prints the allow rules for the read tools. It edits no settings file.",
			Args: cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				exe, err := loamBinary()
				if err != nil {
					return err
				}
				if check {
					r, err := setup.Check(exe)
					if err != nil {
						return err
					}
					if JSON(cmd) {
						return printJSON(cmd, r)
					}
					for _, st := range r.Steps {
						state := "done"
						if !st.Done {
							state = "not done"
						}
						fmt.Fprintf(cmd.OutOrStdout(), "%s: %s", st.ID, state)
						if st.Detail != "" {
							fmt.Fprintf(cmd.OutOrStdout(), " (%s)", st.Detail)
						}
						fmt.Fprintln(cmd.OutOrStdout())
					}
					return nil
				}
				return setup.Run(setup.Options{
					Binary: exe,
					Yes:    yes,
					In:     cmd.InOrStdin(),
					Out:    cmd.OutOrStdout(),
				})
			},
		}
		c.Flags().BoolVarP(&yes, "yes", "y", false, "answer yes to every question")
		c.Flags().BoolVar(&check, "check", false, "report each step as done or not done, and change nothing")
		return c
	})
	Register(func() *cobra.Command {
		return &cobra.Command{
			Use:   "version",
			Short: "Print the loam version and the contract version",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				if JSON(cmd) {
					return printJSON(cmd, struct {
						Version         string `json:"version"`
						ContractVersion int    `json:"contract_version"`
					}{version(), ContractVersion})
				}
				fmt.Fprintf(cmd.OutOrStdout(), "loam version %s\n", version())
				return nil
			},
		}
	})
}
