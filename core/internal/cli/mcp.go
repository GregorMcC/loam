package cli

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/GregorMcC/loam/core/internal/mcpserver"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command {
		return &cobra.Command{
			Use:   "mcp",
			Short: "Run the Loam MCP server on stdin and stdout",
			Long: "Run the stdio MCP server. Claude Code starts this command. `loam setup` registers it.\n" +
				"The server writes only protocol messages to stdout. Logs go to stderr.",
			Args: cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				log.SetOutput(os.Stderr)
				s, err := openStore()
				if err != nil {
					return err
				}
				defer s.Close()
				parent := cmd.Context()
				if parent == nil {
					parent = context.Background()
				}
				ctx, stop := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
				defer stop()
				return mcpserver.Run(ctx, mcpserver.Options{Store: s, Version: version()})
			},
		}
	})
}
