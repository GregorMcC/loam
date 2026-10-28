package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

// The run limits that a store with no row has, and the most runs at a time.
const (
	DefaultAtATime  = 3
	AtATimeLimit    = 20
	DefaultMaxTurns = 40
	DefaultHoldAt   = 80
)

// RunLimits are the limits of every run. There is one set for the store.
// They are not in the change log, as runs are not.
type RunLimits struct {
	// AtATime is how many runs can hold a slot at once: 1 to 20. A run that
	// finds no free slot waits in Queued.
	AtATime int `json:"at_a_time"`
	// MaxTurns is how many turns a run can take before it stops. 0 means no
	// limit.
	MaxTurns int `json:"max_turns"`
	// HoldAt is the percent of the 7-day usage at which new runs wait in
	// Queued: 0 to 100. 0 means no hold.
	HoldAt int `json:"hold_at"`
}

// DefaultRunLimits are the limits of a store that has no row.
func DefaultRunLimits() RunLimits {
	return RunLimits{AtATime: DefaultAtATime, MaxTurns: DefaultMaxTurns, HoldAt: DefaultHoldAt}
}

func (l RunLimits) check() error {
	switch {
	case l.AtATime < 1 || l.AtATime > AtATimeLimit:
		return fmt.Errorf("at a time is 1 to %d runs, not %d: %w", AtATimeLimit, l.AtATime, ErrInvalid)
	case l.MaxTurns < 0:
		return fmt.Errorf("max turns is 0 (no limit) or more, not %d: %w", l.MaxTurns, ErrInvalid)
	case l.HoldAt < 0 || l.HoldAt > 100:
		return fmt.Errorf("hold at is a percent from 0 (off) to 100, not %d: %w", l.HoldAt, ErrInvalid)
	}
	return nil
}

// GetRunLimits returns the run limits, or [DefaultRunLimits] when none are
// set.
func (s *Store) GetRunLimits() (RunLimits, error) {
	var l RunLimits
	err := s.readTx(func(q queryer) error {
		var err error
		l, err = loadRunLimits(q)
		return err
	})
	return l, err
}

func loadRunLimits(q queryer) (RunLimits, error) {
	l := DefaultRunLimits()
	err := q.QueryRowContext(context.Background(), `SELECT at_a_time, max_turns, hold_at FROM run_limits WHERE id = 1`).
		Scan(&l.AtATime, &l.MaxTurns, &l.HoldAt)
	if errors.Is(err, sql.ErrNoRows) {
		return DefaultRunLimits(), nil
	}
	return l, err
}

// SetRunLimits replaces the run limits. A value out of range wraps
// [ErrInvalid]. Runs that hold a slot keep it when AtATime goes down.
func (s *Store) SetRunLimits(l RunLimits) (RunLimits, error) {
	if err := l.check(); err != nil {
		return RunLimits{}, err
	}
	tx, err := s.beginWrite()
	if err != nil {
		return RunLimits{}, err
	}
	defer tx.rollback()
	if err := tx.exec(`INSERT INTO run_limits(id, at_a_time, max_turns, hold_at, updated_at) VALUES (1, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET at_a_time = excluded.at_a_time, max_turns = excluded.max_turns, hold_at = excluded.hold_at,
  updated_at = excluded.updated_at`,
		l.AtATime, l.MaxTurns, l.HoldAt, time.Now().UnixMilli()); err != nil {
		return RunLimits{}, err
	}
	return l, tx.commit()
}

// UsageWindow is the usage of one window of Claude Code's limits.
type UsageWindow struct {
	// Utilization is the share of the window that is used: 0 to 1.
	Utilization float64 `json:"utilization"`
	// ResetsAt is when the window starts again.
	ResetsAt time.Time `json:"resets_at"`
}

// Usage is the last usage that Claude Code reported to Loam. A window is nil
// while Claude Code has not reported it. ReadAt is when Loam read it, or nil
// before the first time.
type Usage struct {
	FiveHour *UsageWindow `json:"five_hour"`
	SevenDay *UsageWindow `json:"seven_day"`
	ReadAt   *time.Time   `json:"read_at"`
}

// WeekPercent returns the 7-day utilization as a percent, and false when it
// is not known at now: Claude Code never reported it, or its window has
// started again since.
func (u Usage) WeekPercent(now time.Time) (float64, bool) {
	if u.SevenDay == nil || !u.SevenDay.ResetsAt.After(now) {
		return 0, false
	}
	return u.SevenDay.Utilization * 100, true
}

// GetUsage returns the last usage that Claude Code reported. Before the
// first report, both windows and ReadAt are nil.
func (s *Store) GetUsage() (Usage, error) {
	var u Usage
	err := s.readTx(func(q queryer) error {
		var err error
		u, err = loadUsage(q)
		return err
	})
	return u, err
}

func loadUsage(q queryer) (Usage, error) {
	var five, seven sql.NullFloat64
	var fiveAt, sevenAt sql.NullInt64
	var readAt int64
	err := q.QueryRowContext(context.Background(), `SELECT five_hour, five_hour_resets_at, seven_day, seven_day_resets_at, read_at FROM usage WHERE id = 1`).
		Scan(&five, &fiveAt, &seven, &sevenAt, &readAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Usage{}, nil
	}
	if err != nil {
		return Usage{}, err
	}
	window := func(v sql.NullFloat64, at sql.NullInt64) *UsageWindow {
		if !v.Valid {
			return nil
		}
		return &UsageWindow{Utilization: v.Float64, ResetsAt: tm(at.Int64)}
	}
	u := Usage{FiveHour: window(five, fiveAt), SevenDay: window(seven, sevenAt)}
	if readAt > 0 { // 0 is a row that a probe made before the first report
		read := tm(readAt)
		u.ReadAt = &read
	}
	return u, nil
}

// ClaimUsageProbe records now as the time of a probe of the usage and
// returns true, when no probe was tried in the span before now. Else it
// writes nothing and returns false. The caller probes only on true, so
// separate processes probe at most once in each span, whether the probes
// work or not. A time after now, from a clock that went back, does not
// count.
func (s *Store) ClaimUsageProbe(now time.Time, span time.Duration) (bool, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return false, err
	}
	defer tx.rollback()
	var tried int64
	err = tx.conn.QueryRowContext(context.Background(), `SELECT tried_at FROM usage WHERE id = 1`).Scan(&tried)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if at := tm(tried); tried > 0 && now.Sub(at) < span && !at.After(now) {
		return false, nil
	}
	if err := tx.exec(`INSERT INTO usage(id, read_at, tried_at) VALUES (1, 0, ?)
ON CONFLICT(id) DO UPDATE SET tried_at = excluded.tried_at`, now.UnixMilli()); err != nil {
		return false, err
	}
	return true, tx.commit()
}

// RecordUsage records what Claude Code reported at now. A window that u has
// replaces the stored one, and a window that u does not have stays.
func (s *Store) RecordUsage(u Usage, now time.Time) (Usage, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return Usage{}, err
	}
	defer tx.rollback()
	old, err := loadUsage(tx.conn)
	if err != nil {
		return Usage{}, err
	}
	if u.FiveHour == nil {
		u.FiveHour = old.FiveHour
	}
	if u.SevenDay == nil {
		u.SevenDay = old.SevenDay
	}
	now = tm(now.UnixMilli()) // as the store keeps it
	u.ReadAt = &now
	cols := func(w *UsageWindow) (any, any) {
		if w == nil {
			return nil, nil
		}
		return w.Utilization, w.ResetsAt.UnixMilli()
	}
	five, fiveAt := cols(u.FiveHour)
	seven, sevenAt := cols(u.SevenDay)
	if err := tx.exec(`INSERT INTO usage(id, five_hour, five_hour_resets_at, seven_day, seven_day_resets_at, read_at) VALUES (1, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET five_hour = excluded.five_hour, five_hour_resets_at = excluded.five_hour_resets_at,
  seven_day = excluded.seven_day, seven_day_resets_at = excluded.seven_day_resets_at, read_at = excluded.read_at`,
		five, fiveAt, seven, sevenAt, now.UnixMilli()); err != nil {
		return Usage{}, err
	}
	return u, tx.commit()
}

// TakeSlot calls fn on the run, as [Store.UpdateRun] does, and checks the
// slot of a run that fn starts, in the same write. When fn leaves the run in
// a state that holds a slot (see [RunState.HoldsSlot]), and the run limits
// or the week's usage hold it, the run goes to Queued instead. Its note says
// why, and its queue is q, or the queue that it has when q is nil. A try
// that fn counts keeps the note of fn in its event. A run that leaves Queued
// keeps no queue. The caller starts the session only when the run that comes
// back holds a slot.
func (s *Store) TakeSlot(id string, q *RunQueue, fn func(*Run) error) (Run, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return Run{}, err
	}
	defer tx.rollback()
	hold, err := holdNote(tx.conn, id, time.Now())
	if err != nil {
		return Run{}, err
	}
	tryNote := ""
	r, err := updateRun(tx, id, func(r *Run) error {
		if err := fn(r); err != nil {
			return err
		}
		switch {
		case r.State.HoldsSlot() && hold != "":
			tryNote = r.Note
			r.State, r.Note = RunQueued, hold
			if q != nil {
				r.Queue = q
			}
		case r.State != RunQueued:
			r.Queue = nil
		}
		return nil
	}, &tryNote)
	if err != nil {
		return Run{}, err
	}
	return r, tx.commit()
}

// SlotHold says why the run id cannot start its session now, or "" when it
// can, as [Store.TakeSlot] would decide. It writes nothing.
func (s *Store) SlotHold(id string) (string, error) {
	var note string
	err := s.readTx(func(q queryer) error {
		var err error
		note, err = holdNote(q, id, time.Now())
		return err
	})
	return note, err
}

// holdNote says why the run id cannot start its session at now, or "" when
// it can. The week's usage at or over the hold comes first, because a free
// slot does not help it. Then every slot is taken by other runs.
func holdNote(q queryer, id string, now time.Time) (string, error) {
	l, err := loadRunLimits(q)
	if err != nil {
		return "", err
	}
	if l.HoldAt > 0 {
		u, err := loadUsage(q)
		if err != nil {
			return "", err
		}
		if pct, ok := u.WeekPercent(now); ok && pct >= float64(l.HoldAt) {
			return HeldNote(pct, l.HoldAt), nil
		}
	}
	args, marks := []any{id}, []string{}
	for _, st := range runStates {
		if st.HoldsSlot() {
			args, marks = append(args, st), append(marks, "?")
		}
	}
	var holding int
	if err := q.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM runs WHERE id != ? AND state IN (`+strings.Join(marks, ", ")+`)`, args...).
		Scan(&holding); err != nil {
		return "", err
	}
	switch {
	case holding == l.AtATime:
		return fmt.Sprintf("Waits for a slot: %d of %d runs are running", holding, l.AtATime), nil
	case holding > l.AtATime: // the limit went down while runs held slots
		return fmt.Sprintf("Waits for a slot: %d runs are running, over the limit of %d", holding, l.AtATime), nil
	}
	return "", nil
}

// HeldNote is the note of a run that the week's usage holds, such as "Held:
// the week's usage is at 82%, over the 80% limit".
func HeldNote(pct float64, holdAt int) string {
	at := int(math.Round(pct))
	if at <= holdAt {
		return fmt.Sprintf("Held: the week's usage is at %d%%, the limit", at)
	}
	return fmt.Sprintf("Held: the week's usage is at %d%%, over the %d%% limit", at, holdAt)
}
