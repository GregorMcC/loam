package run

import "testing"

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
