package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// FilterPlots keeps the plots whose archived flag equals archived. The order
// stays.
func FilterPlots(plots []PlotSummary, archived bool) []PlotSummary {
	out := []PlotSummary{}
	for _, p := range plots {
		if p.Archived == archived {
			out = append(out, p)
		}
	}
	return out
}

// SetArchived sets the archived flag of a plot. The plot keeps its place in
// the plot order, so unarchive puts it back where it was. The flag is not a
// change: it has no change log entry and no undo. Setting the flag to its
// current value does nothing. An unknown plot wraps [ErrNotFound].
func (s *Store) SetArchived(id string, archived bool) error {
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	res, err := w.conn.ExecContext(context.Background(), `UPDATE plots SET archived = ? WHERE id = ?`, archived, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("plot %q: %w", id, ErrNotFound)
	}
	return w.commit()
}

// DeletePlot removes an archived plot that has no worktrees: the plot, its
// links and repos, its change log, its session records, and the repo settings
// that no other plot uses. It returns the session records that it removed. It
// does not touch the plot folder. An unknown plot wraps [ErrNotFound], a plot
// that is not archived wraps [ErrNotArchived], and a plot with worktrees wraps
// [ErrHasWorktrees]. The checks and the delete run in one transaction.
func (s *Store) DeletePlot(id string) ([]SessionRecord, error) {
	w, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer w.rollback()
	ctx := context.Background()

	var archived bool
	err = w.conn.QueryRowContext(ctx, `SELECT archived FROM plots WHERE id = ?`, id).Scan(&archived)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("plot %q: %w", id, ErrNotFound)
	}
	if err != nil {
		return nil, err
	}
	if !archived {
		return nil, fmt.Errorf("plot %q: %w", id, ErrNotArchived)
	}
	var worktrees int
	if err := w.conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM worktrees WHERE plot_id = ?`, id).Scan(&worktrees); err != nil {
		return nil, err
	}
	if worktrees > 0 {
		return nil, fmt.Errorf("plot %q has %d worktrees: %w", id, worktrees, ErrHasWorktrees)
	}

	recs, err := loadSessions(w.conn, `plot_id = ?`, id)
	if err != nil {
		return nil, err
	}

	// Repo settings belong to a path. Keep them while another plot holds the path.
	if err := w.exec(`DELETE FROM repo_settings WHERE path IN (SELECT path FROM repos WHERE plot_id = ?)
  AND path NOT IN (SELECT path FROM repos WHERE plot_id <> ?)
  AND path NOT IN (SELECT repo_path FROM worktrees WHERE plot_id <> ?)`, id, id, id); err != nil {
		return nil, err
	}
	for _, q := range []string{
		`DELETE FROM session_pids WHERE session_id IN (SELECT session_id FROM sessions WHERE plot_id = ?)`,
		`DELETE FROM sessions WHERE plot_id = ?`,
		`DELETE FROM change_entries WHERE plot_id = ?`,
		`DELETE FROM changes WHERE plot_id = ?`,
		`DELETE FROM links WHERE plot_id = ?`,
		`DELETE FROM repos WHERE plot_id = ?`,
		`DELETE FROM plot_order WHERE plot_id = ?`,
		`DELETE FROM plots WHERE id = ?`,
	} {
		if err := w.exec(q, id); err != nil {
			return nil, err
		}
	}
	if err := w.commit(); err != nil {
		return nil, err
	}
	return recs, nil
}
