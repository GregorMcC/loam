package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"time"
)

// RepoSettings are the worktree settings of one repo path: a setup command
// and the files to copy into each new worktree. Every plot that holds the
// path shares them. A change to them is not a change in the change log.
type RepoSettings struct {
	Setup string   `json:"setup,omitempty"`
	Copy  []string `json:"copy,omitempty"`
	// SetupApproved is the setup command that you last approved. A setup
	// command runs with no question only when it is equal to Setup.
	SetupApproved string `json:"-"`
}

func decodeCopy(s string) []string {
	var out []string
	if err := json.Unmarshal([]byte(s), &out); err != nil || len(out) == 0 {
		return nil
	}
	return out
}

// RepoSettings returns the settings of a repo path. A path with no record has
// empty settings.
func (s *Store) RepoSettings(path string) (RepoSettings, error) {
	var out RepoSettings
	err := s.readTx(func(q queryer) error {
		var copyJSON string
		err := q.QueryRowContext(context.Background(), `SELECT setup, copy, setup_approved FROM repo_settings WHERE path = ?`, filepath.Clean(path)).Scan(&out.Setup, &copyJSON, &out.SetupApproved)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		out.Copy = decodeCopy(copyJSON)
		return err
	})
	return out, err
}

// ApproveSetup records cmd as the approved setup command of a repo path. The
// path must be absolute.
func (s *Store) ApproveSetup(path, cmd string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("a repo path must be absolute: %w", ErrInvalid)
	}
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	if err := w.exec(`INSERT INTO repo_settings(path, setup_approved) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET setup_approved = excluded.setup_approved`, filepath.Clean(path), cmd); err != nil {
		return err
	}
	return w.commit()
}

// SetRepoSettings sets the setup command and the files to copy of a repo
// path. A nil argument keeps the stored value. An empty value clears it. The
// path must be absolute.
func (s *Store) SetRepoSettings(path string, setup *string, copyFiles *[]string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("a repo path must be absolute: %w", ErrInvalid)
	}
	path = filepath.Clean(path)
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	if err := w.exec(`INSERT INTO repo_settings(path) VALUES (?) ON CONFLICT(path) DO NOTHING`, path); err != nil {
		return err
	}
	if setup != nil {
		if err := w.exec(`UPDATE repo_settings SET setup = ? WHERE path = ?`, *setup, path); err != nil {
			return err
		}
	}
	if copyFiles != nil {
		b, err := json.Marshal(append([]string{}, *copyFiles...))
		if err != nil {
			return err
		}
		if err := w.exec(`UPDATE repo_settings SET copy = ? WHERE path = ?`, string(b), path); err != nil {
			return err
		}
	}
	return w.commit()
}

// Worktree is a git worktree that Loam made for a plot. It covers one repo of
// the plot. It is not a change in the change log.
type Worktree struct {
	ID     string `json:"id"`
	PlotID string `json:"plot_id"`
	// Repo is the path of the repo that the worktree belongs to.
	Repo string `json:"repo"`
	// Name is the name that the person gave. It is the branch name.
	Name   string `json:"name"`
	Branch string `json:"branch"`
	// Base is the branch that a new branch started from, such as origin/main.
	// It is empty when the worktree uses a branch that already existed.
	Base string `json:"base"`
	Path string `json:"path"`
	// SetupDone is true after the setup command has succeeded in the worktree.
	SetupDone bool      `json:"setup_done"`
	CreatedAt time.Time `json:"created_at"`
}

const worktreeCols = `id, plot_id, repo_path, name, branch, base, path, setup_done, created_at`

func scanWorktree(sc interface{ Scan(...any) error }) (Worktree, error) {
	var w Worktree
	var created int64
	err := sc.Scan(&w.ID, &w.PlotID, &w.Repo, &w.Name, &w.Branch, &w.Base, &w.Path, &w.SetupDone, &created)
	w.CreatedAt = tm(created)
	return w, err
}

// AddWorktree records a worktree and gives it an ID. The name must be new for
// the plot and the repo, and the path must be new.
func (s *Store) AddWorktree(w Worktree) (Worktree, error) {
	if w.PlotID == "" || w.Repo == "" || w.Name == "" || w.Branch == "" || w.Path == "" {
		return Worktree{}, fmt.Errorf("a worktree record needs a plot, repo, name, branch, and path: %w", ErrInvalid)
	}
	tx, err := s.beginWrite()
	if err != nil {
		return Worktree{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, w.PlotID)
	if err != nil {
		return Worktree{}, err
	}
	if !ok {
		return Worktree{}, fmt.Errorf("plot %q: %w", w.PlotID, ErrNotFound)
	}
	dup, err := exists(tx.conn, `SELECT 1 FROM worktrees WHERE (plot_id = ? AND repo_path = ? AND name = ?) OR path = ?`, w.PlotID, w.Repo, w.Name, w.Path)
	if err != nil {
		return Worktree{}, err
	}
	if dup {
		return Worktree{}, fmt.Errorf("the plot already has a worktree %q for this repo, or one at %s: %w", w.Name, w.Path, ErrDuplicate)
	}
	w.ID, err = newID(func(id string) (bool, error) { return exists(tx.conn, `SELECT 1 FROM worktrees WHERE id = ?`, id) })
	if err != nil {
		return Worktree{}, err
	}
	now := time.Now().UnixMilli()
	if err := tx.exec(`INSERT INTO worktrees(`+worktreeCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)`,
		w.ID, w.PlotID, w.Repo, w.Name, w.Branch, w.Base, w.Path, now); err != nil {
		return Worktree{}, err
	}
	w.SetupDone, w.CreatedAt = false, tm(now)
	return w, tx.commit()
}

// GetWorktree returns a worktree by ID, or an error that wraps [ErrNotFound].
func (s *Store) GetWorktree(id string) (Worktree, error) {
	return s.oneWorktree(`id = ?`, id)
}

// WorktreeByPath returns the worktree at a folder, or an error that wraps
// [ErrNotFound].
func (s *Store) WorktreeByPath(path string) (Worktree, error) {
	return s.oneWorktree(`path = ?`, filepath.Clean(path))
}

func (s *Store) oneWorktree(where string, arg any) (Worktree, error) {
	var w Worktree
	err := s.readTx(func(q queryer) (err error) {
		w, err = scanWorktree(q.QueryRowContext(context.Background(), `SELECT `+worktreeCols+` FROM worktrees WHERE `+where, arg))
		return err
	})
	if errors.Is(err, sql.ErrNoRows) {
		return Worktree{}, fmt.Errorf("worktree: %w", ErrNotFound)
	}
	return w, err
}

// ListWorktrees returns the worktrees of a plot, oldest first. An empty
// plotID returns every worktree.
func (s *Store) ListWorktrees(plotID string) ([]Worktree, error) {
	out := []Worktree{}
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			w, err := scanWorktree(rows)
			if err != nil {
				return err
			}
			out = append(out, w)
			return nil
		}, `SELECT `+worktreeCols+` FROM worktrees WHERE ? = '' OR plot_id = ? ORDER BY created_at, rowid`, plotID, plotID)
	})
	return out, err
}

// MarkWorktreeSetup records that the setup command has succeeded in a worktree.
func (s *Store) MarkWorktreeSetup(id string) error {
	return s.writeWorktree(id, `UPDATE worktrees SET setup_done = 1 WHERE id = ?`)
}

// RemoveWorktree deletes the record of a worktree. It does not touch git.
func (s *Store) RemoveWorktree(id string) error {
	return s.writeWorktree(id, `DELETE FROM worktrees WHERE id = ?`)
}

func (s *Store) writeWorktree(id, query string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	res, err := tx.conn.ExecContext(context.Background(), query, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("worktree %q: %w", id, ErrNotFound)
	}
	return tx.commit()
}
