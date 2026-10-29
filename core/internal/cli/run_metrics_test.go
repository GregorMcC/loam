package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-176: a run that lands counts in the metrics, and a run that you start
// with --fixes counts it as fixed.
func TestRunMetricsCountALandedRunAndItsFix(t *testing.T) {
	s, r, _ := readyRun(t)
	if _, code, out := runLand(t, r.ID); code != 0 {
		t.Fatalf("land: exit %d: %s", code, out)
	}
	metrics := func() run.Metrics {
		t.Helper()
		out, code := loam(t, "run", "metrics", "--plot", r.PlotID, "--json")
		if code != 0 {
			t.Fatalf("metrics: exit %d: %s", code, out)
		}
		var m run.Metrics
		if err := json.Unmarshal([]byte(out), &m); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		return m
	}
	m := metrics()
	if c := m.Current; c.Landed != 1 || c.FirstPass != 1 || c.Fixed != 0 || c.LeadTime.Count != 1 || c.Stations.Ship.Count != 1 {
		t.Fatalf("current %+v", c)
	}
	if d := m.Current.To.Sub(m.Current.From); d != run.MetricsWindow || !m.Previous.To.Equal(m.Current.From) {
		t.Fatalf("windows %+v %+v", m.Current, m.Previous)
	}

	out, code := loam(t, "run", "start", r.PlotID, "--title", "Fix the README", "--fixes", r.ID, "--json")
	if code != 0 {
		t.Fatalf("start: exit %d: %s", code, out)
	}
	var started struct {
		Run store.Run `json:"run"`
	}
	if err := json.Unmarshal([]byte(out), &started); err != nil || started.Run.Fixes != r.ID {
		t.Fatalf("%v: %s", err, out)
	}
	if c := metrics().Current; c.Fixed != 1 {
		t.Fatalf("fixed %d", c.Fixed)
	}
	// A fix of a run that has not landed, or of no run, is refused.
	if out, code := loam(t, "run", "start", r.PlotID, "--title", "Fix the fix", "--fixes", started.Run.ID, "--json"); code != 2 ||
		!strings.Contains(out, "a run fixes a landed run") {
		t.Fatalf("fix of a running run: exit %d: %s", code, out)
	}
	if out, code := loam(t, "run", "shape", r.PlotID, "--title", "Fix nothing", "--fixes", "runnothere", "--json"); code != 1 {
		t.Fatalf("a fix of no run: exit %d: %s", code, out)
	}
	if runs, _ := s.ListRuns(r.PlotID); len(runs) != 2 {
		t.Fatalf("a refused fix made a run: %d runs", len(runs))
	}
}

func TestRunMetricsPrintsTheStationsForAPerson(t *testing.T) {
	runCLI(t)
	out, code := loam(t, "run", "metrics")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	for _, want := range []string{"Landed: 0, 0 a week (before: 0)", "Lead time: none (before: none)", "Merge    0s", "Recovery: gate none. CI none."} {
		if !strings.Contains(out, want) {
			t.Fatalf("no %q in:\n%s", want, out)
		}
	}
	if _, code := loam(t, "run", "metrics", "--since", "yesterday", "--json"); code != 2 {
		t.Fatalf("a bad time: exit %d", code)
	}
	if out, code := loam(t, "run", "metrics", "--since", "2999-01-01T00:00:00Z", "--json"); code != 2 || !strings.Contains(out, "--since") {
		t.Fatalf("a start after now: exit %d: %s", code, out)
	}
	// A window under a week has no week rate.
	since := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	if out, code := loam(t, "run", "metrics", "--since", since); code != 0 || !strings.Contains(out, "Landed: 0 (before: 0)") {
		t.Fatalf("a short window: exit %d: %s", code, out)
	}
}

func TestMetricsTimesReadAsMinutes(t *testing.T) {
	for in, want := range map[int64]string{0: "0s", 54: "54s", 290: "5m", 7843: "2h11m", 3600: "1h"} {
		if got := seconds(in); got != want {
			t.Errorf("seconds(%d) = %q, want %q", in, got, want)
		}
	}
}
