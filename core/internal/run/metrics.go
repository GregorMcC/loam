package run

import (
	"fmt"
	"math"
	"slices"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// MetricsWindow is the window of the run metrics when you give no start.
const MetricsWindow = 30 * 24 * time.Hour

// Metrics are the run metrics of one window of time (TAS-176), and of the
// window before it, of the same length, for a trend. They follow the DORA
// keys: the lead time, the lands, the change failures, and the recovery
// time. All times are wall time.
type Metrics struct {
	Current  MetricsPeriod `json:"current"`
	Previous MetricsPeriod `json:"previous"`
}

// MetricsPeriod is the metrics of the runs in one window, from From up to
// To. A landed run counts in the window that it landed in.
type MetricsPeriod struct {
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
	// Landed counts the runs that landed in the window.
	Landed int `json:"landed"`
	// FirstPass counts the landed runs that used no try and no review try.
	FirstPass int `json:"first_pass"`
	// Fixed counts the landed runs that a later run fixes, unless you
	// cancelled the fix: the change failures.
	Fixed int `json:"fixed"`
	// LeadTime is the time of each landed run from approve to landed. A run
	// with no draft starts when Loam records it.
	LeadTime Spread   `json:"lead_time"`
	Stations Stations `json:"stations"`
	Recovery Recovery `json:"recovery"`
	Rework   Rework   `json:"rework"`
	// NotLanded counts the runs whose last state is in the window and is
	// Stopped, Limited, Cancelled, or Start unknown.
	NotLanded NotLanded `json:"not_landed"`
}

// Spread is the median and the 90th percentile of some times, in seconds,
// by the nearest rank. Both are 0 when Count is 0.
type Spread struct {
	Count         int   `json:"count"`
	MedianSeconds int64 `json:"median_seconds"`
	P90Seconds    int64 `json:"p90_seconds"`
}

// Stations is the time that the landed runs spent at each station. Each
// spread holds every landed run, with 0 for a station that a run did not
// pass, except Approve: it holds only the runs that had a draft. The
// stations other than Approve add up to the lead time of a run.
type Stations struct {
	// Approve is the time in Shaping: the draft, and your approve.
	Approve Spread `json:"approve"`
	// Queue is the time in Queued, for a slot or for the usage.
	Queue Spread `json:"queue"`
	// Build is the time in Starting and Running: the session and its gate.
	Build Spread `json:"build"`
	// Ship is the time in Shipping: the code review, the push, and CI.
	Ship Spread `json:"ship"`
	// Merge is the time in Ready, until you land the run.
	Merge Spread `json:"merge"`
	// Stopped is the time in Stopped, Limited, and Start unknown, before you
	// started the run again.
	Stopped Spread `json:"stopped"`
}

// Recovery is the time from a failure to the next pass. Gate is from a
// failed gate until the run ships, or is Ready. CI is from a failed CI until
// the run is Ready again. A gate that fails while the run fixes a CI failure
// is part of that CI failure. A failure counts in the window that it
// started in. A failure that never passed does not count, and nor does one
// that stopped the run, because the Stopped station holds that wait.
type Recovery struct {
	Gate Spread `json:"gate"`
	CI   Spread `json:"ci"`
}

// Rework is the sum of the loops of the landed runs.
type Rework struct {
	GateTries   int `json:"gate_tries"`
	CITries     int `json:"ci_tries"`
	ReviewTries int `json:"review_tries"`
	// CodeReviewRounds counts the code reviews before a push that found a
	// Critical or Major issue.
	CodeReviewRounds int `json:"code_review_rounds"`
	// Redrafts counts the drafts after the first one, with the drafts that
	// failed: each one is a loop back to Shape.
	Redrafts int `json:"redrafts"`
	Turns    int `json:"turns"`
}

// NotLanded counts the runs that did not land, by their last state.
type NotLanded struct {
	Stopped      int `json:"stopped"`
	Limited      int `json:"limited"`
	Cancelled    int `json:"cancelled"`
	StartUnknown int `json:"start_unknown"`
}

// Measure reads the history of the runs of a plot, or of every plot when
// plotID is empty, and returns their metrics from from up to to.
func Measure(s *store.Store, plotID string, from, to time.Time) (Metrics, error) {
	if !from.Before(to) {
		return Metrics{}, fmt.Errorf("the metrics window must start before %s: %w", to.Format(time.RFC3339), store.ErrInvalid)
	}
	runs, events, err := s.RunHistory(plotID)
	if err != nil {
		return Metrics{}, err
	}
	return ComputeMetrics(runs, events, from, to), nil
}

// ComputeMetrics returns the metrics of the runs from their events, which
// are in order for each run.
func ComputeMetrics(runs []store.Run, events []store.RunEvent, from, to time.Time) Metrics {
	byRun := map[string][]store.RunEvent{}
	for _, e := range events {
		byRun[e.RunID] = append(byRun[e.RunID], e)
	}
	fixed := map[string]bool{}
	for _, r := range runs {
		if r.Fixes != "" && r.State != store.RunCancelled {
			fixed[r.Fixes] = true
		}
	}
	paths := make([]runPath, len(runs))
	for i, r := range runs {
		paths[i] = walk(r, byRun[r.ID])
		paths[i].fixed = fixed[r.ID]
	}
	length := to.Sub(from)
	return Metrics{Current: measure(paths, from, to), Previous: measure(paths, from.Add(-length), from)}
}

// runPath is what the events of one run say about it.
type runPath struct {
	run store.Run
	// landed is when the run landed, or zero.
	landed time.Time
	// start is when the run left Shaping, or when Loam recorded it.
	start time.Time
	// last is the time of the last state.
	last     time.Time
	shaped   bool
	stations [stationCount]time.Duration
	tries    map[string]int
	shapes   int
	recover  []recovery
	fixed    bool
}

// recovery is one failure that passed: when it started, its stage, and how
// long it took.
type recovery struct {
	at    time.Time
	stage string
	took  time.Duration
}

// The stations of a run, as indexes of runPath.stations.
const (
	stationApprove = iota
	stationQueue
	stationBuild
	stationShip
	stationMerge
	stationStopped
	stationCount
)

// stationOf is the station of a state. Landed and the other ends have none.
func stationOf(st store.RunState) (int, bool) {
	switch st {
	case store.RunShaping:
		return stationApprove, true
	case store.RunQueued:
		return stationQueue, true
	case store.RunStarting, store.RunRunning:
		return stationBuild, true
	case store.RunShipping:
		return stationShip, true
	case store.RunReady:
		return stationMerge, true
	case store.RunStopped, store.RunLimited, store.RunStartUnknown:
		return stationStopped, true
	}
	return 0, false
}

// passes reports whether a state passes a failure of the stage.
func passes(stage string, st store.RunState) bool {
	if stage == store.TryCI {
		return st == store.RunReady || st == store.RunLanded
	}
	return st == store.RunShipping || st == store.RunReady || st == store.RunLanded
}

// walk reads the events of a run in order. Each state adds the time since
// the state before it to the station of that state. The walk ends when the
// run lands.
func walk(r store.Run, events []store.RunEvent) runPath {
	p := runPath{run: r, tries: map[string]int{}}
	var cur store.RunState
	var since time.Time
	var open *recovery
	for _, e := range events {
		switch e.Kind {
		case "shape":
			p.shapes++
		case "try":
			p.tries[e.Stage]++
			if open == nil {
				open = &recovery{at: e.At, stage: e.Stage}
			}
		case "state":
			st := store.RunState(e.Detail)
			if cur == "" {
				p.start = e.At
			} else if i, ok := stationOf(cur); ok {
				p.stations[i] += e.At.Sub(since)
			}
			if st == store.RunShaping {
				p.shaped = true
			} else if cur == store.RunShaping {
				p.start = e.At
			}
			if open != nil && passes(open.stage, st) {
				open.took = e.At.Sub(open.at)
				p.recover = append(p.recover, *open)
				open = nil
			}
			if i, ok := stationOf(st); st == store.RunCancelled || ok && i == stationStopped {
				open = nil // the failure stopped the run
			}
			cur, since, p.last = st, e.At, e.At
			if st == store.RunLanded {
				p.landed = e.At
				return p
			}
		}
	}
	return p
}

// measure is the metrics of one window.
func measure(paths []runPath, from, to time.Time) MetricsPeriod {
	in := func(t time.Time) bool { return !t.IsZero() && !t.Before(from) && t.Before(to) }
	m := MetricsPeriod{From: from, To: to}
	var lead []time.Duration
	var stations [stationCount][]time.Duration
	var gate, ci []time.Duration
	for _, p := range paths {
		for _, rc := range p.recover {
			if !in(rc.at) {
				continue
			}
			if rc.stage == store.TryCI {
				ci = append(ci, rc.took)
			} else {
				gate = append(gate, rc.took)
			}
		}
		if p.landed.IsZero() {
			if in(p.last) {
				m.NotLanded.add(p.run.State)
			}
			continue
		}
		if !in(p.landed) {
			continue
		}
		m.Landed++
		lead = append(lead, p.landed.Sub(p.start))
		for i, d := range p.stations {
			if i != stationApprove || p.shaped {
				stations[i] = append(stations[i], d)
			}
		}
		tries := p.tries[store.TryGate] + p.tries[store.TryCI]
		if tries == 0 && p.run.ReviewTries == 0 {
			m.FirstPass++
		}
		if p.fixed {
			m.Fixed++
		}
		m.Rework.GateTries += p.tries[store.TryGate]
		m.Rework.CITries += p.tries[store.TryCI]
		m.Rework.ReviewTries += p.run.ReviewTries
		if p.run.CodeReview != nil {
			m.Rework.CodeReviewRounds += p.run.CodeReview.Rounds
		}
		m.Rework.Redrafts += max(0, p.shapes-1)
		m.Rework.Turns += p.run.Turns
	}
	m.LeadTime = spreadOf(lead)
	m.Stations = Stations{
		Approve: spreadOf(stations[stationApprove]), Queue: spreadOf(stations[stationQueue]),
		Build: spreadOf(stations[stationBuild]), Ship: spreadOf(stations[stationShip]),
		Merge: spreadOf(stations[stationMerge]), Stopped: spreadOf(stations[stationStopped]),
	}
	m.Recovery = Recovery{Gate: spreadOf(gate), CI: spreadOf(ci)}
	return m
}

// add counts a run that did not land, by its state. A run that still works
// does not count.
func (n *NotLanded) add(st store.RunState) {
	switch st {
	case store.RunStopped:
		n.Stopped++
	case store.RunLimited:
		n.Limited++
	case store.RunCancelled:
		n.Cancelled++
	case store.RunStartUnknown:
		n.StartUnknown++
	}
}

// spreadOf is the median and the 90th percentile of ds by the nearest rank:
// the value at rank ceil(q × n) of the sorted times.
func spreadOf(ds []time.Duration) Spread {
	if len(ds) == 0 {
		return Spread{}
	}
	sorted := slices.Clone(ds)
	slices.Sort(sorted)
	rank := func(q float64) int64 {
		i := int(math.Ceil(q*float64(len(sorted)))) - 1
		return int64(sorted[i].Round(time.Second) / time.Second)
	}
	return Spread{Count: len(sorted), MedianSeconds: rank(0.5), P90Seconds: rank(0.9)}
}
