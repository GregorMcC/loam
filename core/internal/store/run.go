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
// Shipping when its gate passes, and to Ready when CI passes on its PR. A run
// that has no slot for its session waits in Queued. Shaping, Stopped, and
// Limited need you.
type RunState string

const (
	// RunShaping waits for you to approve its goal and its checks.
	RunShaping RunState = "shaping"
	// RunQueued waits for a slot: the run limits or the week's usage hold
	// its session. A tick starts it when a slot is free. Its note says why
	// it waits.
	RunQueued RunState = "queued"
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

var runStates = []RunState{RunShaping, RunQueued, RunStarting, RunRunning, RunShipping, RunReady, RunStopped, RunLimited,
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

// HoldsSlot reports whether a run in the state holds one of the slots that
// the run limits allow: Loam starts its session, or the session works.
// Starting, Running, and Start unknown hold a slot.
func (st RunState) HoldsSlot() bool {
	return st == RunStarting || st == RunRunning || st == RunStartUnknown
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
	// FollowUps are the work that the draft leaves out on purpose. Each one
	// becomes an issue when you approve the run, unless you drop it.
	FollowUps []FollowUp `json:"follow_ups"`
	// Plan is the steps that Claude means to take.
	Plan []string `json:"plan"`
	// Size is Claude's estimate of the change, in one sentence.
	Size string `json:"size"`
	// DraftedAt is when Claude finished the last draft, or nil while the run
	// has none.
	DraftedAt *time.Time `json:"drafted_at,omitempty"`
	// Repo, Base, and Link say how the run's worktree is made when you
	// approve it, as for loam run start. Model and Effort are those of the
	// draft and of the session.
	Repo   string `json:"repo"`
	Base   string `json:"base"`
	Link   string `json:"link"`
	Model  string `json:"model"`
	Effort string `json:"effort"`
	// Brief is what Claude drafts from when the run has no issue, such as
	// the prompt of a recurring run.
	Brief string `json:"brief,omitempty"`
	// Split is true while a shape with --split has no draft yet, so a
	// redraft splits the issue across the repos again.
	Split bool `json:"split,omitempty"`
}

// The kinds of the target of a follow-up.
const (
	TargetLinear = "linear"
	TargetGitHub = "github"
)

// FollowUp is work that a draft leaves out on purpose, such as "A picker in
// the app". On approve, Loam files it as an issue at its target.
type FollowUp struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	// Target is where Loam files the issue.
	Target FollowUpTarget `json:"target"`
	// Kept is true until you drop the follow-up.
	Kept bool `json:"kept"`
	// Filed is the issue that Loam made for it, or nil while there is none.
	Filed *FiledIssue `json:"filed,omitempty"`
	// Error is why Loam could not file it, or empty.
	Error string `json:"error,omitempty"`
}

// FollowUpTarget is the tracker where a follow-up becomes an issue.
type FollowUpTarget struct {
	// Kind is linear or github.
	Kind string `json:"kind"`
	// Label is for a person: the Linear project, or the GitHub repo.
	Label string `json:"label"`
	// URL is the Linear project or team page, or the web page of the GitHub
	// repo. It is empty for the project of the Linear issue that the run
	// started from.
	URL string `json:"url,omitempty"`
}

// FiledIssue is the issue that Loam made for a follow-up. A Linear key is
// such as ENG-523. A GitHub key is owner/name#57.
type FiledIssue struct {
	Key string `json:"key"`
	URL string `json:"url"`
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

// RunQueue is how a Queued run starts its session when a slot is free.
type RunQueue struct {
	// Model and Effort are those of a new session.
	Model  string `json:"model"`
	Effort string `json:"effort"`
	// Resume is the prompt that resumes the session of the run, such as your
	// notes or a CI failure. Empty means a new session.
	Resume string `json:"resume"`
}

// RunNotes are the ship notes of a run: what Claude wrote about the change
// when Loam opened its PR. The Land screen shows them.
type RunNotes struct {
	// Walkthrough says what changed and why, in 2 to 4 plain sentences.
	Walkthrough string `json:"walkthrough"`
	// Files are the changed files, in the order that a reviewer should read
	// them.
	Files []NoteFile `json:"files"`
	Risk  NoteRisk   `json:"risk"`
	// WhereItStands is a new Where it stands for the plot: the text that the
	// plot had, moved on by this change.
	WhereItStands string    `json:"where_it_stands"`
	WrittenAt     time.Time `json:"written_at"`
}

// NoteFile is one changed file of the ship notes, with its role in the
// change in 1 to 4 words, such as "Tests".
type NoteFile struct {
	Path string `json:"path"`
	Role string `json:"role"`
}

// Risk levels of the ship notes.
const (
	RiskLow    = "low"
	RiskMedium = "medium"
	RiskHigh   = "high"
)

// NoteRisk is how risky the change is, and why. Loam adds facts of its own
// to the reasons of Claude.
type NoteRisk struct {
	// Level is low, medium, or high.
	Level   string   `json:"level"`
	Reasons []string `json:"reasons"`
}

// RunPRDraft is the PR text that Loam made for a run before it opened the
// PR: the title, the body, and the ship notes. A tick that could not open
// the PR uses it again, so Claude does not write the text twice. It holds
// for the commit Head only.
type RunPRDraft struct {
	Head  string    `json:"head"`
	Title string    `json:"title"`
	Body  string    `json:"body"`
	Notes *RunNotes `json:"notes"`
}

// clone copies the draft and its notes.
func (d *RunPRDraft) clone() *RunPRDraft {
	if d == nil {
		return nil
	}
	c := *d
	c.Notes = d.Notes.clone()
	return &c
}

// clone copies the notes, with empty lists where they have none, so the
// JSON has arrays.
func (n *RunNotes) clone() *RunNotes {
	if n == nil {
		return nil
	}
	c := *n
	c.Files = append([]NoteFile{}, n.Files...)
	c.Risk.Reasons = append([]string{}, n.Risk.Reasons...)
	return &c
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
	// GroupID links the runs that one shape made for one issue, one in each
	// repo. It is the ID of the first run, or empty for a run alone.
	GroupID string `json:"group_id"`
	// Turns counts the turns that the session ended: one for each Stop.
	Turns int `json:"turns"`
	// TurnBase is Turns when Loam last resumed the session, such as with
	// your notes or a CI failure. The turn limit counts the turns after it.
	// It is not in the JSON.
	TurnBase int `json:"-"`
	// Queue says how a Queued run starts its session, or nil. It is not in
	// the JSON.
	Queue *RunQueue `json:"-"`
	// SessionID is the Claude Code session ID, from its SessionStart hook.
	// It is empty until the session starts.
	SessionID string `json:"session_id"`
	// Note says why the run is in its state, such as the failed checks.
	Note string `json:"note"`
	// Notes are the ship notes that Claude wrote when Loam opened the PR, or
	// nil.
	Notes *RunNotes `json:"notes"`
	// PRDraft is the PR text that waits for the PR to open, or nil. It is
	// not in the JSON.
	PRDraft   *RunPRDraft `json:"-"`
	CreatedAt time.Time   `json:"created_at"`
	UpdatedAt time.Time   `json:"updated_at"`
}

// RunEvent is one line of a run's history: a state, a try, or a note.
type RunEvent struct {
	ID     int64     `json:"id"`
	RunID  string    `json:"run_id"`
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	Detail string    `json:"detail"`
}

// FeedLimit is the most events that [Store.RunFeed] returns.
const FeedLimit = 200

// FeedEvent is a run event with the run and the plot that it belongs to.
type FeedEvent struct {
	RunID    string    `json:"run_id"`
	PlotID   string    `json:"plot_id"`
	RunTitle string    `json:"run_title"`
	At       time.Time `json:"at"`
	Kind     string    `json:"kind"`
	Detail   string    `json:"detail"`
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
	r.Tries, r.Turns, r.TurnBase = 0, 0, 0
	r.CreatedAt, r.UpdatedAt = tm(now), tm(now)
	checks, src, pr, shape, queue, notes, draft := encodeRun(r)
	if err := tx.exec(`INSERT INTO runs(`+runCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)`,
		r.ID, r.PlotID, r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, r.GroupID, queue, notes, draft, now, now); err != nil {
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
	r, err := updateRun(tx, id, fn, nil)
	if err != nil {
		return Run{}, err
	}
	return r, tx.commit()
}

// updateRun is [Store.UpdateRun] in the write transaction tx. It does not
// commit. A try event has the note of the run, or tryNote when it is not nil
// and not empty after fn.
func updateRun(tx *writeTx, id string, fn func(*Run) error, tryNote *string) (Run, error) {
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
	if old.Queue != nil {
		q := *old.Queue
		r.Queue = &q
	}
	r.Notes = old.Notes.clone()
	r.PRDraft = old.PRDraft.clone()
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
	checks, src, pr, shape, queue, notes, draft := encodeRun(r)
	if err := tx.exec(`UPDATE runs SET worktree_id = ?, folder = ?, title = ?, goal = ?, done_when = ?, state = ?, tries = ?,
  max_tries = ?, session_id = ?, note = ?, source_kind = ?, source_key = ?, source_url = ?, pr_number = ?, pr_url = ?,
  shape = ?, group_id = ?, turns = ?, turn_base = ?, queue = ?, notes = ?, pr_draft = ?,
  updated_at = ? WHERE id = ?`,
		r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.Tries, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, r.GroupID, r.Turns, r.TurnBase, queue, notes, draft, now, r.ID); err != nil {
		return Run{}, err
	}
	if r.Tries != old.Tries {
		note := r.Note
		if tryNote != nil && *tryNote != "" {
			note = *tryNote
		}
		if err := addRunEvent(tx, r.ID, now, "try", note); err != nil {
			return Run{}, err
		}
	}
	if r.State != old.State {
		if err := addRunEvent(tx, r.ID, now, "state", string(r.State)); err != nil {
			return Run{}, err
		}
	}
	return r, nil
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

// RunFeed returns the events of every run of the plot, or of every plot when
// plotID is "", newest first, at most [FeedLimit]. A zero since returns all
// events. Else it returns only the events after since.
func (s *Store) RunFeed(plotID string, since time.Time) ([]FeedEvent, error) {
	out := []FeedEvent{}
	query := `SELECT e.run_id, r.plot_id, r.title, e.at, e.kind, e.detail
  FROM run_events e JOIN runs r ON r.id = e.run_id WHERE 1 = 1`
	var args []any
	if plotID != "" {
		query += ` AND r.plot_id = ?`
		args = append(args, plotID)
	}
	if !since.IsZero() {
		query += ` AND e.at > ?`
		args = append(args, since.UnixMilli())
	}
	query += ` ORDER BY e.at DESC, e.id DESC LIMIT ?`
	args = append(args, FeedLimit)
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			var e FeedEvent
			var at int64
			if err := rows.Scan(&e.RunID, &e.PlotID, &e.RunTitle, &at, &e.Kind, &e.Detail); err != nil {
				return err
			}
			e.At = tm(at)
			out = append(out, e)
			return nil
		}, query, args...)
	})
	return out, err
}

// runCols are the columns of a run record.
const runCols = `id, plot_id, worktree_id, folder, title, goal, done_when, state, tries, max_tries, session_id, note,
  source_kind, source_key, source_url, pr_number, pr_url, shape, group_id, turns, turn_base, queue, notes, pr_draft,
  created_at, updated_at`

// encodeRun returns the columns of a run that are not plain values. notes is
// NULL when the run has none, and draft is "" when it has none.
func encodeRun(r Run) (checks string, src RunSource, pr RunPR, shape, queue string, notes sql.NullString, draft string) {
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
	if r.Queue != nil {
		qb, err := json.Marshal(r.Queue)
		if err != nil { // strings always encode
			panic(err)
		}
		queue = string(qb)
	}
	if n := r.Notes.clone(); n != nil {
		nb, err := json.Marshal(n)
		if err != nil { // strings, string slices, and a time always encode
			panic(err)
		}
		notes = sql.NullString{String: string(nb), Valid: true}
	}
	if d := r.PRDraft.clone(); d != nil {
		db, err := json.Marshal(d)
		if err != nil { // strings and notes always encode
			panic(err)
		}
		draft = string(db)
	}
	return string(b), src, pr, shape, queue, notes, draft
}

// clone copies the shape, with empty lists where it has none, so the JSON
// has arrays.
func (sh *RunShape) clone() *RunShape {
	if sh == nil {
		return nil
	}
	c := *sh
	c.Assumptions = append([]Assumption{}, sh.Assumptions...)
	c.FollowUps = append([]FollowUp{}, sh.FollowUps...)
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
	var shape, queue, draft string
	var notes sql.NullString
	var created, updated int64
	err := sc.Scan(&r.ID, &r.PlotID, &r.WorktreeID, &r.Folder, &r.Title, &r.Goal, &checks, &r.State, &r.Tries,
		&r.MaxTries, &r.SessionID, &r.Note, &src.Kind, &src.Key, &src.URL, &pr.Number, &pr.URL, &shape, &r.GroupID,
		&r.Turns, &r.TurnBase, &queue, &notes, &draft, &created, &updated)
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
	if queue != "" {
		var q RunQueue
		if err := json.Unmarshal([]byte(queue), &q); err != nil {
			return Run{}, fmt.Errorf("run %s: bad queue: %w", r.ID, err)
		}
		r.Queue = &q
	}
	if notes.Valid {
		var n RunNotes
		if err := json.Unmarshal([]byte(notes.String), &n); err != nil {
			return Run{}, fmt.Errorf("run %s: bad notes: %w", r.ID, err)
		}
		r.Notes = n.clone()
	}
	if draft != "" {
		var d RunPRDraft
		if err := json.Unmarshal([]byte(draft), &d); err != nil {
			return Run{}, fmt.Errorf("run %s: bad PR draft: %w", r.ID, err)
		}
		r.PRDraft = &d
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
