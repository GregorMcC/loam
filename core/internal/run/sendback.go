package run

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/store"
)

// Note is one note of yours on the work of a run: on a line of a file, or on
// the whole run when File is empty.
type Note struct {
	File string `json:"file,omitempty"`
	Line int    `json:"line,omitempty"`
	Text string `json:"text"`
}

// String is the note as a line of the prompt.
func (n Note) String() string {
	if n.File == "" {
		return n.Text
	}
	return fmt.Sprintf("%s line %d: %s", n.File, n.Line, n.Text)
}

var notePlace = regexp.MustCompile(`(?s)^([^\s:][^:]*):([0-9]+):\s*(.+)$`)

// ParseNote reads a note as "<file>:<line>: <text>", or as text alone.
func ParseNote(text string) (Note, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return Note{}, fmt.Errorf("a note needs text: %w", store.ErrInvalid)
	}
	if m := notePlace.FindStringSubmatch(text); m != nil {
		line, err := strconv.Atoi(m[2])
		if err == nil && line > 0 {
			return Note{File: m[1], Line: line, Text: m[3]}, nil
		}
	}
	return Note{Text: text}, nil
}

// SendBack resumes the session of a run that waits for you, Ready to land or
// Stopped, with your notes. The run goes back to Running, and then round the
// gate and Ship again. A note is not a failure, so it uses no try. A run that
// has used all its tries gets one more.
func SendBack(ctx context.Context, s *store.Store, id string, notes []Note) (store.Run, error) {
	if len(notes) == 0 {
		return store.Run{}, fmt.Errorf("send back needs a note: add --note <text>: %w", store.ErrInvalid)
	}
	r, err := s.GetRun(id)
	if err != nil {
		return r, err
	}
	if r.State != store.RunReady && r.State != store.RunStopped {
		return r, fmt.Errorf("only a run that is Ready to land or Stopped can go back, and this run is %s: %w", r.State, store.ErrInvalid)
	}
	if r.SessionID == "" {
		return r, fmt.Errorf("the run has no session to send the notes to: %w", store.ErrInvalid)
	}
	from, sent := r.State, false
	note := "Sent back with " + count(len(notes), "note")
	r, err = s.UpdateRun(id, func(r *store.Run) error {
		if r.State != from {
			return nil
		}
		r.State, r.Note, sent = store.RunRunning, note, true
		r.MaxTries = max(r.MaxTries, r.Tries+1)
		return nil
	})
	if err != nil || !sent {
		return r, err
	}
	if err := s.AddRunEvent(id, "review", "Sent back "+count(len(notes), "note")); err != nil {
		return r, err
	}
	if err := send(ctx, r, notesPrompt(r, notes)); err != nil {
		return r, stopAfter(s, id, fmt.Errorf("could not send the notes to the session: %w", err))
	}
	return r, nil
}

// notesPrompt is the prompt that sends your notes back to the session.
func notesPrompt(r store.Run, notes []Note) string {
	var b strings.Builder
	where, then := "", "Loam runs the Done when checks again, and the run comes back to me."
	if r.PR != nil {
		where = fmt.Sprintf(" on #%d", r.PR.Number)
		then = fmt.Sprintf("Loam runs the Done when checks again, then pushes the changes to #%d.", r.PR.Number)
	}
	fmt.Fprintf(&b, "I read your work%s and have %s. Where a note names a file and a line, the line is in the file as it is now.\n\n",
		where, count(len(notes), "note"))
	for _, n := range notes {
		fmt.Fprintf(&b, "- %s\n", n)
	}
	fmt.Fprintf(&b, "\nMake the changes, commit them, and end your turn. %s\n", then)
	return b.String()
}
