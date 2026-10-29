package cli

import (
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
)

func newRunMetricsCmd() *cobra.Command {
	var since, plot string
	c := &cobra.Command{
		Use:   "metrics [--plot <plot>] [--since <time>]",
		Short: "Show where the time of the runs goes, from approve to landed",
		Long: "Shows the run metrics of the last 30 days, or from --since to now, and of the window before it, of the same length, for a trend. " +
			"--since takes an RFC 3339 time.\n" +
			"A landed run counts in the window that it landed in. The lead time runs from approve to landed, and splits into the stations " +
			"Queue, Build, Ship, Merge, and Stopped. Fixed counts the landed runs that a later run started with --fixes fixes. All times are wall time.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			to := time.Now().UTC()
			from := to.Add(-run.MetricsWindow)
			if since != "" {
				t, err := time.Parse(time.RFC3339, since)
				if err != nil {
					return fmt.Errorf("--since %q is not an RFC 3339 time: %w", since, store.ErrInvalid)
				}
				from = t.UTC()
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			plotID := ""
			if plot != "" {
				p, err := resolvePlot(s, plot)
				if err != nil {
					return err
				}
				plotID = p.ID
			}
			m, err := run.Measure(s, plotID, from, to)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, m)
			}
			printMetrics(cmd.OutOrStdout(), m)
			return nil
		},
	}
	c.Flags().StringVar(&since, "since", "", "start the window at this RFC 3339 time (default: 30 days ago)")
	c.Flags().StringVar(&plot, "plot", "", "show only the runs of this plot")
	return c
}

// printMetrics prints the metrics of the window, with the window before it
// in brackets.
func printMetrics(out io.Writer, m run.Metrics) {
	c, p := m.Current, m.Previous
	days := c.To.Sub(c.From).Hours() / 24
	fmt.Fprintf(out, "Runs from %s to %s (%s days)\n", c.From.Format(time.DateOnly), c.To.Format(time.DateOnly), trimFloat(days))
	fmt.Fprintf(out, "Landed: %d, %s a week (before: %d)\n", c.Landed, trimFloat(float64(c.Landed)/days*7), p.Landed)
	fmt.Fprintf(out, "Lead time: %s (before: %s)\n", spreadText(c.LeadTime), spreadText(p.LeadTime))
	fmt.Fprintf(out, "First pass: %d of %d. Fixed later: %d of %d.\n", c.FirstPass, c.Landed, c.Fixed, c.Landed)
	fmt.Fprintln(out)
	w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "Station\tMedian\t90th\tRuns")
	for _, st := range []struct {
		name string
		s    run.Spread
	}{
		{"Approve", c.Stations.Approve}, {"Queue", c.Stations.Queue}, {"Build", c.Stations.Build},
		{"Ship", c.Stations.Ship}, {"Merge", c.Stations.Merge}, {"Stopped", c.Stations.Stopped},
	} {
		fmt.Fprintf(w, "%s\t%s\t%s\t%d\n", st.name, seconds(st.s.MedianSeconds), seconds(st.s.P90Seconds), st.s.Count)
	}
	w.Flush()
	fmt.Fprintln(out)
	fmt.Fprintf(out, "Recovery: gate %s. CI %s.\n", spreadText(c.Recovery.Gate), spreadText(c.Recovery.CI))
	r := c.Rework
	fmt.Fprintf(out, "Rework: gate tries %d, CI tries %d, review tries %d, code review rounds %d, redrafts %d, turns %d\n",
		r.GateTries, r.CITries, r.ReviewTries, r.CodeReviewRounds, r.Redrafts, r.Turns)
	n := c.NotLanded
	fmt.Fprintf(out, "Not landed: stopped %d, limited %d, cancelled %d, start unknown %d\n", n.Stopped, n.Limited, n.Cancelled, n.StartUnknown)
}

// spreadText is a spread for a person, such as "median 4m, 90th 12m (5)".
func spreadText(s run.Spread) string {
	if s.Count == 0 {
		return "none"
	}
	return fmt.Sprintf("median %s, 90th %s (%d)", seconds(s.MedianSeconds), seconds(s.P90Seconds), s.Count)
}

// seconds is a time for a person: whole minutes from 1 minute, such as
// "2h15m" or "1h", else seconds.
func seconds(n int64) string {
	d := time.Duration(n) * time.Second
	if d < time.Minute {
		return d.String()
	}
	text := strings.TrimSuffix(d.Round(time.Minute).String(), "0s")
	if strings.HasSuffix(text, "h0m") {
		text = strings.TrimSuffix(text, "0m")
	}
	return text
}

// trimFloat is a number with at most one decimal, such as "1.2" or "30".
func trimFloat(f float64) string {
	return strings.TrimSuffix(fmt.Sprintf("%.1f", f), ".0")
}
