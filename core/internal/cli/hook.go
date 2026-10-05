package cli

import (
	"os"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command {
		return &cobra.Command{
			Use:    "hook",
			Short:  "Answer a Claude Code hook (used by seeded sessions)",
			Hidden: true,
			Args:   cobra.ArbitraryArgs,
			// The hook never fails and never blocks the session.
			Run: func(cmd *cobra.Command, _ []string) {
				session.RunHook(cmd.InOrStdin(), cmd.OutOrStdout(), os.Getenv)
			},
		}
	})
}
