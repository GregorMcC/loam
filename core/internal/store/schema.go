package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// migrations holds the schema steps. Step n takes the schema to version n.
// Add new steps at the end. Never edit a step that has shipped.
var migrations = []string{
	// 1: plots, links, repos, order, change log, sessions.
	`
CREATE TABLE plots (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  what TEXT NOT NULL DEFAULT '',
  why TEXT NOT NULL DEFAULT '',
  where_it_stands TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE TABLE plot_order (
  position INTEGER PRIMARY KEY AUTOINCREMENT,
  plot_id TEXT NOT NULL UNIQUE REFERENCES plots(id)
);
CREATE TABLE links (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  position INTEGER NOT NULL,
  label TEXT NOT NULL,
  target TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT ''
);
CREATE INDEX links_plot ON links(plot_id, position);
CREATE TABLE repos (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  path TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  is_main INTEGER NOT NULL DEFAULT 0,
  UNIQUE (plot_id, path)
);
CREATE TABLE changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  at INTEGER NOT NULL,
  actor_kind TEXT NOT NULL,
  session_id TEXT NOT NULL DEFAULT '',
  loam_started INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX changes_plot ON changes(plot_id, id);
CREATE TABLE change_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  change_id INTEGER NOT NULL REFERENCES changes(id),
  plot_id TEXT NOT NULL,
  item TEXT NOT NULL,
  field TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT
);
CREATE INDEX entries_change ON change_entries(change_id);
CREATE INDEX entries_item ON change_entries(plot_id, item);
CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  start_folder TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX sessions_plot ON sessions(plot_id, created_at);
CREATE TABLE session_pids (
  pid INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
`,
	// 2: undo_of marks a change that reverted another change.
	`ALTER TABLE changes ADD COLUMN undo_of INTEGER;`,
	// 3: repo settings (keyed by path, shared by every plot that holds the
	// repo) and worktree records. Neither is in the change log.
	`
CREATE TABLE repo_settings (
  path TEXT PRIMARY KEY,
  setup TEXT NOT NULL DEFAULT '',
  copy TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE worktrees (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  repo_path TEXT NOT NULL,
  name TEXT NOT NULL,
  branch TEXT NOT NULL,
  base TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL UNIQUE,
  setup_done INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (plot_id, repo_path, name)
);
CREATE INDEX worktrees_plot ON worktrees(plot_id, repo_path);
`,
	// 4: the archived flag of a plot. It is not in the change log.
	`ALTER TABLE plots ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;`,
	// 5: the setup command that you last approved for a repo path. Loam runs
	// a setup command only when it matches.
	`ALTER TABLE repo_settings ADD COLUMN setup_approved TEXT NOT NULL DEFAULT '';`,
}

// SchemaVersion is the schema version of this binary.
var SchemaVersion = len(migrations)

// ErrSchemaNewer means a newer Loam made the database. This binary refuses to
// write. The text is for a person: a running MCP server shows it as is.
var ErrSchemaNewer = errors.New("the Loam store is newer than this program: restart this session")

func (s *Store) migrate() error {
	if v, err := s.readVersion(s.db); err == nil && v >= SchemaVersion {
		return nil
	}
	w, err := s.beginRaw()
	if err != nil {
		return err
	}
	defer w.rollback()
	if _, err := w.conn.ExecContext(context.Background(), `CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`); err != nil {
		return fmt.Errorf("create schema version table: %w", err)
	}
	v, err := s.readVersion(w.conn)
	if err != nil {
		return err
	}
	if v > SchemaVersion {
		return nil // newer database: leave it, and refuse writes later
	}
	if v == 0 {
		if _, err := w.conn.ExecContext(context.Background(), `INSERT INTO schema_version(version) VALUES (0)`); err != nil {
			return err
		}
	}
	for n := v + 1; n <= SchemaVersion; n++ {
		if _, err := w.conn.ExecContext(context.Background(), migrations[n-1]); err != nil {
			return fmt.Errorf("migrate to schema %d: %w", n, err)
		}
		if _, err := w.conn.ExecContext(context.Background(), `UPDATE schema_version SET version = ?`, n); err != nil {
			return err
		}
	}
	return w.commit()
}

type queryRower interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// readVersion returns the schema version, or 0 when the database is new.
func (s *Store) readVersion(q queryRower) (int, error) {
	var v int
	err := q.QueryRowContext(context.Background(), `SELECT version FROM schema_version`).Scan(&v)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, nil
		}
		return 0, err
	}
	return v, nil
}
