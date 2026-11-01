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
	// 6: the PR cache: what GitHub last said about a branch of a repo (keyed
	// by path, as repo_settings is). It is not in the change log.
	`
CREATE TABLE pr_cache (
  repo_path TEXT NOT NULL,
  branch TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '',
  checked_at INTEGER NOT NULL DEFAULT 0,
  note TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (repo_path, branch)
);
`,
	// 7: the goal of a worktree, and the link that the work started from: its
	// target, label, and issue key, and the ID of the plot link it came from,
	// if any. A goal edit is in the change log as the item worktree:<id>.
	`
ALTER TABLE worktrees ADD COLUMN goal TEXT NOT NULL DEFAULT '';
ALTER TABLE worktrees ADD COLUMN link_target TEXT NOT NULL DEFAULT '';
ALTER TABLE worktrees ADD COLUMN link_label TEXT NOT NULL DEFAULT '';
ALTER TABLE worktrees ADD COLUMN link_key TEXT NOT NULL DEFAULT '';
ALTER TABLE worktrees ADD COLUMN link_id TEXT NOT NULL DEFAULT '';
`,
	// 8: the land of a worktree that waits for GitHub (an auto merge, or a
	// merge queue), as JSON. It is empty when no land waits. It is not in the
	// change log.
	`ALTER TABLE worktrees ADD COLUMN land TEXT NOT NULL DEFAULT '';`,
	// 9: what the app does when a refresh finds that GitHub merged the PR of
	// a worktree of the repo path: ask, remove, or keep.
	`ALTER TABLE repo_settings ADD COLUMN after_merge TEXT NOT NULL DEFAULT 'ask';`,
	// 10: runs and their events. A run is one goal that a background
	// session works on in a folder, until its Done when checks pass and CI
	// passes on the PR that Loam opens for it. The worktree ID is not a
	// foreign key: a run outlives its worktree. Neither table is in the change
	// log.
	`
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  worktree_id TEXT NOT NULL DEFAULT '',
  folder TEXT NOT NULL,
  title TEXT NOT NULL,
  goal TEXT NOT NULL DEFAULT '',
  done_when TEXT NOT NULL DEFAULT '[]',
  state TEXT NOT NULL,
  tries INTEGER NOT NULL DEFAULT 0,
  max_tries INTEGER NOT NULL,
  session_id TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  source_kind TEXT NOT NULL DEFAULT '',
  source_key TEXT NOT NULL DEFAULT '',
  source_url TEXT NOT NULL DEFAULT '',
  pr_number INTEGER NOT NULL DEFAULT 0,
  pr_url TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX runs_plot ON runs(plot_id, created_at);
CREATE INDEX runs_session ON runs(session_id);
CREATE TABLE run_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(id),
  at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX run_events_run ON run_events(run_id, id);
`,
	`ALTER TABLE runs ADD COLUMN shape TEXT NOT NULL DEFAULT '';`,
	// 12: recurring runs (ticket 208). Not in the change log, as runs are
	// not.
	`
CREATE TABLE recurring (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  title TEXT NOT NULL,
  prompt TEXT NOT NULL,
  kind TEXT NOT NULL,
  days TEXT NOT NULL,
  at TEXT NOT NULL,
  precheck TEXT NOT NULL DEFAULT '',
  if_asleep TEXT NOT NULL,
  repo TEXT NOT NULL DEFAULT '',
  done_when TEXT NOT NULL DEFAULT '[]',
  max_tries INTEGER NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  next_at INTEGER NOT NULL,
  last_at INTEGER NOT NULL DEFAULT 0,
  last_note TEXT NOT NULL DEFAULT '',
  last_run_id TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX recurring_next ON recurring(next_at);
`,
	// 13: rules (ticket 209): checks that every run of a plot must pass.
	`
CREATE TABLE rules (
  id TEXT PRIMARY KEY,
  plot_id TEXT NOT NULL REFERENCES plots(id),
  name TEXT NOT NULL,
  command TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX rules_plot ON rules(plot_id, created_at);
`,
	// 14: effort of runs, and the model and effort that a plot defaults to.
	`
ALTER TABLE recurring ADD COLUMN effort TEXT NOT NULL DEFAULT '';
CREATE TABLE run_defaults (
  plot_id TEXT PRIMARY KEY REFERENCES plots(id),
  model TEXT NOT NULL DEFAULT '',
  effort TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);
`,
	// 15: linked runs: the runs that one shape made for one issue, one in
	// each repo, share a group.
	`ALTER TABLE runs ADD COLUMN group_id TEXT NOT NULL DEFAULT '';`,
	// 16: run limits and the queue. turns counts the turns that the session
	// of a run ended. queue says how a Queued run starts its session when a
	// slot is free, as JSON. run_limits has one row, and usage has one row:
	// the last usage that Claude Code reported. Neither is in the change log.
	`
ALTER TABLE runs ADD COLUMN turns INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN queue TEXT NOT NULL DEFAULT '';
CREATE TABLE run_limits (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  at_a_time INTEGER NOT NULL,
  max_turns INTEGER NOT NULL,
  hold_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE usage (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  five_hour REAL,
  five_hour_resets_at INTEGER,
  seven_day REAL,
  seven_day_resets_at INTEGER,
  read_at INTEGER NOT NULL
);
`,
	// 17: the ship notes of a run, as JSON, or NULL when it has none. And the
	// switches for the updates that Loam makes to Linear: one row, for every
	// plot. Neither is in the change log.
	`
ALTER TABLE runs ADD COLUMN notes TEXT;
CREATE TABLE linear_updates (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  in_progress INTEGER NOT NULL,
  attach_pr INTEGER NOT NULL,
  done INTEGER NOT NULL,
  walkthrough_comment INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
`,
	// 18: when Loam last tried a probe of the usage, whether it worked or
	// not, so separate processes probe at most once in a while. A usage row
	// with read_at 0 has no report yet. turn_base is the turns of a run when
	// Loam last resumed its session, for the turn limit. pr_draft is the PR
	// text that Loam made before it opened the PR of a run, as JSON, or ''.
	`
ALTER TABLE usage ADD COLUMN tried_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN turn_base INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN pr_draft TEXT NOT NULL DEFAULT '';
`,
	// 19: the worktree that a session works in, when it is not the folder
	// that the session started in, such as a worktree that the session made
	// through MCP. A session has one at most. Not in the change log.
	`
CREATE TABLE session_worktrees (
  session_id TEXT PRIMARY KEY,
  worktree_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX session_worktrees_worktree ON session_worktrees(worktree_id, updated_at);
`,
	// 20: the MCP servers that claude -p loads when it drafts a run or writes
	// the PR text, as a JSON list of names. Not in the change log.
	`ALTER TABLE run_defaults ADD COLUMN mcp_servers TEXT NOT NULL DEFAULT '[]';`,
	// 21: the reviews that Loam sent back to the session of a run.
	// review_tries counts the sends. reviews_sent holds the IDs of the
	// reviews that requested changes, as a JSON list, or ''.
	`
ALTER TABLE runs ADD COLUMN review_tries INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN reviews_sent TEXT NOT NULL DEFAULT '';
	`,
	// 22: the code review that Loam runs before it pushes a run. review turns
	// it on or off for a plot, and review_effort is its effort level, or ''
	// for the Claude Code setting. code_review is the state of the review of
	// a run, as JSON, or ''. Neither is in the change log.
	`
ALTER TABLE run_defaults ADD COLUMN review INTEGER NOT NULL DEFAULT 1;
ALTER TABLE run_defaults ADD COLUMN review_effort TEXT NOT NULL DEFAULT '';
ALTER TABLE runs ADD COLUMN code_review TEXT NOT NULL DEFAULT '';
`,
	// 23: what Loam sent back of the last review of a run, as JSON, or '',
	// so it posts the replies of the session to those threads only.
	`ALTER TABLE runs ADD COLUMN review_replies TEXT NOT NULL DEFAULT '';`,
	// 24: the run metrics (TAS-176). fixes is the ID of the landed run that a
	// run fixes, or ''. stage is where a try failed: gate or ci, and '' for
	// the other events. A try that a run counted in Shipping is a CI try, so
	// the UPDATE gives the tries before this migration their stage from the
	// state before them.
	`
ALTER TABLE runs ADD COLUMN fixes TEXT NOT NULL DEFAULT '';
ALTER TABLE run_events ADD COLUMN stage TEXT NOT NULL DEFAULT '';
UPDATE run_events SET stage = CASE (
  SELECT p.detail FROM run_events p WHERE p.run_id = run_events.run_id AND p.kind = 'state' AND p.id < run_events.id
  ORDER BY p.id DESC LIMIT 1) WHEN 'shipping' THEN 'ci' WHEN 'ready' THEN 'ci' ELSE 'gate' END
WHERE kind = 'try';
`,
	// 25: the paths and hosts that the user adds to the sandbox of a run. scope
	// is a plot ID, or '' for the machine. Each list is JSON. Not in the change
	// log.
	`
CREATE TABLE sandbox_settings (
  scope TEXT PRIMARY KEY,
  read_paths TEXT NOT NULL,
  write_paths TEXT NOT NULL,
  hosts TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
`,
	// 26: what a run event holds beside its detail (TAS-204), as JSON, or '':
	// the result of the check of a "check" event, with the end of the output
	// of a failed check, and the findings of a "code_review" event.
	`ALTER TABLE run_events ADD COLUMN data TEXT NOT NULL DEFAULT '';`,
	// 27: gate_timeouts counts the gates of a run in a row whose checks ran
	// out of time, so the second one stops the run. blocked_stops counts the
	// stops in a row that the gate blocked, so the gate stops the run before
	// Claude Code lets the session stop (TAS-213).
	`
ALTER TABLE runs ADD COLUMN gate_timeouts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN blocked_stops INTEGER NOT NULL DEFAULT 0;
`,
	// 28: ci_rerun is the head commit of the PR of a run whose failed CI
	// jobs Loam ran again, or '', so it runs the jobs of a head again at most
	// once. ci_sent is the head whose CI failure Loam sent back to the
	// session, or '', so a session that changes nothing does not get the
	// same failure again (TAS-210).
	`
ALTER TABLE runs ADD COLUMN ci_rerun TEXT NOT NULL DEFAULT '';
ALTER TABLE runs ADD COLUMN ci_sent TEXT NOT NULL DEFAULT '';
`,
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
