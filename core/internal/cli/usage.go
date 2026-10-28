package cli

import (
	"fmt"
	"io"
	"math"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newUsageCmd)
}

func newUsageCmd() *cobra.Command {
	var refresh bool
	c := &cobra.Command{
		Use:   "usage [--refresh]",
		Short: "Show the last usage that Claude Code reported: the 5-hour and the 7-day windows",
		Long: "Claude Code reports its usage to each claude -p call that Loam makes with stream-json output, such as a Shape draft. Loam keeps the last report.\n" +
			"--refresh asks now, with a small claude -p call that uses Haiku and no tools. loam run tick asks too when the usage hold needs it and the report is more than 30 minutes old.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			var u store.Usage
			if refresh {
				u, err = run.ProbeUsage(cmd.Context(), s)
			} else {
				u, err = s.GetUsage()
			}
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, map[string]any{"usage": u})
			}
			printUsage(cmd.OutOrStdout(), u)
			return nil
		},
	}
	c.Flags().BoolVar(&refresh, "refresh", false, "ask Claude Code for its usage now")
	return c
}

// printUsage prints the usage for a person.
func printUsage(out io.Writer, u store.Usage) {
	if u.ReadAt == nil {
		fmt.Fprintln(out, "Claude Code has not reported its usage yet. loam usage --refresh asks now")
		return
	}
	for _, w := range []struct {
		name string
		w    *store.UsageWindow
	}{{"5 hours", u.FiveHour}, {"This week", u.SevenDay}} {
		if w.w == nil {
			fmt.Fprintf(out, "%s: not reported\n", w.name)
			continue
		}
		fmt.Fprintf(out, "%s: %d%%, starts again %s\n", w.name, int(math.Round(w.w.Utilization*100)), w.w.ResetsAt.Format("Mon 2 Jan 15:04"))
	}
	fmt.Fprintf(out, "Read at %s\n", u.ReadAt.Local().Format(time.DateTime))
}
