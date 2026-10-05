// Package store is the Loam store: one SQLite database that holds plots,
// their order, the change log, and the records of sessions that Loam started.
//
// The CLI and the MCP server open the store directly. Every write goes
// through [Store.Apply] or [Store.CreatePlot]. Each call is one change in the
// change log and one SQLite transaction.
//
// Main entry points:
//
//   - [Home] and [Open] find the LOAM_HOME folder and open the store.
//   - [Store.CreatePlot] makes a plot.
//   - [Store.GetPlot] reads a plot with the version of each item.
//   - [Store.ListPlots] lists plots in the stored order.
//   - [Store.Apply] changes a plot: a set of edits and the versions that the
//     caller read, in one transaction. A stale version fails the whole call
//     with a [*StaleError] and writes nothing.
//   - [Store.ListChanges] reads the change log.
//   - [Store.AddSession], [Store.IsSeeded], and the PID functions keep the
//     records of sessions.
//
// A version is the ID of the change that last set an item. The items are
// [ItemName], [ItemWhat], [ItemWhy], [ItemWhere], [LinkItem] and [RepoItem].
package store

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite" // the SQLite driver, pure Go
)

// DefaultBusyTimeoutMS is how long a writer waits for another writer.
const DefaultBusyTimeoutMS = 5000

// Home returns the Loam home folder: LOAM_HOME, or ~/.loam.
func Home() (string, error) {
	if h := os.Getenv("LOAM_HOME"); h != "" {
		return filepath.Abs(h)
	}
	u, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home folder: %w", err)
	}
	return filepath.Join(u, ".loam"), nil
}

// Store is an open Loam store. It is safe for concurrent use.
type Store struct {
	db   *sql.DB
	home string
}

// Open opens the store in the home folder, and creates the folder, the
// database, and the plots folder when they are missing. It migrates an older
// database to the schema of this binary. It does not fail on a newer
// database. Writes to a newer database fail with [ErrSchemaNewer].
//
// The home folder is private to the user (0700): it holds every brief, the
// seeds, and the worktrees, which can hold copied secrets.
func Open(home string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(home, "plots"), 0o700); err != nil {
		return nil, fmt.Errorf("create store folder: %w", err)
	}
	if err := os.Chmod(home, 0o700); err != nil {
		return nil, fmt.Errorf("make the store folder private: %w", err)
	}
	q := url.Values{}
	q.Add("_pragma", fmt.Sprintf("busy_timeout(%d)", DefaultBusyTimeoutMS))
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "foreign_keys(1)")
	dsn := (&url.URL{Scheme: "file", Path: filepath.Join(home, "loam.db"), RawQuery: q.Encode()}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open store: %w", err)
	}
	s := &Store{db: db, home: home}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// OpenHome opens the store in [Home].
func OpenHome() (*Store, error) {
	h, err := Home()
	if err != nil {
		return nil, err
	}
	return Open(h)
}

// Close closes the store.
func (s *Store) Close() error { return s.db.Close() }

// Home returns the home folder of the store.
func (s *Store) Home() string { return s.home }

// PlotDir returns the plot folder for a plot ID. It does not create it.
func (s *Store) PlotDir(plotID string) string {
	return filepath.Join(s.home, "plots", plotID)
}
