package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// RunState is where a run is. A run moves from Starting to Running, then to
// Shipping when its gate passes, and to Ready when CI passes on its PR.
// Shaping, Stopped, and Limited need you.
type RunState string

const (
	// RunShaping waits for you to approve its goal and its checks.
	RunShaping RunState = "shaping"
	// RunStarting is a run that Loam is starting. A run that stays here after
	// its start command ended is Start unknown.
	RunStarting RunState = "starting"
	// RunRunning has a background session in a turn, or between the turns
	// that its gate asks for.
	RunRunning RunState = "running"
	// RunShipping passed its gate. Loam pushes its branch, opens its PR, and
	// waits for CI. A CI failure sends the run back to Running with a try.
	RunShipping RunState = "shipping"
	// RunReady waits for you to land it: its gate passed, and CI passed on its
	// PR, or it has no PR.
	RunReady RunState = "ready"
	// RunStopped used all its tries, or a failure stopped it.
	RunStopped RunState = "stopped"
	// RunLimited is Stopped by a limit: Claude Code hit a usage limit. It
	// does not count a try.
	RunLimited RunState = "limited"
	// RunStartUnknown is a run whose start Loam lost track of. Loam reads the
	// background sessions before it starts the run again, so a prompt never
	// goes twice.
	RunStartUnknown RunState = "start_unknown"
	// RunLanded is merged.
	RunLanded RunState = "landed"
	// RunCancelled was stopped by you.
	RunCancelled RunState = "cancelled"
	// RunSkipped is a recurring run whose precheck found no work.
	RunSkipped RunState = "skipped"
)

var runStates = []RunState{RunShaping, RunStarting, RunRunning, RunShipping, RunReady, RunStopped, RunLimited,
	RunStartUnknown, RunLanded, RunCancelled, RunSkipped}

// NeedsYou reports whether the state waits for you: Shaping, Stopped, and
// Limited.
func (st RunState) NeedsYou() bool {
	return st == RunShaping || st == RunStopped || st == RunLimited
}

// Ended reports whether the run has no session to work any more.
func (st RunState) Ended() bool {
	return st == RunLanded || st == RunCancelled || st == RunSkipped
}

func (st RunState) valid() bool {
	for _, s := range runStates {
		if s == st {
			return true
		}
	}
	return false
}

// DefaultMaxTries is how many times the gate of a run can fail before the
// run stops.
const DefaultMaxTries = 3

// MaxTriesLimit is the most tries a run can have. Claude Code lets a stop
// happen after 8 blocked stops in a row, so a gate cannot hold more.
const MaxTriesLimit = 8

// Check is one Done when check of a run: a shell command that passes when it
// exits 0 in the run's folder.
type Check struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

// SourceRecurring is the kind of the source of a run that a recurring run
// started. Its key is the ID of the recurring run.
const SourceRecurring = "recurring"

// RunSource is the issue that a run started from.
type RunSource struct {
	// Kind is linear, github, map, or recurring.
	Kind string `json:"kind"`
	Key  string `json:"key"`
	URL  string `json:"url"`
}

// RunShape is the draft of a Shaping run (ticket 207): what Claude made of
// its issue besides the goal and the checks, and how the run starts when you
// approve it.
type RunShape struct {
	// Assumptions are the choices that Claude made and the issue does not
	// settle. You keep each one or change it.
	Assumptions []Assumption `json:"assumptions"`
	// Plan is the steps that Claude means to take.
	Plan []string `json:"plan"`
	// Size is Claude's estimate of the change, in one sentence.
	Size string `json:"size"`
	// DraftedAt is when Claude finished the last draft, or nil while the run
	// has none.
	DraftedAt *time.Time `json:"drafted_at,omitempty"`
	// Repo, Base, and Link say how the run's worktree is made when you
	// approve it, as for loam run start. Model is the model of the session.
	Repo  string `json:"repo"`
	Base  string `json:"base"`
	Link  string `json:"link"`
	Model string `json:"model"`
	// Brief is what Claude drafts from when the run has no issue, such as
	// the prompt of a recurring run.
	Brief string `json:"brief,omitempty"`
}

// Assumption is one choice of a draft that the issue does not settle.
type Assumption struct {
	Text string `json:"text"`
	// Answer is what you want instead, or empty when you keep the
	// assumption.
	Answer string `json:"answer"`
}

// RunPR is the pull request that Loam opened for a run.
type RunPR struct {
	Number int    `json:"number"`
	URL    string `json:"url"`
}

// Run is one goal that a background Claude Code session works on in a
// folder, until its Done when checks pass. A run is not in the change log.
type Run struct {
	ID     string `json:"id"`
	PlotID string `json:"plot_id"`
	// WorktreeID is the worktree that the run works in, or empty when the run
	// works in a repo folder. The worktree can be gone.
	WorktreeID string `json:"worktree_id"`
	// Folder is where the session starts and where the checks run.
	Folder   string     `json:"folder"`
	Title    string     `json:"title"`
	Goal     string     `json:"goal"`
	DoneWhen []Check    `json:"done_when"`
	State    RunState   `json:"state"`
	Tries    int        `json:"tries"`
	MaxTries int        `json:"max_tries"`
	Source   *RunSource `json:"source,omitempty"`
	// PR is the pull request of the run, or nil before Loam ships it.
	PR *RunPR `json:"pr,omitempty"`
	// Shape is the draft of a run that started in Shaping, or nil.
	Shape *RunShape `json:"shape,omitempty"`
	// SessionID is the Claude Code session ID, from its SessionStart hook.
	// It is empty until the session starts.
	SessionID string `json:"session_id"`
	// Note says why the run is in its state, such as the failed checks.
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// RunEvent is one line of a run's history: a state, a try, or a note.
type RunEvent struct {
	ID     int64     `json:"id"`
	RunID  string    `json:"run_id"`
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	Detail string    `json:"detail"`
}

func (r *Run) check() error {
	var missing []string
	if r.PlotID == "" {
		missing = append(missing, "a plot")
	}
	if strings.TrimSpace(r.Title) == "" {
		missing = append(missing, "a title")
	}
	if r.Folder == "" {
		missing = append(missing, "a folder")
	}
	if len(missing) > 0 {
		return fmt.Errorf("a run needs %s: %w", strings.Join(missing, ", "), ErrInvalid)
	}
	for _, c := range r.DoneWhen {
		if strings.TrimSpace(c.Name) == "" || strings.TrimSpace(c.Command) == "" {
			return fmt.Errorf("each Done when check needs a name and a command: %w", ErrInvalid)
		}
	}
	if r.MaxTries < 1 || r.MaxTries > MaxTriesLimit {
		return fmt.Errorf("a run has 1 to %d tries, because Claude Code lets a session stop after %d blocked stops in a row: %w",
			MaxTriesLimit, MaxTriesLimit, ErrInvalid)
	}
	if !r.State.valid() {
		return fmt.Errorf("%q is not a run state: %w", r.State, ErrInvalid)
	}
	return nil
}

// AddRun records a run and gives it an ID. A run with no state starts as
// Starting, and a run with no MaxTries gets [DefaultMaxTries].
func (s *Store) AddRun(r Run) (Run, error) {
	if r.State == "" {
		r.State = RunStarting
	}
	if r.MaxTries == 0 {
		r.MaxTries = DefaultMaxTries
	}
	if r.DoneWhen == nil {
		r.DoneWhen = []Check{}
	}
	if err := r.check(); err != nil {
		return Run{}, err
	}
	tx, err := s.beginWrite()
	if err != nil {
		return Run{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, r.PlotID)
	if err != nil {
		return Run{}, err
	}
	if !ok {
		return Run{}, fmt.Errorf("plot %q: %w", r.PlotID, ErrNotFound)
	}
	r.ID, err = newID(func(id string) (bool, error) { return exists(tx.conn, `SELECT 1 FROM runs WHERE id = ?`, id) })
	if err != nil {
		return Run{}, err
	}
	now := time.Now().UnixMilli()
	r.Tries = 0
	r.CreatedAt, r.UpdatedAt = tm(now), tm(now)
	checks, src, pr, shape := encodeRun(r)
	if err := tx.exec(`INSERT INTO runs(`+runCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.PlotID, r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, now, now); err != nil {
		return Run{}, err
	}
	if err := addRunEvent(tx, r.ID, now, "state", string(r.State)); err != nil {
		return Run{}, err
	}
	return r, tx.commit()
}

// GetRun returns a run by ID, or an error that wraps [ErrNotFound].
func (s *Store) GetRun(id string) (Run, error) {
	var r Run
	err := s.readTx(func(q queryer) error {
		var err error
		r, err = loadRun(q, `id = ?`, id)
		return err
	})
	return r, err
}

// RunBySession returns the run of a Claude Code session ID, or an error that
// wraps [ErrNotFound].
func (s *Store) RunBySession(sessionID string) (Run, error) {
	if sessionID == "" {
		return Run{}, fmt.Errorf("run for no session: %w", ErrNotFound)
	}
	var r Run
	err := s.readTx(func(q queryer) error {
		var err error
		r, err = loadRun(q, `session_id = ?`, sessionID)
		return err
	})
	return r, err
}

// ListRuns returns the runs of a plot, or of every plot when plotID is
// empty, newest first.
func (s *Store) ListRuns(plotID string) ([]Run, error) {
	out := []Run{}
	query := `SELECT ` + runCols + ` FROM runs`
	var args []any
	if plotID != "" {
		query += ` WHERE plot_id = ?`
		args = append(args, plotID)
	}
	query += ` ORDER BY created_at DESC, rowid DESC`
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			r, err := scanRun(rows)
			if err != nil {
				return err
			}
			out = append(out, r)
			return nil
		}, query, args...)
	})
	return out, err
}

// UpdateRun reads a run, calls fn on it, and writes it back, in one write
// transaction. An error from fn writes nothing. fn cannot change the ID, the
// plot, or the creation time. A new state or a new try count adds a run
// event: the state, or the note of the try.
func (s *Store) UpdateRun(id string, fn func(*Run) error) (Run, error) {
	tx, err := s.beginWrite()
	if err != nil {
		return Run{}, err
	}
	defer tx.rollback()
	old, err := loadRun(tx.conn, `id = ?`, id)
	if err != nil {
		return Run{}, err
	}
	r := old
	r.DoneWhen = append([]Check{}, old.DoneWhen...)
	if old.Source != nil {
		src := *old.Source
		r.Source = &src
	}
	if old.PR != nil {
		pr := *old.PR
		r.PR = &pr
	}
	r.Shape = old.Shape.clone()
	if err := fn(&r); err != nil {
		return Run{}, err
	}
	if r.ID != old.ID || r.PlotID != old.PlotID || !r.CreatedAt.Equal(old.CreatedAt) {
		return Run{}, fmt.Errorf("a run keeps its ID, plot, and creation time: %w", ErrInvalid)
	}
	if err := r.check(); err != nil {
		return Run{}, err
	}
	now := time.Now().UnixMilli()
	r.UpdatedAt = tm(now)
	checks, src, pr, shape := encodeRun(r)
	if err := tx.exec(`UPDATE runs SET worktree_id = ?, folder = ?, title = ?, goal = ?, done_when = ?, state = ?, tries = ?,
  max_tries = ?, session_id = ?, note = ?, source_kind = ?, source_key = ?, source_url = ?, pr_number = ?, pr_url = ?,
  shape = ?, updated_at = ? WHERE id = ?`,
		r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.Tries, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, now, r.ID); err != nil {
		return Run{}, err
	}
	if r.Tries != old.Tries {
		if err := addRunEvent(tx, r.ID, now, "try", r.Note); err != nil {
			return Run{}, err
		}
	}
	if r.State != old.State {
		if err := addRunEvent(tx, r.ID, now, "state", string(r.State)); err != nil {
			return Run{}, err
		}
	}
	return r, tx.commit()
}

// AddRunEvent adds a line to the history of a run, such as the result of
// one check.
func (s *Store) AddRunEvent(runID, kind, detail string) error {
	tx, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM runs WHERE id = ?`, runID)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("run %q: %w", runID, ErrNotFound)
	}
	if err := addRunEvent(tx, runID, time.Now().UnixMilli(), kind, detail); err != nil {
		return err
	}
	return tx.commit()
}

// RunEvents returns the history of a run, oldest first.
func (s *Store) RunEvents(runID string) ([]RunEvent, error) {
	out := []RunEvent{}
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			var e RunEvent
			var at int64
			if err := rows.Scan(&e.ID, &e.RunID, &at, &e.Kind, &e.Detail); err != nil {
				return err
			}
			e.At = tm(at)
			out = append(out, e)
			return nil
		}, `SELECT id, run_id, at, kind, detail FROM run_events WHERE run_id = ? ORDER BY id`, runID)
	})
	return out, err
}

// runCols are the columns of a run record.
const runCols = `id, plot_id, worktree_id, folder, title, goal, done_when, state, tries, max_tries, session_id, note,
  source_kind, source_key, source_url, pr_number, pr_url, shape, created_at, updated_at`

func encodeRun(r Run) (checks string, src RunSource, pr RunPR, shape string) {
	b, err := json.Marshal(append([]Check{}, r.DoneWhen...))
	if err != nil { // a slice of string pairs always encodes
		panic(err)
	}
	if r.Source != nil {
		src = *r.Source
	}
	if r.PR != nil {
		pr = *r.PR
	}
	if sh := r.Shape.clone(); sh != nil {
		sb, err := json.Marshal(sh)
		if err != nil { // strings, string slices, and a time always encode
			panic(err)
		}
		shape = string(sb)
	}
	return string(b), src, pr, shape
}

// clone copies the shape, with empty lists where it has none, so the JSON
// has arrays.
func (sh *RunShape) clone() *RunShape {
	if sh == nil {
		return nil
	}
	c := *sh
	c.Assumptions = append([]Assumption{}, sh.Assumptions...)
	c.Plan = append([]string{}, sh.Plan...)
	if sh.DraftedAt != nil {
		at := *sh.DraftedAt
		c.DraftedAt = &at
	}
	return &c
}

func scanRun(sc interface{ Scan(...any) error }) (Run, error) {
	var r Run
	var checks string
	var src RunSource
	var pr RunPR
	var shape string
	var created, updated int64
	err := sc.Scan(&r.ID, &r.PlotID, &r.WorktreeID, &r.Folder, &r.Title, &r.Goal, &checks, &r.State, &r.Tries,
		&r.MaxTries, &r.SessionID, &r.Note, &src.Kind, &src.Key, &src.URL, &pr.Number, &pr.URL, &shape, &created, &updated)
	if err != nil {
		return Run{}, err
	}
	if err := json.Unmarshal([]byte(checks), &r.DoneWhen); err != nil {
		return Run{}, fmt.Errorf("run %s: bad Done when checks: %w", r.ID, err)
	}
	if src.Kind != "" || src.Key != "" || src.URL != "" {
		r.Source = &src
	}
	if pr.Number != 0 {
		r.PR = &pr
	}
	if shape != "" {
		var sh RunShape
		if err := json.Unmarshal([]byte(shape), &sh); err != nil {
			return Run{}, fmt.Errorf("run %s: bad shape: %w", r.ID, err)
		}
		r.Shape = sh.clone()
	}
	r.CreatedAt, r.UpdatedAt = tm(created), tm(updated)
	return r, nil
}

func loadRun(q queryer, where string, arg any) (Run, error) {
	r, err := scanRun(q.QueryRowContext(context.Background(), `SELECT `+runCols+` FROM runs WHERE `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return Run{}, fmt.Errorf("run %q: %w", arg, ErrNotFound)
	}
	return r, err
}

func addRunEvent(tx *writeTx, runID string, at int64, kind, detail string) error {
	return tx.exec(`INSERT INTO run_events(run_id, at, kind, detail) VALUES (?, ?, ?, ?)`, runID, at, kind, detail)
}
