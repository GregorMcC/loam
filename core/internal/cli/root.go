// Package cli holds the cobra commands of the loam binary.
//
// Each command lives in its own file and registers itself in init with
// [Register]. That keeps root.go free of merge conflicts between tickets.
package cli

import (
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"slices"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

// ContractVersion is the version of the --json output and the exit codes. It
// goes up only when a change makes the output unreadable for the app. Adding
// a field does not count. See docs/contract.md.
const ContractVersion = 1

// Version is the program version. The build sets it with
// -ldflags "-X github.com/GregorMcC/loam/core/internal/cli.Version=...".
// Without it, the version comes from the Go build info.
var Version = ""

func version() string {
	if Version != "" {
		return Version
	}
	if bi, ok := debug.ReadBuildInfo(); ok && bi.Main.Version != "" && bi.Main.Version != "(devel)" {
		return bi.Main.Version
	}
	return "dev"
}

var registry []func() *cobra.Command

// Register adds a command to the root command. Call it from init in the file
// of the command. The function runs each time [NewRootCmd] builds a root, so
// a command gets fresh flag state per root.
func Register(f func() *cobra.Command) { registry = append(registry, f) }

// JSON reports whether the global --json flag is set.
func JSON(cmd *cobra.Command) bool {
	v, _ := cmd.Flags().GetBool("json")
	return v
}

// NewRootCmd builds the loam root command with the global --json flag and
// every registered command.
func NewRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "loam",
		Short:         "Give each area of work a home that every Claude Code session can see",
		Version:       version(),
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE:          func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	root.SetVersionTemplate("loam version {{.Version}}\n")
	root.PersistentFlags().Bool("json", false, "print machine-readable JSON")
	root.PersistentFlags().String("actor", "", "who makes the write: app records you in the app (default: you in the CLI)")
	root.PersistentPreRunE = func(cmd *cobra.Command, _ []string) error {
		if v, _ := cmd.Flags().GetString("actor"); v != "" && v != string(store.ActorApp) {
			return fmt.Errorf("--actor %q: the only value is app: %w", v, store.ErrInvalid)
		}
		return nil
	}
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usageError{err} })
	for _, f := range registry {
		root.AddCommand(f())
	}
	markUsageErrors(root)
	return root
}

// markUsageErrors makes argument errors, such as a wrong count or an unknown
// command, exit with the invalid code.
func markUsageErrors(c *cobra.Command) {
	if orig := c.Args; orig != nil {
		c.Args = func(cmd *cobra.Command, args []string) error {
			if err := orig(cmd, args); err != nil {
				return usageError{err}
			}
			return nil
		}
	}
	for _, sub := range c.Commands() {
		markUsageErrors(sub)
	}
}

// Execute runs the loam command line and returns the exit code.
func Execute() int {
	return execute(NewRootCmd(), os.Args[1:], os.Stdout, os.Stderr)
}

// execute runs root with args. With --json, an error prints as JSON on out
// (see [ErrorBody]). Otherwise it prints one line on errOut.
func execute(root *cobra.Command, args []string, out, errOut io.Writer) int {
	root.SetArgs(args)
	err := root.Execute()
	if err == nil {
		return ExitOK
	}
	// A bad flag fails before cobra parses --json, so look at the args too.
	v, _ := root.PersistentFlags().GetBool("json")
	asJSON := v || slices.Contains(args, "--json")
	return writeError(out, errOut, err, asJSON)
}
