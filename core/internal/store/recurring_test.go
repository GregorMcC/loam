package store_test

import (
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// wed is Wednesday 2026-10-28, 09:00 on the clock of the Mac.
var wed = time.Date(2026, 10, 28, 9, 0, 0, 0, time.Local)

func addTestRecurring(t *testing.T, s *store.Store, plotID string, days []string, at string) store.Recurring {
	t.Helper()
	r, err := s.AddRecurring(store.Recurring{
		PlotID: plotID, Title: "Shape new issues", Prompt: "Shape a run for each new bug.", Kind: store.RecurringShape,
		Days: days, At: at, Precheck: "true",
	}, wed)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestAddRecurringGivesTheNextTimeAndDefaults(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRecurring(t, s, p.ID, []string{"fri", "mon", "tue", "wed", "thu", "mon"}, "06:30")
	// 06:30 on Wednesday has passed, so the next time is Thursday.
	if want := time.Date(2026, 10, 29, 6, 30, 0, 0, time.Local); !r.NextAt.Equal(want) {
		t.Fatalf("next %v, want %v", r.NextAt, want)
	}
	if !slices.Equal(r.Days, []string{"mon", "tue", "wed", "thu", "fri"}) || r.IfAsleep != store.AsleepRunOnce ||
		r.MaxTries != store.DefaultMaxTries || len(r.ID) != store.IDLength {
		t.Fatalf("%+v", r)
	}
	got, err := s.GetRecurring(r.ID)
	if err != nil || !got.NextAt.Equal(r.NextAt) || !slices.Equal(got.Days, r.Days) || got.LastAt != nil {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestNextAfterFollowsTheTimetable(t *testing.T) {
	r := store.Recurring{Days: []string{"wed"}, At: "09:00"}
	// The time itself is not after it, so the next is a week on.
	if got, want := r.NextAfter(wed), wed.AddDate(0, 0, 7); !got.Equal(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	r = store.Recurring{Days: []string{"sat", "sun"}, At: "22:15"}
	if got, want := r.NextAfter(wed), time.Date(2026, 10, 31, 22, 15, 0, 0, time.Local); !got.Equal(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestAddRecurringRefusesABadTimetable(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	for _, r := range []store.Recurring{
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: store.RecurringChore, Days: []string{"mon"}, At: "7:5"},
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: store.RecurringChore, Days: []string{"mon"}, At: "24:00"},
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: store.RecurringChore, Days: []string{"monday"}, At: "07:00"},
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: store.RecurringChore, At: "07:00"},
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: "nightly", Days: []string{"mon"}, At: "07:00"},
		{PlotID: p.ID, Title: "T", Kind: store.RecurringChore, Days: []string{"mon"}, At: "07:00"},
		{PlotID: p.ID, Title: "T", Prompt: "P", Kind: store.RecurringChore, Days: []string{"mon"}, At: "07:00", IfAsleep: "later"},
	} {
		if _, err := s.AddRecurring(r, wed); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%+v: %v", r, err)
		}
	}
}

func TestOnlyOneTickClaimsADueTime(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRecurring(t, s, p.ID, []string{"thu"}, "06:30")
	next := r.NextAfter(r.NextAt)
	if ok, err := s.ClaimRecurring(r.ID, r.NextAt, next); !ok || err != nil {
		t.Fatalf("first claim: %v %v", ok, err)
	}
	if ok, err := s.ClaimRecurring(r.ID, r.NextAt, next); ok || err != nil {
		t.Fatalf("second claim: %v %v", ok, err)
	}
	if err := s.RecordRecurring(r.ID, r.NextAt, "Skipped: the precheck found no work", ""); err != nil {
		t.Fatal(err)
	}
	got, _ := s.GetRecurring(r.ID)
	if !got.NextAt.Equal(next) || got.LastAt == nil || !got.LastAt.Equal(r.NextAt) || got.LastNote == "" {
		t.Fatalf("%+v", got)
	}
}

func TestRemoveRecurringAndThePlotRemovesIt(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRecurring(t, s, p.ID, []string{"mon"}, "06:30")
	if err := s.RemoveRecurring(r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetRecurring(r.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("got %v", err)
	}
	if list, _ := s.ListRecurring(p.ID); len(list) != 0 {
		t.Fatalf("%+v", list)
	}
}
