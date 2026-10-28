package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// RecurringKind is what a recurring run does when its precheck finds work.
type RecurringKind string

const (
	// RecurringShape has Claude draft a run in Shaping, for you to approve.
	RecurringShape RecurringKind = "shape"
	// RecurringChore starts a run, which works to its gate and then waits
	// for you to land it.
	RecurringChore RecurringKind = "chore"
)

// IfAsleep says what a recurring run does when the Mac slept through its
// time.
type IfAsleep string

const (
	// AsleepRunOnce runs once when the Mac wakes, for all the times it
	// missed.
	AsleepRunOnce IfAsleep = "once"
	// AsleepSkip skips the times that the Mac missed.
	AsleepSkip IfAsleep = "skip"
)

// weekdays are the names of the days of a schedule, Sunday first, as
// [time.Weekday] counts them.
var weekdays = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}

// Recurring is a run that starts on a timetable (ticket 208), such as "Shape
// new issues" on weekdays at 06:30. `loam tick` starts it when it is due and
// its precheck finds work. A recurring run is not in the change log, as runs
// are not.
type Recurring struct {
	ID     string `json:"id"`
	PlotID string `json:"plot_id"`
	Title  string `json:"title"`
	// Prompt is what Claude does: the goal of a chore, or the brief that
	// Claude drafts a run from.
	Prompt string        `json:"prompt"`
	Kind   RecurringKind `json:"kind"`
	// Days are the days of the week that it runs on: sun, mon, and so on,
	// in that order.
	Days []string `json:"days"`
	// At is the time of day, HH:MM, on the clock of the Mac.
	At string `json:"at"`
	// Precheck is a shell command that runs in the repo. The run starts only
	// when it exits 0. Empty starts the run each time.
	Precheck string   `json:"precheck"`
	IfAsleep IfAsleep `json:"if_asleep"`
	// Repo is the repo of the run, by ID or path, or empty for the main repo
	// of the plot.
	Repo     string  `json:"repo"`
	DoneWhen []Check `json:"done_when"`
	MaxTries int     `json:"max_tries"`
	Model    string  `json:"model"`
	Effort   string  `json:"effort"`
	// NextAt is the next time that it is due.
	NextAt time.Time `json:"next_at"`
	// LastAt, LastNote and LastRunID say what the last tick that took it
	// did: the run that it started, or why it skipped.
	LastAt    *time.Time `json:"last_at,omitempty"`
	LastNote  string     `json:"last_note"`
	LastRunID string     `json:"last_run_id"`
	CreatedAt time.Time  `json:"created_at"`
}

func (r *Recurring) check() error {
	var missing []string
	if r.PlotID == "" {
		missing = append(missing, "a plot")
	}
	if strings.TrimSpace(r.Title) == "" {
		missing = append(missing, "a title")
	}
	if strings.TrimSpace(r.Prompt) == "" {
		missing = append(missing, "a prompt that says what Claude does")
	}
	if len(missing) > 0 {
		return fmt.Errorf("a recurring run needs %s: %w", strings.Join(missing, ", "), ErrInvalid)
	}
	if r.Kind != RecurringShape && r.Kind != RecurringChore {
		return fmt.Errorf("%q is not a kind of recurring run: use shape or chore: %w", r.Kind, ErrInvalid)
	}
	if r.IfAsleep != AsleepRunOnce && r.IfAsleep != AsleepSkip {
		return fmt.Errorf("%q is not a choice for a Mac that slept: use once or skip: %w", r.IfAsleep, ErrInvalid)
	}
	if _, _, err := clock(r.At); err != nil {
		return err
	}
	if len(r.Days) == 0 {
		return fmt.Errorf("a recurring run needs at least one day: %w", ErrInvalid)
	}
	for _, d := range r.Days {
		if !slices.Contains(weekdays, d) {
			return fmt.Errorf("%q is not a day: use %s: %w", d, strings.Join(weekdays, ", "), ErrInvalid)
		}
	}
	for _, c := range r.DoneWhen {
		if strings.TrimSpace(c.Name) == "" || strings.TrimSpace(c.Command) == "" {
			return fmt.Errorf("each Done when check needs a name and a command: %w", ErrInvalid)
		}
	}
	if r.MaxTries < 1 || r.MaxTries > MaxTriesLimit {
		return fmt.Errorf("a run has 1 to %d tries: %w", MaxTriesLimit, ErrInvalid)
	}
	return CheckEffort(r.Effort)
}

// clock reads a time of day, HH:MM.
func clock(at string) (hour, minute int, err error) {
	h, m, ok := strings.Cut(at, ":")
	hour, herr := strconv.Atoi(h)
	minute, merr := strconv.Atoi(m)
	if !ok || len(m) != 2 || herr != nil || merr != nil || hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, 0, fmt.Errorf("%q is not a time of day: use HH:MM, such as 06:30: %w", at, ErrInvalid)
	}
	return hour, minute, nil
}

// NextAfter returns the first time of the timetable after t, in the time
// zone of t.
func (r Recurring) NextAfter(t time.Time) time.Time {
	hour, minute, err := clock(r.At)
	if err != nil {
		return time.Time{}
	}
	// A day of the timetable comes within 8 days. The 8th covers a time
	// that is earlier today than t on the only day of the week.
	for i := range 8 {
		d := time.Date(t.Year(), t.Month(), t.Day()+i, hour, minute, 0, 0, t.Location())
		if d.After(t) && slices.Contains(r.Days, weekdays[d.Weekday()]) {
			return d
		}
	}
	return time.Time{}
}

// sortDays puts the days in the order of the week, once each.
func sortDays(days []string) []string {
	out := []string{}
	for _, d := range weekdays {
		if slices.Contains(days, d) {
			out = append(out, d)
		}
	}
	for _, d := range days {
		if !slices.Contains(weekdays, d) {
			out = append(out, d) // check() names it
		}
	}
	return out
}

// AddRecurring records a recurring run and gives it an ID. Its first time is
// the first time of its timetable after now.
func (s *Store) AddRecurring(r Recurring, now time.Time) (Recurring, error) {
	if r.MaxTries == 0 {
		r.MaxTries = DefaultMaxTries
	}
	if r.IfAsleep == "" {
		r.IfAsleep = AsleepRunOnce
	}
	if r.DoneWhen == nil {
		r.DoneWhen = []Check{}
	}
	r.Days = sortDays(r.Days)
	if err := r.check(); err != nil {
		return Recurring{}, err
	}
	tx, err := s.beginWrite()
	if err != nil {
		return Recurring{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, r.PlotID)
	if err != nil {
		return Recurring{}, err
	}
	if !ok {
		return Recurring{}, fmt.Errorf("plot %q: %w", r.PlotID, ErrNotFound)
	}
	r.ID, err = newID(func(id string) (bool, error) { return exists(tx.conn, `SELECT 1 FROM recurring WHERE id = ?`, id) })
	if err != nil {
		return Recurring{}, err
	}
	r.NextAt = tm(r.NextAfter(now).UnixMilli())
	r.CreatedAt = tm(now.UnixMilli())
	r.LastAt, r.LastNote, r.LastRunID = nil, "", ""
	checks, err := json.Marshal(r.DoneWhen)
	if err != nil {
		return Recurring{}, err
	}
	if err := tx.exec(`INSERT INTO recurring(`+recurringCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, '', '', ?)`,
		r.ID, r.PlotID, r.Title, r.Prompt, r.Kind, strings.Join(r.Days, ","), r.At, r.Precheck, r.IfAsleep, r.Repo,
		string(checks), r.MaxTries, r.Model, r.Effort, r.NextAt.UnixMilli(), r.CreatedAt.UnixMilli()); err != nil {
		return Recurring{}, err
	}
	return r, tx.commit()
}

// GetRecurring returns a recurring run by ID, or an error that wraps
// [ErrNotFound].
func (s *Store) GetRecurring(id string) (Recurring, error) {
	var r Recurring
	err := s.readTx(func(q queryer) error {
		var err error
		r, err = scanRecurring(q.QueryRowContext(context.Background(), `SELECT `+recurringCols+` FROM recurring WHERE id = ?`, id))
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("recurring run %q: %w", id, ErrNotFound)
		}
		return err
	})
	return r, err
}

// ListRecurring returns the recurring runs of a plot, or of every plot when
// plotID is empty, the next due first.
func (s *Store) ListRecurring(plotID string) ([]Recurring, error) {
	out := []Recurring{}
	query := `SELECT ` + recurringCols + ` FROM recurring`
	var args []any
	if plotID != "" {
		query += ` WHERE plot_id = ?`
		args = append(args, plotID)
	}
	query += ` ORDER BY next_at, created_at`
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			r, err := scanRecurring(rows)
			if err != nil {
				return err
			}
			out = append(out, r)
			return nil
		}, query, args...)
	})
	return out, err
}

// RemoveRecurring removes a recurring run. Its runs stay.
func (s *Store) RemoveRecurring(id string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM recurring WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("recurring run %q: %w", id, ErrNotFound)
	}
	if err := tx.exec(`DELETE FROM recurring WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.commit()
}

// ClaimRecurring moves the next time of a recurring run from due to next,
// and reports whether this call moved it. Two ticks at once both read the
// same due time, and only one of them claims it.
func (s *Store) ClaimRecurring(id string, due, next time.Time) (bool, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return false, err
	}
	defer tx.rollback()
	res, err := tx.conn.ExecContext(context.Background(), `UPDATE recurring SET next_at = ? WHERE id = ? AND next_at = ?`,
		next.UnixMilli(), id, due.UnixMilli())
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil || n == 0 {
		return false, err
	}
	return true, tx.commit()
}

// RecordRecurring keeps what a tick did with a recurring run: the run that
// it started, if any, and a note for you.
func (s *Store) RecordRecurring(id string, at time.Time, note, runID string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	if err := tx.exec(`UPDATE recurring SET last_at = ?, last_note = ?, last_run_id = ? WHERE id = ?`,
		at.UnixMilli(), note, runID, id); err != nil {
		return err
	}
	return tx.commit()
}

const recurringCols = `id, plot_id, title, prompt, kind, days, at, precheck, if_asleep, repo, done_when, max_tries, model, effort,
  next_at, last_at, last_note, last_run_id, created_at`

func scanRecurring(sc interface{ Scan(...any) error }) (Recurring, error) {
	var r Recurring
	var days, checks string
	var next, last, created int64
	err := sc.Scan(&r.ID, &r.PlotID, &r.Title, &r.Prompt, &r.Kind, &days, &r.At, &r.Precheck, &r.IfAsleep, &r.Repo,
		&checks, &r.MaxTries, &r.Model, &r.Effort, &next, &last, &r.LastNote, &r.LastRunID, &created)
	if err != nil {
		return Recurring{}, err
	}
	r.Days = strings.Split(days, ",")
	if err := json.Unmarshal([]byte(checks), &r.DoneWhen); err != nil {
		return Recurring{}, fmt.Errorf("recurring run %s: bad Done when checks: %w", r.ID, err)
	}
	r.NextAt, r.CreatedAt = tm(next), tm(created)
	if last != 0 {
		at := tm(last)
		r.LastAt = &at
	}
	return r, nil
}
