package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// LinearUpdates are the switches for the updates that Loam makes to the
// Linear issue of a run. They hold for every plot. They are not in the change
// log, as runs are not.
type LinearUpdates struct {
	// InProgress moves the issue to In Progress when a run starts.
	InProgress bool `json:"in_progress"`
	// AttachPR attaches the PR to the issue when Loam opens it.
	AttachPR bool `json:"attach_pr"`
	// Done moves the issue to Done when a run lands.
	Done bool `json:"done"`
	// WalkthroughComment adds the walkthrough of the ship notes to the issue
	// as a comment when a run lands.
	WalkthroughComment bool `json:"walkthrough_comment"`
}

// DefaultLinearUpdates are the switches before you change one: every update
// is on except the walkthrough comment.
var DefaultLinearUpdates = LinearUpdates{InProgress: true, AttachPR: true, Done: true}

// GetLinearUpdates returns the switches, or [DefaultLinearUpdates] when you
// have changed none.
func (s *Store) GetLinearUpdates() (LinearUpdates, error) {
	u := DefaultLinearUpdates
	err := s.readTx(func(q queryer) error {
		err := q.QueryRowContext(context.Background(),
			`SELECT in_progress, attach_pr, done, walkthrough_comment FROM linear_updates WHERE id = 1`).
			Scan(&u.InProgress, &u.AttachPR, &u.Done, &u.WalkthroughComment)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	})
	return u, err
}

// SetLinearUpdates replaces the switches.
func (s *Store) SetLinearUpdates(u LinearUpdates) (LinearUpdates, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return LinearUpdates{}, err
	}
	defer tx.rollback()
	if err := tx.exec(`INSERT INTO linear_updates(id, in_progress, attach_pr, done, walkthrough_comment, updated_at)
VALUES (1, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET in_progress = excluded.in_progress, attach_pr = excluded.attach_pr, done = excluded.done,
  walkthrough_comment = excluded.walkthrough_comment, updated_at = excluded.updated_at`,
		u.InProgress, u.AttachPR, u.Done, u.WalkthroughComment, time.Now().UnixMilli()); err != nil {
		return LinearUpdates{}, err
	}
	return u, tx.commit()
}
