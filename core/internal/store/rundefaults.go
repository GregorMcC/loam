package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Efforts are the effort levels that Claude Code accepts, lowest first.
var Efforts = []string{"low", "medium", "high", "xhigh", "max"}

// CheckEffort returns an error that wraps [ErrInvalid] when effort is not a
// level that Claude Code accepts. Empty is fine: it means the Claude Code
// setting.
func CheckEffort(effort string) error {
	if effort == "" || slices.Contains(Efforts, effort) {
		return nil
	}
	return fmt.Errorf("%q is not an effort level: use %s: %w", effort, strings.Join(Efforts, ", "), ErrInvalid)
}

// RunDefaults are the model and the effort that a run of a plot uses when
// the run names none. Empty means the Claude Code setting. They are not in
// the change log, as rules and runs are not.
type RunDefaults struct {
	PlotID string `json:"plot_id"`
	Model  string `json:"model"`
	Effort string `json:"effort"`
}

// GetRunDefaults returns the run defaults of a plot. A plot that has none
// gets empty strings.
func (s *Store) GetRunDefaults(plotID string) (RunDefaults, error) {
	d := RunDefaults{PlotID: plotID}
	err := s.readTx(func(q queryer) error {
		err := q.QueryRowContext(context.Background(), `SELECT model, effort FROM run_defaults WHERE plot_id = ?`, plotID).
			Scan(&d.Model, &d.Effort)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	})
	return d, err
}

// SetRunDefaults replaces the run defaults of a plot.
func (s *Store) SetRunDefaults(d RunDefaults) (RunDefaults, error) {
	d.Model = strings.TrimSpace(d.Model)
	if err := CheckEffort(d.Effort); err != nil {
		return RunDefaults{}, err
	}
	tx, err := s.beginWrite()
	if err != nil {
		return RunDefaults{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, d.PlotID)
	if err != nil {
		return RunDefaults{}, err
	}
	if !ok {
		return RunDefaults{}, fmt.Errorf("plot %q: %w", d.PlotID, ErrNotFound)
	}
	if err := tx.exec(`INSERT INTO run_defaults(plot_id, model, effort, updated_at) VALUES (?, ?, ?, ?)
ON CONFLICT(plot_id) DO UPDATE SET model = excluded.model, effort = excluded.effort, updated_at = excluded.updated_at`,
		d.PlotID, d.Model, d.Effort, time.Now().UnixMilli()); err != nil {
		return RunDefaults{}, err
	}
	return d, tx.commit()
}
