package run

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

func TestParseNote(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want Note
	}{
		{"core/search/match.go:21: Match repo labels too.", Note{File: "core/search/match.go", Line: 21, Text: "Match repo labels too."}},
		{"  Add a test.  ", Note{Text: "Add a test."}},
		{"a.go:12:Two lines,\nas one note.", Note{File: "a.go", Line: 12, Text: "Two lines,\nas one note."}},
		// Text that only looks like a place stays text.
		{"Note: this is fine.", Note{Text: "Note: this is fine."}},
		{"a.go:0: no line 0", Note{Text: "a.go:0: no line 0"}},
		{"a.go:x: not a line", Note{Text: "a.go:x: not a line"}},
	} {
		got, err := ParseNote(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("ParseNote(%q) = %+v, %v; want %+v", tc.in, got, err, tc.want)
		}
	}
	if _, err := ParseNote(" \n "); err == nil {
		t.Error("an empty note parsed")
	}
}

func TestSimilarNotes(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"Keep the README short.", "Please keep the README short!", true},
		{"Use the colour tokens in views.", "Views must use the colour tokens.", true},
		{"Keep the README short.", "Keep the test names short.", false},
		// One word in common is not enough.
		{"Add a test.", "Add a comment.", false},
		{"", "Keep it short.", false},
	} {
		if got := similarNotes(tc.a, tc.b); got != tc.want {
			t.Errorf("similarNotes(%q, %q) = %v", tc.a, tc.b, got)
		}
	}
	if got := noteText("docs/a.md line 4: Keep it short."); got != "Keep it short." {
		t.Errorf("noteText = %q", got)
	}
}

// TAS-220: you can send back a run that is Shipping. A tick that ships the
// run at that moment read it as Shipping, and must not write over the run
// that went back to Running.
func TestATickLeavesARunThatWentBackDuringTheTick(t *testing.T) {
	s, r := runWithTemp(t, store.RunShipping)
	sh := &shipper{s: s, r: r} // the tick read the run as Shipping
	back, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.State, r.Note = store.RunRunning, "Sent back with 1 note"
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// Every slot is taken, so a resume that still checked a slot would put
	// the run in Queued.
	if _, err := s.AddRun(store.Run{PlotID: r.PlotID, Title: "Other", Folder: t.TempDir(), State: store.RunRunning}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 1}); err != nil {
		t.Fatal(err)
	}
	steps := map[string]func() (bool, error){
		"move":    func() (bool, error) { return sh.move(store.RunReady, "Ready to land") },
		"moveTry": func() (bool, error) { return sh.moveTry(store.RunStopped, "CI failed") },
		"update":  func() (bool, error) { return sh.update(func(r *store.Run) { r.CIRerun = "abc" }) },
		"adopt": func() (bool, error) {
			return sh.adopt(context.Background(), &github.PR{Number: 7, URL: "https://github.com/acme/web/pull/7"})
		},
		"resume": func() (bool, error) {
			return sh.resume(context.Background(), "CI failed", "Fixing the CI failure", "CI failure", func(r *store.Run) { r.Tries++ })
		},
	}
	for name, step := range steps {
		sh.r, sh.movedOn = r, false
		if moved, err := step(); err != nil || moved {
			t.Errorf("%s: moved %v, %v; want the run left as it is", name, moved, err)
		}
		got, err := s.GetRun(r.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got.State != store.RunRunning || got.Note != back.Note || got.Tries != back.Tries || got.CIRerun != "" || got.Queue != nil ||
			!got.UpdatedAt.Equal(back.UpdatedAt) {
			t.Errorf("%s: the run is %s (%q, %d tries), want it as send-back left it", name, got.State, got.Note, got.Tries)
		}
		// A later step of the same tick, such as passCI after a guard that
		// failed in endReplies, must not take Running as the state it read.
		if sh.r.State != store.RunShipping {
			t.Errorf("%s: the shipper took the state %s as its own", name, sh.r.State)
		}
		for later, step := range steps {
			if moved, err := step(); err != nil || moved {
				t.Errorf("%s then %s: moved %v, %v; want no write", name, later, moved, err)
			}
		}
		if got, _ := s.GetRun(r.ID); got.State != store.RunRunning || !got.UpdatedAt.Equal(back.UpdatedAt) {
			t.Errorf("%s: a later step wrote the run: %s (%q)", name, got.State, got.Note)
		}
	}
	// A PR that the run does not hold gets no event.
	if e := lastEvent(t, s, r.ID, "ship"); e != "" {
		t.Errorf("ship event %q for a run that went back", e)
	}
}

// TAS-220: a tick can resume a Shipping run, for example with a CI failure,
// after send-back read it. With every slot taken, the send-back must not put
// the run in Queued with your notes while its session works on the CI
// prompt, and it must say that the notes did not go back.
func TestASendBackLeavesARunThatATickMoved(t *testing.T) {
	s, r := runWithTemp(t, store.RunShipping)
	moved, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.State, r.Note, r.Tries = store.RunRunning, "Fixing the CI failure", r.Tries+1
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddRun(store.Run{PlotID: r.PlotID, Title: "Other", Folder: t.TempDir(), State: store.RunRunning}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 1}); err != nil {
		t.Fatal(err)
	}
	got, err := takeSendBack(s, r, 1, "the notes")
	if !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), "did not go back") {
		t.Fatalf("err %v, want the notes refused", err)
	}
	after, _ := s.GetRun(r.ID)
	if got.State != store.RunRunning || after.State != store.RunRunning || after.Note != moved.Note || after.Queue != nil ||
		!after.UpdatedAt.Equal(moved.UpdatedAt) {
		t.Fatalf("the run is %s (%q), want it as the tick left it", after.State, after.Note)
	}
}
