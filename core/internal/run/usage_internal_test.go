package run

import (
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// The line that Claude Code 2.1.312 prints in stream-json output.
const rateLimitLine = `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793187600,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.18,"resetsAt":1793187600,"status":"allowed"},"seven_day":{"utilization":0.18,"resetsAt":1793660400,"status":"allowed"}}}}`

func TestParseUsageReadsBothWindows(t *testing.T) {
	u, ok := parseUsage([]byte(rateLimitLine))
	if !ok || u.FiveHour == nil || u.SevenDay == nil {
		t.Fatalf("%+v %v", u, ok)
	}
	if u.FiveHour.Utilization != 0.18 || !u.FiveHour.ResetsAt.Equal(time.Unix(1793187600, 0)) ||
		u.SevenDay.Utilization != 0.18 || !u.SevenDay.ResetsAt.Equal(time.Unix(1793660400, 0)) {
		t.Fatalf("%+v %+v", u.FiveHour, u.SevenDay)
	}
	// An event with no window that Loam knows reports nothing.
	if _, ok := parseUsage([]byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}`)); ok {
		t.Fatal("no windows parsed as usage")
	}
}

// The draft stream gives the usage of a rate limit event to its recorder,
// and still returns the result.
func TestDraftStreamGivesTheUsage(t *testing.T) {
	stream := rateLimitLine + "\n" + `{"type":"result","subtype":"success","is_error":false,"result":"ok"}` + "\n"
	var got []store.Usage
	res, err := readDraftStream(strings.NewReader(stream), "/work", func(string) {}, func(u store.Usage) { got = append(got, u) })
	if err != nil || res == nil || res.Result != "ok" || len(got) != 1 || got[0].SevenDay == nil {
		t.Fatalf("%+v %v %+v", res, err, got)
	}
}
