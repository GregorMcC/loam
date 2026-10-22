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
// the plot. Making or removing it is not a change in the change log. A goal
// edit is a change (see [OpSetGoal]).
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
	// Goal is one line that says what the worktree is for. It can be empty.
	Goal string `json:"goal"`
	// Link is the link that the work started from, or nil.
	Link *WorktreeLink `json:"link"`
	// Version is the ID of the change that last set the goal, or 0 when no
	// change has set it.
	Version int64 `json:"version"`
}

// WorktreeLink is the link that the work of a worktree started from. It
// belongs to the worktree, not to the plot's links, and it goes when the
// worktree goes.
type WorktreeLink struct {
	Target string `json:"target"`
	Label  string `json:"label"`
	// Key names the issue, such as "ENG-482", "#57", or "example/widgets#57"
	// (see [linkkind.IssueKey]). It is empty for a link that is not an issue.
	// The key of a GitHub issue depends on the origin of the repo when the
	// worktree was made, so the record keeps it.
	Key string `json:"key"`
	// LinkID is the ID of the plot link that the worktree copied. It is
	// empty for a URL that was given as it is.
	LinkID string `json:"link_id"`
}

// worktreeCols are the columns of a worktree record.
const worktreeCols = `id, plot_id, repo_path, name, branch, base, path, setup_done, created_at, goal, link_target, link_label, link_key, link_id`

// worktreeSelect reads worktreeCols and the version of the goal. Use it with
// FROM worktrees, with no alias.
const worktreeSelect = worktreeCols + `, (SELECT COALESCE(MAX(e.change_id), 0) FROM change_entries e
  WHERE e.plot_id = worktrees.plot_id AND e.item = '` + worktreePrefix + `' || worktrees.id)`

func scanWorktree(sc interface{ Scan(...any) error }) (Worktree, error) {
	var w Worktree
	var created int64
	var l WorktreeLink
	err := sc.Scan(&w.ID, &w.PlotID, &w.Repo, &w.Name, &w.Branch, &w.Base, &w.Path, &w.SetupDone, &created,
		&w.Goal, &l.Target, &l.Label, &l.Key, &l.LinkID, &w.Version)
	w.CreatedAt = tm(created)
	if l.Target != "" {
		w.Link = &l
	}
	return w, err
}

// AddWorktree records a worktree and gives it an ID. The name must be new for
// the plot and the repo, and the path must be new. The record keeps the goal
// and the link of w. It is not a change, so the goal starts at version 0.
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
	// A link with no target is no link.
	var l WorktreeLink
	if w.Link != nil && w.Link.Target != "" {
		l = *w.Link
	}
	now := time.Now().UnixMilli()
	if err := tx.exec(`INSERT INTO worktrees(`+worktreeCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)`,
		w.ID, w.PlotID, w.Repo, w.Name, w.Branch, w.Base, w.Path, now, w.Goal, l.Target, l.Label, l.Key, l.LinkID); err != nil {
		return Worktree{}, err
	}
	w.SetupDone, w.CreatedAt, w.Link, w.Version = false, tm(now), nil, 0
	if l.Target != "" {
		w.Link = &l
	}
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
		w, err = scanWorktree(q.QueryRowContext(context.Background(), `SELECT `+worktreeSelect+` FROM worktrees WHERE `+where, arg))
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
		}, `SELECT `+worktreeSelect+` FROM worktrees WHERE ? = '' OR plot_id = ? ORDER BY created_at, rowid`, plotID, plotID)
	})
	return out, err
}

// MarkWorktreeSetup records that the setup command has succeeded in a worktree.
func (s *Store) MarkWorktreeSetup(id string) error {
	return s.writeWorktree(id, `UPDATE worktrees SET setup_done = 1 WHERE id = ?`)
}

// RemoveWorktree deletes the record of a worktree and the PR cache row of its
// branch. It does not touch git.
func (s *Store) RemoveWorktree(id string) error {
	return s.writeWorktree(id, `DELETE FROM worktrees WHERE id = ?`,
		`DELETE FROM pr_cache WHERE (repo_path, branch) IN (SELECT repo_path, branch FROM worktrees WHERE id = ?)`)
}

// writeWorktree runs query on the record of a worktree in one write, after
// the queries in before. Each query takes the worktree ID. When query changes
// no row, the write fails with [ErrNotFound].
func (s *Store) writeWorktree(id, query string, before ...string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	for _, q := range before {
		if err := tx.exec(q, id); err != nil {
			return err
		}
	}
	res, err := tx.conn.ExecContext(context.Background(), query, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("worktree %q: %w", id, ErrNotFound)
	}
	return tx.commit()
}
