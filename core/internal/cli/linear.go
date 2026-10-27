package cli

import (
	"bufio"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
)

func init() {
	Register(newLinearCmd)
}

func newLinearCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "linear",
		Short: "Connect Loam to Linear with a personal API key",
		Long: "Loam keeps a personal Linear API key in the macOS Keychain. With a key, the intake of a plot lists the open issues of its Linear team and project links,\n" +
			"and a run that starts from a Linear issue moves the issue to In Progress.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	key := &cobra.Command{
		Use:   "key",
		Short: "Set or remove the Linear API key",
		Args:  cobra.NoArgs,
		RunE:  func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	key.AddCommand(&cobra.Command{
		Use:   "set",
		Short: "Read a personal API key on stdin, check it with Linear, and store it in the Keychain",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			line, _ := bufio.NewReader(cmd.InOrStdin()).ReadString('\n')
			k := strings.TrimSpace(line)
			if k == "" {
				return fmt.Errorf("give the key on stdin: %w", store.ErrInvalid)
			}
			st, err := linear.SetKey(cmd.Context(), k)
			if err != nil {
				return err
			}
			return printLinearStatus(cmd, st)
		},
	}, &cobra.Command{
		Use:   "rm",
		Short: "Remove the Linear API key from the Keychain",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := linear.RemoveKey(); err != nil {
				return err
			}
			return printLinearStatus(cmd, linear.Status{})
		},
	})
	c.AddCommand(key, &cobra.Command{
		Use:   "status",
		Short: "Say whether Loam has a Linear API key, and check it",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := linear.ReadStatus(cmd.Context())
			if err != nil {
				return err
			}
			return printLinearStatus(cmd, st)
		},
	})
	return c
}

func printLinearStatus(cmd *cobra.Command, st linear.Status) error {
	if JSON(cmd) {
		return printJSON(cmd, st)
	}
	out := cmd.OutOrStdout()
	switch {
	case !st.Connected:
		fmt.Fprintln(out, "No Linear API key.")
	case st.Viewer != nil:
		fmt.Fprintf(out, "Connected to %s as %s.\n", st.Viewer.Organization, st.Viewer.Name)
	default:
		fmt.Fprintf(out, "A key is stored, but Linear did not answer: %s\n", st.Error)
	}
	return nil
}
