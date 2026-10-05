package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ListChanges reads the change log. See [ChangeQuery].
func (s *Store) ListChanges(cq ChangeQuery) ([]ChangeRecord, error) {
	rest := `id > ?`
	args := []any{cq.SinceID}
	if cq.PlotID != "" {
		rest += ` AND plot_id = ?`
		args = append(args, cq.PlotID)
	}
	if cq.Newest {
		rest += ` ORDER BY id DESC`
	} else {
		rest += ` ORDER BY id`
	}
	if cq.Limit > 0 {
		rest += fmt.Sprintf(` LIMIT %d`, cq.Limit)
	}
	out := []ChangeRecord{}
	err := s.readTx(func(q queryer) (err error) {
		out, err = loadChanges(q, rest, args...)
		return err
	})
	return out, err
}

// AddSession records a session that Loam started. If the session ID is
// already recorded for the same plot, it does nothing, so a restart is safe.
// If the ID belongs to another plot, it returns ErrDuplicate.
func (s *Store) AddSession(r SessionRecord) error {
	if r.SessionID == "" || r.PlotID == "" {
		return fmt.Errorf("a session record needs a session ID and a plot ID: %w", ErrInvalid)
	}
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	ok, err := exists(w.conn, `SELECT 1 FROM plots WHERE id = ?`, r.PlotID)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("plot %q: %w", r.PlotID, ErrNotFound)
	}
	if err := w.exec(`INSERT INTO sessions(session_id, plot_id, start_folder, created_at) VALUES (?, ?, ?, ?)
ON CONFLICT(session_id) DO NOTHING`, r.SessionID, r.PlotID, r.StartFolder, time.Now().UnixMilli()); err != nil {
		return err
	}
	var plot string
	if err := w.conn.QueryRowContext(context.Background(), `SELECT plot_id FROM sessions WHERE session_id = ?`, r.SessionID).Scan(&plot); err != nil {
		return err
	}
	if plot != r.PlotID {
		return fmt.Errorf("session %q belongs to another plot: %w", r.SessionID, ErrDuplicate)
	}
	return w.commit()
}

// GetSession returns a session record, or an error that wraps [ErrNotFound].
func (s *Store) GetSession(sessionID string) (SessionRecord, error) {
	var r SessionRecord
	var created int64
	err := s.readTx(func(q queryer) error {
		return q.QueryRowContext(context.Background(), `SELECT session_id, plot_id, start_folder, created_at FROM sessions WHERE session_id = ?`, sessionID).
			Scan(&r.SessionID, &r.PlotID, &r.StartFolder, &created)
	})
	if errors.Is(err, sql.ErrNoRows) {
		return r, fmt.Errorf("session %q: %w", sessionID, ErrNotFound)
	}
	r.CreatedAt = tm(created)
	return r, err
}

// ListSessions returns the session records of a plot, oldest first. An empty
// plotID returns every record.
func (s *Store) ListSessions(plotID string) ([]SessionRecord, error) {
	out := []SessionRecord{}
	err := s.readTx(func(q queryer) (err error) {
		out, err = loadSessions(q, `? = '' OR plot_id = ?`, plotID, plotID)
		return err
	})
	return out, err
}

// loadSessions reads the session records that match a SQL condition, oldest first.
func loadSessions(q queryer, where string, args ...any) ([]SessionRecord, error) {
	out := []SessionRecord{}
	err := scanRows(q, func(rows *sql.Rows) error {
		var r SessionRecord
		var created int64
		if err := rows.Scan(&r.SessionID, &r.PlotID, &r.StartFolder, &created); err != nil {
			return err
		}
		r.CreatedAt = tm(created)
		out = append(out, r)
		return nil
	}, `SELECT session_id, plot_id, start_folder, created_at FROM sessions WHERE `+where+` ORDER BY created_at, rowid`, args...)
	return out, err
}

// IsSeeded reports whether Loam started the session: its ID is in the records.
func (s *Store) IsSeeded(sessionID string) (bool, error) {
	ok := false
	err := s.readTx(func(q queryer) (err error) {
		ok, err = exists(q, `SELECT 1 FROM sessions WHERE session_id = ?`, sessionID)
		return err
	})
	return ok, err
}

// SessionActor returns the actor for a session ID, with LoamStarted set from
// the session records. It returns an error if the lookup fails, so a caller
// never logs a wrong LoamStarted value.
func (s *Store) SessionActor(sessionID string) (Actor, error) {
	started, err := s.IsSeeded(sessionID)
	if err != nil {
		return Actor{}, err
	}
	return Actor{Kind: ActorSession, SessionID: sessionID, LoamStarted: started}, nil
}

// SetPIDSession records the current session ID for a Claude Code process ID.
// `loam hook` calls it on each SessionStart, so a server that outlives /clear
// can find its session. A later call for the same PID replaces the record.
func (s *Store) SetPIDSession(pid int, sessionID string) error {
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	if err := w.exec(`INSERT INTO session_pids(pid, session_id, updated_at) VALUES (?, ?, ?)
ON CONFLICT(pid) DO UPDATE SET session_id = excluded.session_id, updated_at = excluded.updated_at`, pid, sessionID, time.Now().UnixMilli()); err != nil {
		return err
	}
	return w.commit()
}

// SessionForPID returns the session ID last recorded for a process ID.
func (s *Store) SessionForPID(pid int) (string, bool, error) {
	var id string
	err := s.readTx(func(q queryer) error {
		return q.QueryRowContext(context.Background(), `SELECT session_id FROM session_pids WHERE pid = ?`, pid).Scan(&id)
	})
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return id, err == nil, err
}
