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
			"and a run that starts from a Linear issue moves the issue to In Progress. loam linear updates turns each update that Loam makes to Linear on or off.",
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
	c.AddCommand(key, newLinearUpdatesCmd(), &cobra.Command{
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

// linearSwitches are the flags of loam linear updates, each with the switch
// that it sets and its words in the text output.
var linearSwitches = []struct {
	flag, words string
	field       func(*store.LinearUpdates) *bool
}{
	{"in-progress", "When a run starts, move the issue to In Progress", func(u *store.LinearUpdates) *bool { return &u.InProgress }},
	{"attach-pr", "When the PR opens, attach it to the issue", func(u *store.LinearUpdates) *bool { return &u.AttachPR }},
	{"done", "When you land a run, move the issue to Done", func(u *store.LinearUpdates) *bool { return &u.Done }},
	{"walkthrough", "When you land a run, add its walkthrough as a comment", func(u *store.LinearUpdates) *bool { return &u.WalkthroughComment }},
}

func newLinearUpdatesCmd() *cobra.Command {
	values := make([]string, len(linearSwitches))
	c := &cobra.Command{
		Use:   "updates [--in-progress on|off] [--attach-pr on|off] [--done on|off] [--walkthrough on|off]",
		Short: "Show or set which updates Loam makes to Linear",
		Long: "Each switch turns one update that Loam makes to the Linear issue of a run on or off. They hold for every plot, and they are not in the change log.\n" +
			"With no flag, this shows the switches. A flag sets that switch and leaves the others.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			u, err := s.GetLinearUpdates()
			if err != nil {
				return err
			}
			changed := false
			for i, sw := range linearSwitches {
				if !cmd.Flags().Changed(sw.flag) {
					continue
				}
				switch values[i] {
				case "on":
					*sw.field(&u) = true
				case "off":
					*sw.field(&u) = false
				default:
					return fmt.Errorf("--%s takes on or off, not %q: %w", sw.flag, values[i], store.ErrInvalid)
				}
				changed = true
			}
			if changed {
				if u, err = s.SetLinearUpdates(u); err != nil {
					return err
				}
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Updates store.LinearUpdates `json:"updates"`
				}{u})
			}
			for _, sw := range linearSwitches {
				state := "off"
				if *sw.field(&u) {
					state = "on"
				}
				fmt.Fprintf(cmd.OutOrStdout(), "%s: %s\n", sw.words, state)
			}
			return nil
		},
	}
	for i, sw := range linearSwitches {
		c.Flags().StringVar(&values[i], sw.flag, "", "on or off: "+strings.ToLower(sw.words[:1])+sw.words[1:])
	}
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
