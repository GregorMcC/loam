package run

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"

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

// RuleOffer says that a note that you sent back is like a note that you sent
// back on another run of the plot (ticket 209): a fix made twice, which a
// rule can check on every run.
type RuleOffer struct {
	Note string `json:"note"`
	// Earlier is the note like it, on the run EarlierRunID.
	Earlier      string `json:"earlier"`
	EarlierRunID string `json:"earlier_run_id"`
	EarlierTitle string `json:"earlier_title"`
}

// SendBack resumes the session of a run that waits for you, Ready to land or
// Stopped, with your notes. The run goes back to Running, and then round the
// gate and Ship again. A note is not a failure, so it uses no try. A run that
// has used all its tries gets one more, up to the limit of tries. Each note is a note event of the run.
// When a note is like one that you sent back on another run of the plot, and
// no rule came from such a note, the offer says so.
func SendBack(ctx context.Context, s *store.Store, id string, notes []Note) (store.Run, *RuleOffer, error) {
	r, err := sendBack(ctx, s, id, notes)
	if err != nil {
		return r, nil, err
	}
	return r, ruleOffer(s, r, notes), nil
}

func sendBack(ctx context.Context, s *store.Store, id string, notes []Note) (store.Run, error) {
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
		r.MaxTries = min(max(r.MaxTries, r.Tries+1), store.MaxTriesLimit)
		return nil
	})
	if err != nil || !sent {
		return r, err
	}
	if err := s.AddRunEvent(id, "review", "Sent back "+count(len(notes), "note")); err != nil {
		return r, err
	}
	for _, n := range notes {
		if err := s.AddRunEvent(id, "note", n.String()); err != nil {
			return r, err
		}
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

// ruleOffer finds the first note that is like a note on another run of the
// plot, the newest run first. A note like the note of a rule has its rule.
func ruleOffer(s *store.Store, r store.Run, notes []Note) *RuleOffer {
	rules, err := s.ListRules(r.PlotID)
	if err != nil {
		return nil
	}
	runs, err := s.ListRuns(r.PlotID)
	if err != nil {
		return nil
	}
	for _, n := range notes {
		if slices.ContainsFunc(rules, func(rule store.Rule) bool { return similarNotes(n.Text, rule.Note) }) {
			continue
		}
		for _, other := range runs {
			if other.ID == r.ID {
				continue
			}
			events, err := s.RunEvents(other.ID)
			if err != nil {
				continue
			}
			for _, e := range events {
				if e.Kind != "note" {
					continue
				}
				if earlier := noteText(e.Detail); similarNotes(n.Text, earlier) {
					return &RuleOffer{Note: n.Text, Earlier: earlier, EarlierRunID: other.ID, EarlierTitle: other.Title}
				}
			}
		}
	}
	return nil
}

var noteEventPlace = regexp.MustCompile(`(?s)^\S[^\n]* line [0-9]+: (.+)$`)

// noteText is the text of a note event, without its file and line.
func noteText(detail string) string {
	if m := noteEventPlace.FindStringSubmatch(detail); m != nil {
		return m[1]
	}
	return detail
}

// minorWords are left out when notes are compared.
var minorWords = map[string]bool{
	"the": true, "and": true, "for": true, "with": true, "this": true, "that": true, "not": true, "are": true,
	"you": true, "from": true, "into": true, "when": true, "its": true, "has": true, "have": true, "was": true,
	"but": true, "all": true, "any": true, "can": true, "one": true, "too": true, "only": true, "also": true,
	"please": true, "here": true, "there": true, "then": true, "than": true, "should": true, "must": true,
}

// similarNotes reports whether two notes ask for the same kind of fix: at
// least 2 words in common, and at least half of all their words.
func similarNotes(a, b string) bool {
	wa, wb := noteWords(a), noteWords(b)
	if len(wa) == 0 || len(wb) == 0 {
		return false
	}
	shared := 0
	for w := range wa {
		if wb[w] {
			shared++
		}
	}
	all := len(wa) + len(wb) - shared
	return shared >= 2 && 2*shared >= all
}

func noteWords(text string) map[string]bool {
	out := map[string]bool{}
	for _, w := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len(w) >= 3 && !minorWords[w] {
			out[w] = true
		}
	}
	return out
}
