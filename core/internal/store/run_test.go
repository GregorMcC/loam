package store_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

func addTestRun(t *testing.T, s *store.Store, plotID string) store.Run {
	t.Helper()
	r, err := s.AddRun(store.Run{
		PlotID:   plotID,
		Title:    "Drag a link to reorder",
		Goal:     "A link in the brief moves by drag.",
		Folder:   "/work/app-eng-523",
		DoneWhen: []store.Check{{Name: "Go tests", Command: "go test ./..."}},
		Source:   &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/x/issue/ENG-523"},
	})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestAddRunGivesAnIDAndDefaults(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if len(r.ID) != store.IDLength || r.State != store.RunStarting || r.Tries != 0 || r.MaxTries != store.DefaultMaxTries {
		t.Fatalf("%+v", r)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != r.Title || got.Folder != r.Folder || !slices.Equal(got.DoneWhen, r.DoneWhen) ||
		got.Source == nil || *got.Source != *r.Source || got.CreatedAt.IsZero() {
		t.Fatalf("got %+v, want %+v", got, r)
	}
	if _, err := s.GetRun("nope"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("missing run: %v", err)
	}
}

func TestAddRunChecksItsInput(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	cases := map[string]store.Run{
		"no plot":       {Title: "x", Folder: "/w"},
		"no title":      {PlotID: p.ID, Folder: "/w"},
		"no folder":     {PlotID: p.ID, Title: "x"},
		"empty check":   {PlotID: p.ID, Title: "x", Folder: "/w", DoneWhen: []store.Check{{Name: "Tests"}}},
		"bad max tries": {PlotID: p.ID, Title: "x", Folder: "/w", MaxTries: -1},
	}
	for name, r := range cases {
		if _, err := s.AddRun(r); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := s.AddRun(store.Run{PlotID: "zzzzzzzzzz", Title: "x", Folder: "/w"}); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown plot: %v", err)
	}
}

func TestListRunsNewestFirstAndByPlot(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	r1 := addTestRun(t, s, a.ID)
	r2 := addTestRun(t, s, b.ID)
	r3 := addTestRun(t, s, a.ID)
	ids := func(rs []store.Run) []string {
		var out []string
		for _, r := range rs {
			out = append(out, r.ID)
		}
		return out
	}
	all, err := s.ListRuns("")
	if err != nil || !slices.Equal(ids(all), []string{r3.ID, r2.ID, r1.ID}) {
		t.Fatalf("all: %v %v", ids(all), err)
	}
	inA, err := s.ListRuns(a.ID)
	if err != nil || !slices.Equal(ids(inA), []string{r3.ID, r1.ID}) {
		t.Fatalf("plot A: %v %v", ids(inA), err)
	}
}

func TestUpdateRunLogsStateChangesAndTries(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)

	got, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.State = store.RunRunning
		r.SessionID = "c57ef956-3136-4e86-bfde-da8facfe0523"
		return nil
	})
	if err != nil || got.State != store.RunRunning || got.SessionID == "" {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Tries++
		r.Note = "Go tests failed"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// An error from fn writes nothing.
	boom := errors.New("boom")
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.State = store.RunLanded; return boom }); !errors.Is(err, boom) {
		t.Fatalf("fn error: %v", err)
	}
	// The ID, the plot, and the creation time never change.
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.PlotID = "other"; return nil }); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("plot change: %v", err)
	}
	// A state must be known.
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.State = "done-ish"; return nil }); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("bad state: %v", err)
	}

	got, err = s.GetRun(r.ID)
	if err != nil || got.State != store.RunRunning || got.Tries != 1 || got.Note != "Go tests failed" {
		t.Fatalf("%+v %v", got, err)
	}
	events, err := s.RunEvents(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, e := range events {
		kinds = append(kinds, e.Kind+":"+e.Detail)
	}
	want := []string{"state:starting", "state:running", "try:Go tests failed"}
	if !slices.Equal(kinds, want) {
		t.Fatalf("events %q, want %q", kinds, want)
	}
}

// Ticket 206: a shipped run keeps the PR that Loam opened for it.
func TestUpdateRunKeepsThePROfAShippedRun(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if r.PR != nil {
		t.Fatalf("a new run has PR %+v", r.PR)
	}
	_, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.State, r.PR = store.RunShipping, &store.RunPR{Number: 147, URL: "https://github.com/example/widgets/pull/147"}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunShipping || got.PR == nil || got.PR.Number != 147 || got.PR.URL != "https://github.com/example/widgets/pull/147" {
		t.Fatalf("got %+v, PR %+v", got, got.PR)
	}
	if got.State.NeedsYou() || got.State.Ended() {
		t.Fatal("a shipping run waits for CI, not for you")
	}
}

// TAS-60: a run keeps the count of its review tries and the reviews that Loam sent back, so it sends none twice.
func TestUpdateRunKeepsTheReviewsSentBack(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if r.ReviewTries != 0 || r.ReviewsSent != nil {
		t.Fatalf("a new run has review tries %d, sent %q", r.ReviewTries, r.ReviewsSent)
	}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.ReviewTries, r.ReviewsSent = 1, append(r.ReviewsSent, "PRR_1", "PRR_2")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// Another change keeps them.
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.Note = "later"; return nil }); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ReviewTries != 1 || !slices.Equal(got.ReviewsSent, []string{"PRR_1", "PRR_2"}) || got.Tries != 0 {
		t.Fatalf("review tries %d, sent %q, tries %d", got.ReviewTries, got.ReviewsSent, got.Tries)
	}
}

// TAS-175: a run keeps the threads of the review that Loam sent back, so Loam posts the replies of the session to
// those threads only. A new run has none, and the JSON leaves them out.
func TestUpdateRunKeepsTheReviewRepliesOutOfTheJSON(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if r.ReviewReplies != nil {
		t.Fatalf("a new run has review replies %+v", r.ReviewReplies)
	}
	cp := r
	cp.ReviewReplies = &store.RunReviewReplies{PR: 7, Threads: []string{"PRRT_1"}}
	if c, err := s.AddRun(cp); err != nil || c.ReviewReplies != nil {
		t.Fatalf("a new run keeps the review replies of a copy: %+v, %v", c.ReviewReplies, err)
	}
	want := store.RunReviewReplies{PR: 7, Threads: []string{"PRRT_1", "PRRT_2"}, Cut: []string{"PRRT_2"}, Comment: true,
		Replied: []string{"PRRT_1"}, Commented: true}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.ReviewReplies = &want; return nil }); err != nil {
		t.Fatal(err)
	}
	// Another change keeps them.
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.Note = "later"; return nil }); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if rr := got.ReviewReplies; rr == nil || rr.PR != 7 || !slices.Equal(rr.Threads, want.Threads) || !slices.Equal(rr.Cut, want.Cut) || !rr.Comment ||
		!slices.Equal(rr.Replied, want.Replied) || !rr.Commented {
		t.Fatalf("review replies %+v", got.ReviewReplies)
	}
	if b, err := json.Marshal(got); err != nil || strings.Contains(string(b), "PRRT_1") {
		t.Fatalf("the run JSON has the review replies: %s, %v", b, err)
	}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.ReviewReplies = nil; return nil }); err != nil {
		t.Fatal(err)
	}
	if got, err := s.GetRun(r.ID); err != nil || got.ReviewReplies != nil {
		t.Fatalf("review replies after a clear %+v, %v", got.ReviewReplies, err)
	}
}

func TestUpdateRunKeepsTheCodeReviewOutOfTheJSON(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if r.CodeReview != nil {
		t.Fatalf("a new run has a code review %+v", r.CodeReview)
	}
	cp := r
	cp.CodeReview = &store.RunCodeReview{Head: "abc123", Rounds: 4}
	if c, err := s.AddRun(cp); err != nil || c.CodeReview != nil {
		t.Fatalf("a new run keeps the code review of a copy: %+v, %v", c.CodeReview, err)
	}
	want := store.RunCodeReview{Head: "abc123", Rounds: 2, Facts: []string{"Minor issue from the code review: a.go:3: A typo."}}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.CodeReview = &want; return nil }); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if c := got.CodeReview; c == nil || c.Head != want.Head || c.Rounds != want.Rounds || !slices.Equal(c.Facts, want.Facts) {
		t.Fatalf("code review %+v", got.CodeReview)
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "abc123") {
		t.Fatalf("the run JSON has the code review: %s", b)
	}
}

func TestRunStateNeedsYou(t *testing.T) {
	for st, want := range map[store.RunState]bool{
		store.RunShaping: true, store.RunStopped: true, store.RunLimited: true,
		store.RunStarting: false, store.RunRunning: false, store.RunReady: false,
		store.RunStartUnknown: false, store.RunLanded: false, store.RunCancelled: false,
	} {
		if st.NeedsYou() != want {
			t.Errorf("%s: NeedsYou %v", st, !want)
		}
	}
}

func TestDeletePlotRemovesItsRuns(t *testing.T) {
	s := openStore(t)
	gone, keep := newPlot(t, s, "Gone"), newPlot(t, s, "Keep")
	addTestRun(t, s, gone.ID)
	kept := addTestRun(t, s, keep.ID)
	if err := s.SetArchived(gone.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeletePlot(gone.ID); err != nil {
		t.Fatal(err)
	}
	all, err := s.ListRuns("")
	if err != nil || len(all) != 1 || all[0].ID != kept.ID {
		t.Fatalf("%+v %v", all, err)
	}
	if ev, err := s.RunEvents(kept.ID); err != nil || len(ev) != 1 {
		t.Fatalf("events of the kept run: %+v %v", ev, err)
	}
}

func TestRunFeedListsTheEventsOfEveryPlotNewestFirst(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	ra, rb := addTestRun(t, s, a.ID), addTestRun(t, s, b.ID)
	if err := s.AddRunEvent(ra.ID, "note", "first note"); err != nil {
		t.Fatal(err)
	}
	if err := s.AddRunEvent(rb.ID, "ship", "Opened #12"); err != nil {
		t.Fatal(err)
	}
	all, err := s.RunFeed("", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	// Each run starts with a state event, so the feed has four.
	if len(all) != 4 || all[0].RunID != rb.ID || all[0].Detail != "Opened #12" || all[0].PlotID != b.ID ||
		all[0].RunTitle != rb.Title || all[1].Detail != "first note" {
		t.Fatalf("all %+v", all)
	}
	one, err := s.RunFeed(a.ID, time.Time{})
	if err != nil || len(one) != 2 || one[0].RunID != ra.ID {
		t.Fatalf("one %+v %v", one, err)
	}
	none, err := s.RunFeed("", time.Now().Add(time.Minute))
	if err != nil || len(none) != 0 || none == nil {
		t.Fatalf("since %+v %v", none, err)
	}
}

func TestRunFeedKeepsAtMostTwoHundredEvents(t *testing.T) {
	s := openStore(t)
	r := addTestRun(t, s, newPlot(t, s, "A").ID)
	for i := 0; i < store.FeedLimit+5; i++ {
		if err := s.AddRunEvent(r.ID, "note", fmt.Sprint("note ", i)); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.RunFeed("", time.Time{})
	if err != nil || len(got) != store.FeedLimit || got[0].Detail != fmt.Sprint("note ", store.FeedLimit+4) {
		t.Fatalf("%d events, first %q, %v", len(got), got[0].Detail, err)
	}
}

// TAS-176: a try in Running is a gate try, and a try in Shipping is a CI
// try. The stage stays out of the JSON.
func TestUpdateRunGivesEachTryItsStage(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	steps := []func(*store.Run){
		func(r *store.Run) { r.State = store.RunRunning },
		func(r *store.Run) { r.Tries++ },
		func(r *store.Run) { r.State = store.RunShipping },
		func(r *store.Run) { r.State, r.Tries = store.RunRunning, r.Tries+1 },
	}
	for _, step := range steps {
		if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { step(r); return nil }); err != nil {
			t.Fatal(err)
		}
	}
	events, err := s.RunEvents(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	var stages []string
	for _, e := range events {
		if e.Kind == "try" {
			stages = append(stages, e.Stage)
		}
	}
	if !slices.Equal(stages, []string{store.TryGate, store.TryCI}) {
		t.Fatalf("stages %q", stages)
	}
	b, err := json.Marshal(events[0])
	if err != nil || strings.Contains(string(b), "stage") {
		t.Fatalf("json %s %v", b, err)
	}
}

// TAS-176: a run keeps the run that it fixes, and cannot fix itself.
func TestARunKeepsTheRunThatItFixes(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	landed := addTestRun(t, s, p.ID)
	fix, err := s.AddRun(store.Run{PlotID: p.ID, Title: "Fix the drag", Folder: "/work/fix", Fixes: landed.ID})
	if err != nil || fix.Fixes != landed.ID {
		t.Fatalf("%+v %v", fix, err)
	}
	if got, err := s.GetRun(fix.ID); err != nil || got.Fixes != landed.ID {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := s.UpdateRun(fix.ID, func(r *store.Run) error { r.Fixes = r.ID; return nil }); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("a run that fixes itself: %v", err)
	}
	b, err := json.Marshal(landed)
	if err != nil || !strings.Contains(string(b), `"fixes":""`) {
		t.Fatalf("json %s %v", b, err)
	}
}

// TAS-176: the history of a plot holds its runs, oldest first, and their
// events in order, and leaves out the runs of other plots.
func TestRunHistoryHoldsTheRunsAndEventsOfAPlot(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	first, second := addTestRun(t, s, a.ID), addTestRun(t, s, a.ID)
	other := addTestRun(t, s, b.ID)
	if err := s.AddRunEvent(first.ID, "check", "Go tests passed"); err != nil {
		t.Fatal(err)
	}
	runs, events, err := s.RunHistory(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 || runs[0].ID != first.ID || runs[1].ID != second.ID {
		t.Fatalf("runs %+v", runs)
	}
	var got []string
	for _, e := range events {
		got = append(got, e.RunID+":"+e.Kind)
	}
	want := []string{first.ID + ":state", second.ID + ":state", first.ID + ":check"}
	if !slices.Equal(got, want) {
		t.Fatalf("events %q, want %q", got, want)
	}
	if runs, events, err := s.RunHistory(""); err != nil || len(runs) != 3 || len(events) != 4 || runs[2].ID != other.ID {
		t.Fatalf("all: %d runs, %d events, %v", len(runs), len(events), err)
	}
}
