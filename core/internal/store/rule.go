package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Rule is a check that every run of a plot must pass (ticket 209), such as
// "Views use the colour tokens". It often comes from a note that you sent
// back on two runs. The gate runs it after the Done when checks of a run. It
// is kept in the store, outside the worktree, so a run can run it but not
// change it. A rule is not in the change log, as runs are not.
type Rule struct {
	ID      string `json:"id"`
	PlotID  string `json:"plot_id"`
	Name    string `json:"name"`
	Command string `json:"command"`
	// Note is the note that the rule came from, or empty.
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"created_at"`
}

// Check is the rule as a check of the gate. Its name says that it is a rule.
func (r Rule) Check() Check { return Check{Name: "Rule: " + r.Name, Command: r.Command} }

// AddRule records a rule of a plot and gives it an ID.
func (s *Store) AddRule(r Rule) (Rule, error) {
	r.Name, r.Command, r.Note = strings.TrimSpace(r.Name), strings.TrimSpace(r.Command), strings.TrimSpace(r.Note)
	if r.Name == "" || r.Command == "" {
		return Rule{}, fmt.Errorf("a rule needs a name and a command: %w", ErrInvalid)
	}
	tx, err := s.beginWrite()
	if err != nil {
		return Rule{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, r.PlotID)
	if err != nil {
		return Rule{}, err
	}
	if !ok {
		return Rule{}, fmt.Errorf("plot %q: %w", r.PlotID, ErrNotFound)
	}
	r.ID, err = newID(func(id string) (bool, error) { return exists(tx.conn, `SELECT 1 FROM rules WHERE id = ?`, id) })
	if err != nil {
		return Rule{}, err
	}
	now := time.Now().UnixMilli()
	r.CreatedAt = tm(now)
	if err := tx.exec(`INSERT INTO rules(`+ruleCols+`) VALUES (?, ?, ?, ?, ?, ?)`,
		r.ID, r.PlotID, r.Name, r.Command, r.Note, now); err != nil {
		return Rule{}, err
	}
	return r, tx.commit()
}

// GetRule returns a rule by ID, or an error that wraps [ErrNotFound].
func (s *Store) GetRule(id string) (Rule, error) {
	var r Rule
	err := s.readTx(func(q queryer) error {
		var err error
		r, err = scanRule(q.QueryRowContext(context.Background(), `SELECT `+ruleCols+` FROM rules WHERE id = ?`, id))
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("rule %q: %w", id, ErrNotFound)
		}
		return err
	})
	return r, err
}

// ListRules returns the rules of a plot, or of every plot when plotID is
// empty, oldest first.
func (s *Store) ListRules(plotID string) ([]Rule, error) {
	out := []Rule{}
	query := `SELECT ` + ruleCols + ` FROM rules`
	var args []any
	if plotID != "" {
		query += ` WHERE plot_id = ?`
		args = append(args, plotID)
	}
	query += ` ORDER BY created_at, rowid`
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			r, err := scanRule(rows)
			if err != nil {
				return err
			}
			out = append(out, r)
			return nil
		}, query, args...)
	})
	return out, err
}

// RemoveRule removes a rule. The gate of each run stops running it.
func (s *Store) RemoveRule(id string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM rules WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("rule %q: %w", id, ErrNotFound)
	}
	if err := tx.exec(`DELETE FROM rules WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.commit()
}

const ruleCols = `id, plot_id, name, command, note, created_at`

func scanRule(sc interface{ Scan(...any) error }) (Rule, error) {
	var r Rule
	var created int64
	if err := sc.Scan(&r.ID, &r.PlotID, &r.Name, &r.Command, &r.Note, &created); err != nil {
		return Rule{}, err
	}
	r.CreatedAt = tm(created)
	return r, nil
}
