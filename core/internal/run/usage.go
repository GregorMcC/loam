package run

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/store"
)

// UsageMaxAge is how old the usage can be before Loam reads it again with a
// probe, when the hold needs it. It is also how long Loam waits after a
// probe, whether it worked or not, before it tries another.
const UsageMaxAge = 30 * time.Minute

// probeTimeout limits the usage probe.
const probeTimeout = 60 * time.Second

// probePrompt is the prompt of the usage probe. Its answer does not matter.
const probePrompt = "Reply with ok"

// rateLimitEvent is the stream-json message in which Claude Code reports its
// usage, such as:
//
//	{"type":"rate_limit_event","rate_limit_info":{"status":"allowed", ...,
//	 "unifiedWindows":{"five_hour":{"utilization":0.18,"resetsAt":1793187600},
//	 "seven_day":{"utilization":0.18,"resetsAt":1793660400}}}}
type rateLimitEvent struct {
	Info struct {
		Windows map[string]struct {
			Utilization *float64 `json:"utilization"`
			// ResetsAt is in Unix seconds.
			ResetsAt int64 `json:"resetsAt"`
		} `json:"unifiedWindows"`
	} `json:"rate_limit_info"`
}

// parseUsage reads the usage of a rate limit event. It returns false when
// the event has no window that Loam knows.
func parseUsage(raw []byte) (store.Usage, bool) {
	var e rateLimitEvent
	if err := json.Unmarshal(raw, &e); err != nil {
		return store.Usage{}, false
	}
	window := func(name string) *store.UsageWindow {
		w, ok := e.Info.Windows[name]
		if !ok || w.Utilization == nil {
			return nil
		}
		return &store.UsageWindow{Utilization: *w.Utilization, ResetsAt: time.Unix(w.ResetsAt, 0)}
	}
	u := store.Usage{FiveHour: window("five_hour"), SevenDay: window("seven_day")}
	return u, u.FiveHour != nil || u.SevenDay != nil
}

// usageRecorder returns a func that records the usage that Claude Code
// reports. A usage that Loam cannot record is lost: it does not stop the
// call that reported it.
func usageRecorder(s *store.Store) func(store.Usage) {
	return func(u store.Usage) { s.RecordUsage(u, time.Now()) }
}

// ProbeUsage asks Claude Code for its usage with a small claude -p call in
// a new temp folder, and records it. The call uses Haiku, no tools, and no
// session file, so it costs very little.
func ProbeUsage(ctx context.Context, s *store.Store) (store.Usage, error) {
	claude, err := claudebin.Find()
	if err != nil {
		return store.Usage{}, err
	}
	dir, err := os.MkdirTemp("", "loam-usage-")
	if err != nil {
		return store.Usage{}, err
	}
	defer os.RemoveAll(dir)
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, claude, "-p", probePrompt, "--model", "haiku", "--output-format", "stream-json", "--verbose",
		"--no-session-persistence", "--tools", "")
	cmd.Dir = dir
	cmd.WaitDelay = time.Second
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return store.Usage{}, err
	}
	if err := cmd.Start(); err != nil {
		return store.Usage{}, errors.New(failureNote("claude -p failed", err, errOut.String()))
	}
	var got *store.Usage
	_, readErr := readDraftStream(stdout, dir, func(string) {}, func(u store.Usage) { got = &u })
	if err := cmd.Wait(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		if ctx.Err() != nil {
			return store.Usage{}, fmt.Errorf("claude -p did not answer in %s", probeTimeout)
		}
		return store.Usage{}, errors.New(failureNote("claude -p failed", err, errOut.String()))
	}
	if readErr != nil {
		return store.Usage{}, fmt.Errorf("claude -p gave an answer that Loam cannot read: %w", readErr)
	}
	if got == nil {
		return store.Usage{}, errors.New("claude -p reported no usage")
	}
	return s.RecordUsage(*got, time.Now())
}

// usageStale reports whether the usage is older than [UsageMaxAge] at now, or
// was never read.
func usageStale(u store.Usage, now time.Time) bool {
	return u.ReadAt == nil || now.Sub(*u.ReadAt) > UsageMaxAge
}

// usageForHold probes the usage before a run of yours takes a slot, when the
// hold is on and the usage is stale, as [probeStale] decides. Loam tries at
// most one probe in [UsageMaxAge], so an action of yours costs at most one.
// A probe that fails leaves the stored usage, and the hold decides from it.
func usageForHold(ctx context.Context, s *store.Store) {
	if l, err := s.GetRunLimits(); err == nil && l.HoldAt > 0 {
		probeStale(ctx, s)
	}
}

// probeStale probes the usage when Loam read it more than [UsageMaxAge] ago,
// and no probe was tried in that time. It returns a warning when it cannot
// read the usage.
func probeStale(ctx context.Context, s *store.Store) string {
	u, err := s.GetUsage()
	if err != nil {
		return err.Error()
	}
	now := time.Now()
	if !usageStale(u, now) {
		return ""
	}
	if ok, err := s.ClaimUsageProbe(now, UsageMaxAge); err != nil || !ok {
		if err != nil {
			return err.Error()
		}
		return ""
	}
	if _, err := ProbeUsage(ctx, s); err != nil {
		return "Loam could not read the usage of Claude Code: " + err.Error()
	}
	return ""
}
