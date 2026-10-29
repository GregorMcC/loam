package run

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// metricsStart is the start of the history that the metrics tests make.
var metricsStart = time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)

// history makes the events of one run. Each step is a kind, a detail, and
// the minutes after metricsStart. A try step has its stage as the detail.
type history struct {
	run    string
	events []store.RunEvent
}

func (h *history) add(kind, detail string, minute int) *history {
	e := store.RunEvent{ID: int64(len(h.events) + 1), RunID: h.run, At: metricsStart.Add(time.Duration(minute) * time.Minute), Kind: kind}
	if kind == "try" {
		e.Stage = detail
	} else {
		e.Detail = detail
	}
	h.events = append(h.events, e)
	return h
}

func (h *history) state(st store.RunState, minute int) *history {
	return h.add("state", string(st), minute)
}

// metricsFixture is 4 runs. Shaped lands after one gate try. Started has no
// draft, fails CI once, and lands. Fix fixes Shaped and lands. Gave up
// stops after its tries.
func metricsFixture() ([]store.Run, []store.RunEvent) {
	shaped := (&history{run: "shaped"}).
		state(store.RunShaping, 0).add("shape", "Drafted", 1).add("shape", "Drafted again", 3).
		state(store.RunStarting, 5).state(store.RunRunning, 6).
		add("try", store.TryGate, 20).
		state(store.RunShipping, 30).state(store.RunReady, 35).state(store.RunLanded, 95)
	started := (&history{run: "started"}).
		state(store.RunQueued, 100).state(store.RunStarting, 110).state(store.RunRunning, 111).
		state(store.RunShipping, 130).add("try", store.TryCI, 140).state(store.RunRunning, 140).
		add("try", store.TryGate, 150).
		state(store.RunShipping, 160).state(store.RunReady, 170).state(store.RunLanded, 180)
	fix := (&history{run: "fix"}).
		state(store.RunStarting, 200).state(store.RunRunning, 201).
		state(store.RunShipping, 210).state(store.RunReady, 214).state(store.RunLanded, 220)
	gaveUp := (&history{run: "gaveup"}).
		state(store.RunStarting, 300).state(store.RunRunning, 301).add("try", store.TryGate, 310).
		state(store.RunStopped, 320)
	runs := []store.Run{
		{ID: "shaped", State: store.RunLanded, Turns: 3, ReviewTries: 1, CodeReview: &store.RunCodeReview{Rounds: 2}},
		{ID: "started", State: store.RunLanded, Turns: 4},
		{ID: "fix", State: store.RunLanded, Turns: 1, Fixes: "shaped"},
		{ID: "gaveup", State: store.RunStopped, Turns: 2},
	}
	var events []store.RunEvent
	for _, h := range []*history{shaped, started, fix, gaveUp} {
		events = append(events, h.events...)
	}
	return runs, events
}

func minutes(n int) int64 { return int64(n * 60) }

func spread(count, median, p90 int) Spread {
	return Spread{Count: count, MedianSeconds: minutes(median), P90Seconds: minutes(p90)}
}

func TestMetricsSplitTheLeadTimeOfEachLandedRunByStation(t *testing.T) {
	runs, events := metricsFixture()
	m := ComputeMetrics(runs, events, metricsStart, metricsStart.Add(24*time.Hour))
	c := m.Current
	// Lead times are 90 (shaped: approve at 5, land at 95), 80 (started:
	// queued at 100), and 20 (fix).
	if c.Landed != 3 || c.LeadTime != spread(3, 80, 90) {
		t.Fatalf("landed %d, lead time %+v", c.Landed, c.LeadTime)
	}
	want := Stations{
		Approve: spread(1, 5, 5),   // only shaped has a draft
		Queue:   spread(3, 0, 10),  // started waited 10
		Build:   spread(3, 25, 40), // shaped 25, started 20 + 20, fix 10
		Ship:    spread(3, 5, 20),  // shaped 5, started 10 + 10, fix 4
		Merge:   spread(3, 10, 60), // shaped 60, started 10, fix 6
		Stopped: spread(3, 0, 0),
	}
	if c.Stations != want {
		t.Fatalf("stations %+v\nwant %+v", c.Stations, want)
	}
}

func TestMetricsCountFirstPassFixesReworkAndRunsThatDidNotLand(t *testing.T) {
	runs, events := metricsFixture()
	c := ComputeMetrics(runs, events, metricsStart, metricsStart.Add(24*time.Hour)).Current
	// Only fix landed with no try and no review try. Shaped is fixed later.
	if c.FirstPass != 1 || c.Fixed != 1 {
		t.Fatalf("first pass %d, fixed %d", c.FirstPass, c.Fixed)
	}
	// The rework is that of the landed runs. Gave up is not one.
	want := Rework{GateTries: 2, CITries: 1, ReviewTries: 1, CodeReviewRounds: 2, Redrafts: 1, Turns: 8}
	if c.Rework != want {
		t.Fatalf("rework %+v, want %+v", c.Rework, want)
	}
	if c.NotLanded != (NotLanded{Stopped: 1}) {
		t.Fatalf("not landed %+v", c.NotLanded)
	}
}

func TestMetricsTimeTheRecoveryFromEachFailureToTheNextPass(t *testing.T) {
	runs, events := metricsFixture()
	c := ComputeMetrics(runs, events, metricsStart, metricsStart.Add(24*time.Hour)).Current
	// Gate: shaped failed at 20 and shipped at 30. Gave up never passed, so
	// it has no recovery. CI: started failed at 140, failed the gate on the
	// way, and was Ready at 170. The gate try at 150 is part of that CI
	// failure.
	want := Recovery{Gate: spread(1, 10, 10), CI: spread(1, 30, 30)}
	if c.Recovery != want {
		t.Fatalf("recovery %+v, want %+v", c.Recovery, want)
	}
}

func TestMetricsCountARunInTheWindowThatItLandedIn(t *testing.T) {
	runs, events := metricsFixture()
	// The window from minute 150 holds the lands of started and fix, the
	// stop of gave up, and no recovery that starts in it.
	from := metricsStart.Add(150 * time.Minute)
	m := ComputeMetrics(runs, events, from, from.Add(4*time.Hour))
	if m.Current.Landed != 2 || m.Current.NotLanded.Stopped != 1 || m.Current.Recovery.CI.Count != 0 || m.Current.Recovery.Gate.Count != 0 {
		t.Fatalf("current %+v", m.Current)
	}
	// The window before has the same length and holds the land of shaped
	// and the CI failure of started.
	p := m.Previous
	if !p.From.Equal(from.Add(-4*time.Hour)) || !p.To.Equal(from) || p.Landed != 1 || p.Recovery.CI.Count != 1 || p.Recovery.Gate.Count != 1 {
		t.Fatalf("previous %+v", p)
	}
}

func TestMetricsOfNoRunsAreZeroWithEmptyCounts(t *testing.T) {
	m := ComputeMetrics(nil, nil, metricsStart, metricsStart.Add(time.Hour))
	if !reflect.DeepEqual(m.Current, MetricsPeriod{From: metricsStart, To: metricsStart.Add(time.Hour)}) {
		t.Fatalf("%+v", m.Current)
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"lead_time":{"count":0,"median_seconds":0,"p90_seconds":0}`, `"not_landed":{"stopped":0,`, `"merge":`} {
		if !strings.Contains(string(b), key) {
			t.Fatalf("json has no %s: %s", key, b)
		}
	}
}

// A failure that stops the run has no recovery, even when the run passes
// after you start it again: the Stopped station holds that wait.
func TestMetricsGiveNoRecoveryToAFailureThatStoppedTheRun(t *testing.T) {
	h := (&history{run: "stopped"}).
		state(store.RunStarting, 0).state(store.RunRunning, 1).add("try", store.TryGate, 10).
		state(store.RunStopped, 10).state(store.RunRunning, 600).state(store.RunShipping, 610).
		state(store.RunReady, 615).state(store.RunLanded, 620)
	runs := []store.Run{{ID: "stopped", State: store.RunLanded}}
	c := ComputeMetrics(runs, h.events, metricsStart, metricsStart.Add(24*time.Hour)).Current
	if c.Recovery.Gate.Count != 0 || c.Stations.Stopped != spread(1, 590, 590) || c.Rework.GateTries != 1 {
		t.Fatalf("recovery %+v, stopped %+v, rework %+v", c.Recovery, c.Stations.Stopped, c.Rework)
	}
}

// A fix that you cancelled does not count its run as failed.
func TestMetricsLeaveOutACancelledFix(t *testing.T) {
	runs, events := metricsFixture()
	runs[2].State = store.RunCancelled
	if c := ComputeMetrics(runs, events, metricsStart, metricsStart.Add(24*time.Hour)).Current; c.Fixed != 0 {
		t.Fatalf("fixed %d", c.Fixed)
	}
}

func TestNearestRank(t *testing.T) {
	ds := func(ns ...int) []time.Duration {
		out := []time.Duration{}
		for _, n := range ns {
			out = append(out, time.Duration(n)*time.Second)
		}
		return out
	}
	for _, c := range []struct {
		in       []time.Duration
		med, p90 int64
	}{
		{ds(), 0, 0},
		{ds(7), 7, 7},
		{ds(4, 1, 3, 2), 2, 4},
		{ds(50, 10, 40, 20, 30), 30, 50},
		{ds(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11), 6, 10},
	} {
		got := spreadOf(c.in)
		if got.Count != len(c.in) || got.MedianSeconds != c.med || got.P90Seconds != c.p90 {
			t.Fatalf("%v: %+v", c.in, got)
		}
	}
}
