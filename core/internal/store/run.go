package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
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

// DefaultMaxReviewTries is how many times Loam sends the review of a PR
// back to the session of its run, when the review requests changes. A
// review try is not a try: it has its own count.
const DefaultMaxReviewTries = 2

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

// RunCodeReview is the state of the code review that Loam runs before it
// pushes a run.
type RunCodeReview struct {
	// Head is the last commit that the review let Loam push: it found no
	// Critical or Major issue, it did not run, or it was off. Loam does not
	// review that commit again.
	Head string `json:"head"`
	// Rounds counts the reviews that found a Critical or Major issue.
	Rounds int `json:"rounds"`
	// Facts are what the review of Head adds to the risk of the ship notes:
	// its Minor findings, or why it did not run.
	Facts []string `json:"facts"`
}

// clone copies the review state, with an empty list where it has none.
func (c *RunCodeReview) clone() *RunCodeReview {
	if c == nil {
		return nil
	}
	out := *c
	out.Facts = append([]string{}, c.Facts...)
	return &out
}

// RunReviewReplies is what Loam sent back of the review of a PR, so it posts
// the replies that the session writes to those threads only.
type RunReviewReplies struct {
	// PR is the number of the PR of the review.
	PR int `json:"pr"`
	// Threads are the IDs of the review threads that the prompt holds.
	Threads []string `json:"threads"`
	// Cut are the IDs of the threads that the prompt holds in part. Loam
	// posts their replies, and does not resolve them.
	Cut []string `json:"cut"`
	// Comment is true when the prompt holds a review, so Loam posts the
	// comment of the session on the PR.
	Comment bool `json:"comment"`
	// Replied are the IDs of the threads that Loam has replied on, and
	// Commented is true when it has posted the comment. A post that Loam
	// tries again does not post them twice.
	Replied   []string `json:"replied"`
	Commented bool     `json:"commented"`
}

// clone copies the review replies, with empty lists where they have none.
func (rr *RunReviewReplies) clone() *RunReviewReplies {
	if rr == nil {
		return nil
	}
	c := *rr
	c.Threads = append([]string{}, rr.Threads...)
	c.Cut = append([]string{}, rr.Cut...)
	c.Replied = append([]string{}, rr.Replied...)
	return &c
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
	// ReviewTries counts the times that Loam sent the review of the PR back
	// to the session, at most [DefaultMaxReviewTries].
	ReviewTries int `json:"review_tries"`
	// ReviewsSent are the IDs of the reviews that requested changes and that
	// Loam sent back, so it sends none twice. It is not in the JSON.
	ReviewsSent []string `json:"-"`
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
	// GateTimeouts counts the gates in a row whose checks ran out of time.
	// Such a gate counts no try, and the second one stops the run. A gate that
	// waited for the gate of another run until no time was left for its
	// checks leaves it as it is. Any other gate, and each resume of the
	// session, sets it to 0. It is not in the JSON.
	GateTimeouts int `json:"-"`
	// BlockedStops counts the stops in a row that the gate blocked. Claude
	// Code lets a session stop after 8 blocked stops in a row, so the gate
	// stops the run before that. A stop that the gate lets end, and each
	// resume of the session, sets it to 0. It is not in the JSON.
	BlockedStops int `json:"-"`
	// CIRerun is the head commit of the PR whose failed CI jobs Loam ran
	// again, or empty. Loam runs the failed jobs of a head again at most
	// once: a second failure on that head goes back to the session. It is
	// not in the JSON.
	CIRerun string `json:"-"`
	// CISent is the head commit of the PR whose CI failure Loam sent back to
	// the session, or empty. When CI fails on that head again, the session
	// made no commit for the failure, and Loam stops the run. It is not in
	// the JSON.
	CISent string `json:"-"`
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
	PRDraft *RunPRDraft `json:"-"`
	// CodeReview is the state of the code review before each push, or nil
	// before the first review. It is not in the JSON.
	CodeReview *RunCodeReview `json:"-"`
	// ReviewReplies is what Loam sent back of the last review, until Loam
	// posts the replies of the session, or nil. It is not in the JSON.
	ReviewReplies *RunReviewReplies `json:"-"`
	// Fixes is the ID of the landed run that this run fixes, or empty. The
	// change failure rate counts the landed runs that a later run fixes.
	Fixes     string    `json:"fixes"`
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
	// Stage is where a try failed: [TryGate] or [TryCI]. It is empty for
	// the other kinds. It is not in the JSON.
	Stage string `json:"-"`
	RunEventData
}

// RunEventData is what a run event holds beside its detail. Each field is
// nil for an event of another kind, and for an event from before Loam
// stored it.
type RunEventData struct {
	// Check is the result of the check of a "check" event.
	Check *RunCheckResult `json:"check,omitempty"`
	// CodeReview is what the code review of a "code_review" event found. It
	// is nil when the review did not run or was off.
	CodeReview *RunCodeReviewRound `json:"code_review,omitempty"`
}

// CheckOutputMax is how many bytes of the output of a failed check a "check"
// event keeps: the end of the output, where the failure usually is.
const CheckOutputMax = 32 << 10

// RunCheckResult is the result of one check of a gate.
type RunCheckResult struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	Passed  bool   `json:"passed"`
	// Exit is the exit code of the check, or -1 when it did not run or did
	// not end.
	Exit int `json:"exit"`
	// Output is the output of a failed check, stdout and stderr together, at
	// most [CheckOutputMax] bytes from its end. A check that passed keeps no
	// output.
	Output string `json:"output"`
	// OutputCut is true when the output was longer, so Output is its end.
	OutputCut bool `json:"output_cut"`
}

// CutOutput keeps the end of output, at most [CheckOutputMax] bytes, from the
// start of a line when it can. It reports whether it cut.
func CutOutput(output string) (string, bool) {
	if len(output) <= CheckOutputMax {
		return output, false
	}
	end := output[len(output)-CheckOutputMax:]
	if i := strings.IndexByte(end, '\n'); i >= 0 && i < len(end)-1 {
		end = end[i+1:]
	}
	for len(end) > 0 && !utf8.RuneStart(end[0]) {
		end = end[1:]
	}
	return end, true
}

// RunCodeReviewRound is what one code review of a run found.
type RunCodeReviewRound struct {
	// Findings are the findings of the review, most severe first, each of
	// them, also the Minor ones that do not go to the session. At most
	// [CodeReviewFindingsMax].
	Findings []RunFinding `json:"findings"`
	// More is how many findings the review found after the list.
	More int `json:"more"`
}

// CodeReviewFindingsMax is how many findings of one code review a
// "code_review" event keeps.
const CodeReviewFindingsMax = 100

// RunFinding is one issue that a code review found.
type RunFinding struct {
	// Severity is critical, major, or minor.
	Severity string `json:"severity"`
	// File is the path from the root of the repo, or empty.
	File string `json:"file"`
	// Line is the line in the new file, or 0.
	Line int    `json:"line"`
	Text string `json:"text"`
}

// encode is the data as the JSON of the data column, or "" when it has none.
func (d RunEventData) encode() (string, error) {
	if d.Check == nil && d.CodeReview == nil {
		return "", nil
	}
	b, err := json.Marshal(d)
	return string(b), err
}

// The stages of a try.
const (
	// TryGate is a try that the gate counted: a Done when check failed.
	TryGate = "gate"
	// TryCI is a try that CI counted on the PR of the run.
	TryCI = "ci"
)

// tryStage is the stage of a try that a run counts in the state from. The
// gate runs while the session works. CI runs while the run ships or is
// Ready, so a try in Shipping or Ready is a CI try.
func tryStage(from RunState) string {
	if from == RunShipping || from == RunReady {
		return TryCI
	}
	return TryGate
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
	r.Tries, r.Turns, r.TurnBase, r.GateTimeouts, r.BlockedStops, r.ReviewTries, r.ReviewsSent, r.CIRerun, r.CISent = 0, 0, 0, 0, 0, 0, nil, "", ""
	r.CodeReview = nil    // a new run has no review of its head
	r.ReviewReplies = nil // nor a review that waits for replies
	r.CreatedAt, r.UpdatedAt = tm(now), tm(now)
	checks, src, pr, shape, queue, notes, draft, sent, review, replies := encodeRun(r)
	if err := tx.exec(`INSERT INTO runs(`+runCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?, ?, ?, 0, ?, ?, ?, ?, '', '', ?, ?)`,
		r.ID, r.PlotID, r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, r.GroupID, queue, notes, draft, sent, review, replies, r.Fixes, now, now); err != nil {
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
	r.ReviewsSent = slices.Clone(old.ReviewsSent)
	r.CodeReview = old.CodeReview.clone()
	r.ReviewReplies = old.ReviewReplies.clone()
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
	checks, src, pr, shape, queue, notes, draft, sent, review, replies := encodeRun(r)
	if err := tx.exec(`UPDATE runs SET worktree_id = ?, folder = ?, title = ?, goal = ?, done_when = ?, state = ?, tries = ?,
  max_tries = ?, session_id = ?, note = ?, source_kind = ?, source_key = ?, source_url = ?, pr_number = ?, pr_url = ?,
  shape = ?, group_id = ?, turns = ?, turn_base = ?, gate_timeouts = ?, blocked_stops = ?, queue = ?, notes = ?, pr_draft = ?, review_tries = ?, reviews_sent = ?,
  code_review = ?, review_replies = ?, fixes = ?, ci_rerun = ?, ci_sent = ?, updated_at = ? WHERE id = ?`,
		r.WorktreeID, r.Folder, r.Title, r.Goal, checks, r.State, r.Tries, r.MaxTries, r.SessionID, r.Note,
		src.Kind, src.Key, src.URL, pr.Number, pr.URL, shape, r.GroupID, r.Turns, r.TurnBase, r.GateTimeouts, r.BlockedStops, queue, notes, draft,
		r.ReviewTries, sent, review, replies, r.Fixes, r.CIRerun, r.CISent, now, r.ID); err != nil {
		return Run{}, err
	}
	if r.Tries != old.Tries {
		note := r.Note
		if tryNote != nil && *tryNote != "" {
			note = *tryNote
		}
		if err := addTryEvent(tx, r.ID, now, note, tryStage(old.State)); err != nil {
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
	return s.AddRunEventData(runID, kind, detail, RunEventData{})
}

// AddRunEventData adds a line to the history of a run with its data, such as
// the output of a check that failed.
func (s *Store) AddRunEventData(runID, kind, detail string, data RunEventData) error {
	raw, err := data.encode()
	if err != nil {
		return err
	}
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
	if err := tx.exec(`INSERT INTO run_events(run_id, at, kind, detail, data) VALUES (?, ?, ?, ?, ?)`,
		runID, time.Now().UnixMilli(), kind, detail, raw); err != nil {
		return err
	}
	return tx.commit()
}

// RunEvents returns the history of a run, oldest first.
func (s *Store) RunEvents(runID string) ([]RunEvent, error) {
	out := []RunEvent{}
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			e, err := scanRunEvent(rows)
			if err != nil {
				return err
			}
			out = append(out, e)
			return nil
		}, `SELECT `+eventCols+` FROM run_events WHERE run_id = ? ORDER BY id`, runID)
	})
	return out, err
}

// eventCols are the columns of a run event, for [scanRunEvent].
const eventCols = `id, run_id, at, kind, detail, stage, data`

func scanRunEvent(rows *sql.Rows) (RunEvent, error) {
	var e RunEvent
	var at int64
	var data string
	if err := rows.Scan(&e.ID, &e.RunID, &at, &e.Kind, &e.Detail, &e.Stage, &data); err != nil {
		return RunEvent{}, err
	}
	if data != "" {
		if err := json.Unmarshal([]byte(data), &e.RunEventData); err != nil {
			return RunEvent{}, fmt.Errorf("run event %d: bad data: %w", e.ID, err)
		}
	}
	e.At = tm(at)
	return e, nil
}

// RunHistory returns the runs of a plot, or of every plot when plotID is
// empty, and their state, try, and shape events, oldest first, in one read.
// The run metrics read only those kinds.
func (s *Store) RunHistory(plotID string) ([]Run, []RunEvent, error) {
	runs, events := []Run{}, []RunEvent{}
	runQuery := `SELECT ` + runCols + ` FROM runs`
	eventQuery := `SELECT ` + eventCols + ` FROM run_events WHERE kind IN ('state', 'try', 'shape')`
	var args []any
	if plotID != "" {
		runQuery += ` WHERE plot_id = ?`
		eventQuery += ` AND run_id IN (SELECT id FROM runs WHERE plot_id = ?)`
		args = append(args, plotID)
	}
	runQuery += ` ORDER BY created_at, rowid`
	eventQuery += ` ORDER BY id`
	err := s.readTx(func(q queryer) error {
		if err := scanRows(q, func(rows *sql.Rows) error {
			r, err := scanRun(rows)
			if err != nil {
				return err
			}
			runs = append(runs, r)
			return nil
		}, runQuery, args...); err != nil {
			return err
		}
		return scanRows(q, func(rows *sql.Rows) error {
			e, err := scanRunEvent(rows)
			if err != nil {
				return err
			}
			events = append(events, e)
			return nil
		}, eventQuery, args...)
	})
	return runs, events, err
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
  source_kind, source_key, source_url, pr_number, pr_url, shape, group_id, turns, turn_base, gate_timeouts, blocked_stops, queue, notes, pr_draft,
  review_tries, reviews_sent, code_review, review_replies, fixes, ci_rerun, ci_sent, created_at, updated_at`

// encodeRun returns the columns of a run that are not plain values. notes is
// NULL when the run has none, and draft, sent, review, and replies are ""
// when it has none.
func encodeRun(r Run) (checks string, src RunSource, pr RunPR, shape, queue string, notes sql.NullString, draft, sent, review, replies string) {
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
	if len(r.ReviewsSent) > 0 {
		sb, err := json.Marshal(r.ReviewsSent)
		if err != nil { // strings always encode
			panic(err)
		}
		sent = string(sb)
	}
	if c := r.CodeReview.clone(); c != nil {
		cb, err := json.Marshal(c)
		if err != nil { // strings and an int always encode
			panic(err)
		}
		review = string(cb)
	}
	if rr := r.ReviewReplies.clone(); rr != nil {
		rb, err := json.Marshal(rr)
		if err != nil { // strings, an int, and a bool always encode
			panic(err)
		}
		replies = string(rb)
	}
	return string(b), src, pr, shape, queue, notes, draft, sent, review, replies
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
	var shape, queue, draft, sent, review, replies string
	var notes sql.NullString
	var created, updated int64
	err := sc.Scan(&r.ID, &r.PlotID, &r.WorktreeID, &r.Folder, &r.Title, &r.Goal, &checks, &r.State, &r.Tries,
		&r.MaxTries, &r.SessionID, &r.Note, &src.Kind, &src.Key, &src.URL, &pr.Number, &pr.URL, &shape, &r.GroupID,
		&r.Turns, &r.TurnBase, &r.GateTimeouts, &r.BlockedStops, &queue, &notes, &draft, &r.ReviewTries, &sent, &review, &replies, &r.Fixes, &r.CIRerun, &r.CISent, &created, &updated)
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
	if sent != "" {
		if err := json.Unmarshal([]byte(sent), &r.ReviewsSent); err != nil {
			return Run{}, fmt.Errorf("run %s: bad sent reviews: %w", r.ID, err)
		}
	}
	if review != "" {
		var c RunCodeReview
		if err := json.Unmarshal([]byte(review), &c); err != nil {
			return Run{}, fmt.Errorf("run %s: bad code review: %w", r.ID, err)
		}
		r.CodeReview = c.clone()
	}
	if replies != "" {
		var rr RunReviewReplies
		if err := json.Unmarshal([]byte(replies), &rr); err != nil {
			return Run{}, fmt.Errorf("run %s: bad review replies: %w", r.ID, err)
		}
		r.ReviewReplies = rr.clone()
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

// addTryEvent adds the event of one try, with the stage that counted it.
func addTryEvent(tx *writeTx, runID string, at int64, note, stage string) error {
	return tx.exec(`INSERT INTO run_events(run_id, at, kind, detail, stage) VALUES (?, ?, 'try', ?, ?)`, runID, at, note, stage)
}
