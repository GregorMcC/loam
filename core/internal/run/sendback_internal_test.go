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
