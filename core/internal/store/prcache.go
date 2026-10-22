package store

import (
	"database/sql"
	"time"
)

// PRKey names one branch of one repo path in the PR cache.
type PRKey struct {
	Repo   string
	Branch string
}

// PRState is one row of the PR cache: what Loam last learned from GitHub
// about the pull request of a branch. The cache is not in the change log,
// and its writes do not rewrite the changed marker (see
// [Store.beginUnmarkedWrite]).
type PRState struct {
	PRKey
	// Data is the cached state as JSON. The worktree package owns its shape.
	// It is empty when GitHub never answered for the branch.
	Data string
	// CheckedAt is when Data came from GitHub. It is zero when GitHub never answered.
	CheckedAt time.Time
	// Note says why the last refresh did not get an answer. It is empty
	// after a refresh that did.
	Note string
}

// PRStates returns every row of the PR cache.
func (s *Store) PRStates() (map[PRKey]PRState, error) {
	out := map[PRKey]PRState{}
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			var r PRState
			var at int64
			if err := rows.Scan(&r.Repo, &r.Branch, &r.Data, &at, &r.Note); err != nil {
				return err
			}
			if at != 0 {
				r.CheckedAt = tm(at)
			}
			out[r.PRKey] = r
			return nil
		}, `SELECT repo_path, branch, data, checked_at, note FROM pr_cache`)
	})
	return out, err
}

// hasWorktree is the condition of a PR cache write: a worktree has the repo
// path and the branch. A refresh reads the worktrees, asks GitHub, then
// writes. `loam worktree rm` can remove a worktree in that time. Then the
// write skips its row, in the same transaction as the check, so the cache
// keeps no row that RemoveWorktree cleared.
const hasWorktree = `EXISTS (SELECT 1 FROM worktrees WHERE repo_path = ? AND branch = ?)`

// SavePRStates writes whole rows of the PR cache in one write: the data,
// its time, and the note. It skips a row whose worktree is gone.
func (s *Store) SavePRStates(rows []PRState) error {
	w, err := s.beginUnmarkedWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	for _, r := range rows {
		var at int64
		if !r.CheckedAt.IsZero() {
			at = r.CheckedAt.UnixMilli()
		}
		if err := w.exec(`INSERT INTO pr_cache(repo_path, branch, data, checked_at, note) SELECT ?, ?, ?, ?, ? WHERE `+hasWorktree+`
ON CONFLICT(repo_path, branch) DO UPDATE SET data = excluded.data, checked_at = excluded.checked_at, note = excluded.note`,
			r.Repo, r.Branch, r.Data, at, r.Note, r.Repo, r.Branch); err != nil {
			return err
		}
	}
	return w.commit()
}

// NotePRStates sets the note of rows of the PR cache in one write. A row
// keeps its data and its time. A branch with no row gets a row with no data.
// It skips a row whose worktree is gone.
func (s *Store) NotePRStates(note string, keys []PRKey) error {
	w, err := s.beginUnmarkedWrite()
	if err != nil {
		return err
	}
	defer w.rollback()
	for _, k := range keys {
		if err := w.exec(`INSERT INTO pr_cache(repo_path, branch, note) SELECT ?, ?, ? WHERE `+hasWorktree+`
ON CONFLICT(repo_path, branch) DO UPDATE SET note = excluded.note`, k.Repo, k.Branch, note, k.Repo, k.Branch); err != nil {
			return err
		}
	}
	return w.commit()
}
