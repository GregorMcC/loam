package store

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// BriefWordLimit is the soft limit for What, Why, and Where it stands
// together. A longer brief saves, and the result carries a warning.
const BriefWordLimit = 300

// Item names for the versioned parts of a plot.
const (
	ItemName  = "name"
	ItemWhat  = "what"
	ItemWhy   = "why"
	ItemWhere = "where"
)

// LinkItem returns the item name of a link, for example "link:k3v9q2mxa7".
func LinkItem(id string) string { return "link:" + id }

// RepoItem returns the item name of a repo, for example "repo:k3v9q2mxa7".
func RepoItem(id string) string { return "repo:" + id }

// Plot is a full plot with the version of each item.
type Plot struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	What      string    `json:"what"`
	Why       string    `json:"why"`
	Where     string    `json:"where_it_stands"`
	CreatedAt time.Time `json:"created_at"`
	// Archived is true for a plot that you put away. It is not a versioned item.
	Archived bool   `json:"archived"`
	Links    []Link `json:"links"`
	Repos    []Repo `json:"repos"`
	// Versions maps each current item to the ID of the change that last set it.
	Versions map[string]int64 `json:"versions"`
	// Revision is the highest change ID of the plot. The seed records it.
	Revision int64 `json:"revision"`
}

// MainRepo returns the main repo, or nil when the plot has no repos.
func (p Plot) MainRepo() *Repo {
	for i := range p.Repos {
		if p.Repos[i].Main {
			return &p.Repos[i]
		}
	}
	return nil
}

// PlotSummary is one row of the plot list.
type PlotSummary struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	What      string    `json:"what"`
	CreatedAt time.Time `json:"created_at"`
	Archived  bool      `json:"archived"`
}

// Link is a labelled pointer to an outside resource. Target is a URL or a
// local path.
type Link struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Target   string `json:"target"`
	Note     string `json:"note"`
	Position int    `json:"position"`
	Version  int64  `json:"version"`
}

// Repo is a local git checkout that a plot holds. Path is absolute.
type Repo struct {
	ID      string `json:"id"`
	Path    string `json:"path"`
	Note    string `json:"note"`
	Main    bool   `json:"main"`
	Version int64  `json:"version"`
	// Setup and Copy are the worktree settings of the repo path. Every plot
	// that holds the path sees the same values. They are not in the change log.
	Setup string   `json:"setup,omitempty"`
	Copy  []string `json:"copy,omitempty"`
}

// PlotInput is the content of a new plot. Link and repo edits use the same
// rules as [Store.Apply]. The first repo becomes the main repo.
type PlotInput struct {
	Name, What, Why, Where string
	Links                  []LinkInput
	Repos                  []RepoInput
}

// LinkInput is a new link.
type LinkInput struct{ Label, Target, Note string }

// RepoInput is a new repo.
type RepoInput struct{ Path, Note string }

// ActorKind says who made a change.
type ActorKind string

// The kinds of actor.
const (
	ActorCLI     ActorKind = "cli"
	ActorApp     ActorKind = "app"
	ActorSession ActorKind = "session"
)

// Actor is who made a change. A session actor has a session ID and says
// whether Loam started the session. Use [Store.SessionActor] to fill
// LoamStarted from the session records.
type Actor struct {
	Kind        ActorKind `json:"kind"`
	SessionID   string    `json:"session_id,omitempty"`
	LoamStarted bool      `json:"loam_started,omitempty"`
}

// Op is the kind of one edit.
type Op string

// The edit operations.
const (
	OpSet         Op = "set"           // Item: name, what, why, or where. Value: the text.
	OpAddLink     Op = "add_link"      // Label, Target, Note.
	OpUpdateLink  Op = "update_link"   // Item: link:<id>. Label, Target, Note: only the non-nil ones.
	OpRemoveLink  Op = "remove_link"   // Item: link:<id>.
	OpAddRepo     Op = "add_repo"      // Path (absolute), Note.
	OpUpdateRepo  Op = "update_repo"   // Item: repo:<id>. Note.
	OpRemoveRepo  Op = "remove_repo"   // Item: repo:<id>.
	OpSetMainRepo Op = "set_main_repo" // Item: repo:<id>.
)

// Edit is one edit inside a change. Only the fields that the Op names are used.
type Edit struct {
	Op                        Op
	Item                      string
	Value                     string
	Label, Target, Path, Note *string
}

// S returns a pointer to s, for the optional fields of [Edit].
func S(s string) *string { return &s }

// Change is a request to change one plot.
type Change struct {
	PlotID string
	Actor  Actor
	// Expect maps an item to the version that the caller read. If any listed
	// item has another version now, nothing is written. A caller that sends no
	// expectation writes over the latest value.
	Expect map[string]int64
	Edits  []Edit
}

// Result is the outcome of a write.
type Result struct {
	// ChangeID is the new change ID. It is 0 when the edits changed nothing,
	// and then the store wrote nothing.
	ChangeID int64
	// Plot is the plot after the change.
	Plot Plot
	// Added holds the item names of the links and repos that the change made.
	Added []string
	// Warnings are for a person to read, for example a brief that is too long.
	Warnings []string
}

// Entry is one changed field in the change log. A nil Old means the item did
// not exist before. A nil New means the change removed the item.
type Entry struct {
	Item  string  `json:"item"`
	Field string  `json:"field"`
	Old   *string `json:"old"`
	New   *string `json:"new"`
}

// ChangeRecord is one change with its entries.
type ChangeRecord struct {
	ID      int64     `json:"id"`
	PlotID  string    `json:"plot_id"`
	At      time.Time `json:"at"`
	Actor   Actor     `json:"actor"`
	Entries []Entry   `json:"entries"`
	// UndoOf is the ID of the change that this change reverted, or nil.
	UndoOf *int64 `json:"undo_of"`
}

// ChangeQuery selects changes. A zero PlotID means every plot.
type ChangeQuery struct {
	PlotID string
	// SinceID returns only changes with an ID above it.
	SinceID int64
	// Limit caps the number of changes. Zero means no cap.
	Limit int
	// Newest returns the newest change first. The default is oldest first.
	Newest bool
}

// SessionRecord is a session that Loam started.
type SessionRecord struct {
	SessionID   string    `json:"session_id"`
	PlotID      string    `json:"plot_id"`
	StartFolder string    `json:"start_folder"`
	CreatedAt   time.Time `json:"created_at"`
}

// Errors that callers test with errors.Is.
var (
	ErrNotFound  = errors.New("not found")
	ErrInvalid   = errors.New("invalid input")
	ErrDuplicate = errors.New("already exists")
	// ErrNeedMainRepo means a change removed the main repo and more than one
	// repo remains. Add an OpSetMainRepo edit to the same change.
	ErrNeedMainRepo = errors.New("the main repo was removed: pick a new main repo")
	// ErrArchived means the plot is archived, and the call needs an active plot.
	ErrArchived = errors.New("the plot is archived")
	// ErrNotArchived means the plot is not archived, and the call needs an archived plot.
	ErrNotArchived = errors.New("the plot is not archived")
	// ErrHasWorktrees means the plot still has worktrees of the repo.
	ErrHasWorktrees = errors.New("the plot has worktrees of this repo")
)

// StaleItem is one item that changed after the caller read it.
type StaleItem struct {
	Item     string `json:"item"`
	Expected int64  `json:"expected"`
	Current  int64  `json:"current"`
	// Exists is false when the item is gone now.
	Exists bool `json:"exists"`
	// Value is the current text of name, what, why, or where.
	Value string `json:"value,omitempty"`
	Link  *Link  `json:"link,omitempty"`
	Repo  *Repo  `json:"repo,omitempty"`
}

// StaleError is the error of a write whose expectations no longer hold.
type StaleError struct {
	PlotID string      `json:"plot_id"`
	Items  []StaleItem `json:"items"`
}

func (e *StaleError) Error() string {
	names := make([]string, len(e.Items))
	for i, it := range e.Items {
		names[i] = it.Item
	}
	return fmt.Sprintf("stale write: %s changed since you read it", strings.Join(names, ", "))
}

// BriefWords counts the words in What, Why, and Where it stands.
func BriefWords(what, why, where string) int {
	return len(strings.Fields(what)) + len(strings.Fields(why)) + len(strings.Fields(where))
}
