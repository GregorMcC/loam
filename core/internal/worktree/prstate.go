package worktree

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/store"
)

// PRNote says why the ship state of a worktree is missing or old. It is the
// result of the last refresh of the worktree. It is empty after a refresh
// that got an answer from GitHub.
type PRNote string

// The notes. [PRNotes] lists them.
const (
	NoteGHMissing      PRNote = "gh_missing"
	NoteGHSignedOut    PRNote = "gh_signed_out"
	NoteNoAccess       PRNote = "no_access"
	NoteNoGitHubRemote PRNote = "no_github_remote"
	NoteOffline        PRNote = "offline"
	NoteRateLimited    PRNote = "rate_limited"
)

// PRNotes lists every note.
var PRNotes = []PRNote{NoteGHMissing, NoteGHSignedOut, NoteNoAccess, NoteNoGitHubRemote, NoteOffline, NoteRateLimited}

// noteOf returns the note of an error from the github package.
func noteOf(err error) PRNote {
	switch {
	case errors.Is(err, github.ErrGHMissing):
		return NoteGHMissing
	case errors.Is(err, github.ErrSignedOut):
		return NoteGHSignedOut
	case errors.Is(err, github.ErrNoAccess):
		return NoteNoAccess
	case errors.Is(err, github.ErrRateLimited):
		return NoteRateLimited
	}
	return NoteOffline
}

// cachedPR is the data of a row of the PR cache.
type cachedPR struct {
	PR     *github.PR `json:"pr"`
	Pushed bool       `json:"pushed"`
	// Stage is the stage of the PR from the GitHub state alone, with no
	// local checks. It is empty with no PR. The next refresh of the same PR
	// reads it as the last stage.
	Stage Stage `json:"stage"`
	// CompareURL is the compare page of a branch that is on GitHub.
	CompareURL string `json:"compare_url,omitempty"`
}

// decodeCached reads the data of a cache row. A row with no data, or with
// data that does not decode, has no ship state. The next refresh writes it again.
func decodeCached(row store.PRState) cachedPR {
	var c cachedPR
	if row.Data == "" || json.Unmarshal([]byte(row.Data), &c) != nil {
		return cachedPR{}
	}
	return c
}

// addPRState adds the cached ship state of the worktree and its stage. A
// worktree whose folder is gone gets no ship state. When the stage comes
// from the local checks (see [StageInput.UsesPR]), the worktree shows no PR.
func (st *Status) addPRState(row store.PRState) {
	c := decodeCached(row)
	in := StageInput{PR: c.PR, Pushed: c.Pushed, Missing: st.Missing, Changed: st.Changed, Unpushed: st.Unpushed, Last: c.Stage}
	if c.PR != nil && isDone(c.PR) && !st.Missing {
		in.HeadInPR = headInPR(st.Worktree.Path, c.PR.HeadOID, st.Unpushed)
	}
	st.Stage = StageOf(in)
	if st.Missing {
		return
	}
	if in.UsesPR() {
		st.PR = c.PR
	}
	st.PRNote = PRNote(row.Note)
	if !row.CheckedAt.IsZero() {
		at := row.CheckedAt
		st.PRCheckedAt = &at
	}
	if st.Stage == StagePushedNoPR {
		st.CompareURL = c.CompareURL
	}
}

// headInPR reports whether the commit that the worktree in dir has checked
// out is prHead or an earlier commit of it. GitHub can add commits to a PR,
// such as with Update branch, so the local HEAD can be behind the PR head.
// When the local repo does not have prHead, Loam cannot read the history of
// the PR. Then the HEAD counts as in the PR when every local commit is on a
// remote branch (unpushed is 0). When git fails, the HEAD is not in the PR.
func headInPR(dir, prHead string, unpushed int) bool {
	if !oidPattern.MatchString(prHead) {
		return false
	}
	head, err := git(dir, "rev-parse", "HEAD")
	if err != nil {
		return false
	}
	if head == prHead {
		return true
	}
	if _, err := git(dir, "cat-file", "-e", prHead+"^{commit}"); err != nil {
		return unpushed == 0
	}
	_, err = git(dir, "merge-base", "--is-ancestor", head, prHead)
	return err == nil
}

// oidPattern matches a full SHA-1 or SHA-256 commit ID. Loam checks a PR head
// from the cache before it gives it to git.
var oidPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

// RefreshPRs asks GitHub for the ship state of the worktrees and writes it to
// the PR cache. It runs the gh queries of each repo (see [github.Client.Fetch])
// at the same time as those of the other repos. It skips a worktree whose
// folder is gone, and a repo whose origin is not on GitHub gets no query.
// When a query fails, the cache keeps the last state, and the note says why.
//
// When ctx ends, gh stops, and RefreshPRs writes nothing and returns the
// error of ctx. Else it fails only when it cannot write the cache.
func RefreshPRs(ctx context.Context, s *store.Store, ws []store.Worktree) error {
	cache, err := s.PRStates()
	if err != nil {
		return err
	}
	var repos []string
	byRepo := map[string][]store.Worktree{}
	for _, w := range ws {
		if fi, err := os.Stat(w.Path); err != nil || !fi.IsDir() {
			continue
		}
		if _, ok := byRepo[w.Repo]; !ok {
			repos = append(repos, w.Repo)
		}
		byRepo[w.Repo] = append(byRepo[w.Repo], w)
	}
	client, clientErr := github.NewClient()
	results := make([]repoRefresh, len(repos))
	errs := make([]error, len(repos))
	var wg sync.WaitGroup
	for i, repo := range repos {
		wg.Go(func() { results[i], errs[i] = refreshRepo(ctx, client, clientErr, repo, byRepo[repo], cache) })
	}
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("the refresh stopped: %w", err)
	}
	if err := errors.Join(errs...); err != nil {
		return err
	}
	for _, r := range results {
		if err := r.write(s); err != nil {
			return err
		}
	}
	return nil
}

// repoRefresh is the result of the refresh of one repo: new rows, and the
// rows that keep their state and get the note of a failed query.
type repoRefresh struct {
	rows []store.PRState
	note PRNote
	keep []store.PRKey
}

// write writes the result to the PR cache. The store skips the row of a
// worktree that `loam worktree rm` removed while the refresh ran.
func (r repoRefresh) write(s *store.Store) error {
	if len(r.rows) > 0 {
		if err := s.SavePRStates(r.rows); err != nil {
			return err
		}
	}
	if len(r.keep) > 0 {
		return s.NotePRStates(string(r.note), r.keep)
	}
	return nil
}

// refreshRepo asks GitHub about the worktrees of one repo. clientErr is the
// error of [github.NewClient]. When the second query fails, a worktree with
// no PR, or with a merged or closed PR, still gets its new state, with the
// note. A worktree with an open PR keeps its state. refreshRepo fails only
// when it cannot encode a cache row.
func refreshRepo(ctx context.Context, client *github.Client, clientErr error, repoPath string, ws []store.Worktree, cache map[store.PRKey]store.PRState) (repoRefresh, error) {
	keys := make([]store.PRKey, len(ws))
	for i, w := range ws {
		keys[i] = store.PRKey{Repo: w.Repo, Branch: w.Branch}
	}
	ghRepo, ok := githubRepo(repoPath)
	if !ok {
		// The state of an old GitHub remote does not apply: clear it.
		rows := make([]store.PRState, len(keys))
		for i, k := range keys {
			rows[i] = store.PRState{PRKey: k, Note: string(NoteNoGitHubRemote)}
		}
		return repoRefresh{rows: rows}, nil
	}
	if clientErr != nil {
		return repoRefresh{note: noteOf(clientErr), keep: keys}, nil
	}
	branches := make([]string, len(ws))
	for i, w := range ws {
		branches[i] = w.Branch
	}
	var r repoRefresh
	got, err := client.Fetch(ctx, ghRepo, branches)
	if err != nil {
		r.note = noteOf(err)
	}
	now := time.Now()
	for i, w := range ws {
		b, ok := got[w.Branch]
		if !ok {
			r.keep = append(r.keep, keys[i])
			continue
		}
		c := cachedPR{PR: b.PR, Pushed: b.Pushed}
		if b.PR != nil {
			last := StageNone
			if old := decodeCached(cache[keys[i]]); old.PR != nil && old.PR.Number == b.PR.Number {
				last = old.Stage
			}
			c.Stage = prStage(b.PR, last)
		}
		if b.Pushed {
			c.CompareURL = ghRepo.CompareURL(compareBase(w), w.Branch)
		}
		data, err := json.Marshal(c)
		if err != nil {
			return repoRefresh{}, err
		}
		r.rows = append(r.rows, store.PRState{PRKey: keys[i], Data: string(data), CheckedAt: now, Note: string(r.note)})
	}
	return r, nil
}

// compareBase returns the base of the compare page of a worktree: the branch
// of origin that the worktree started from. It is empty for a local base, or
// none, because GitHub may not have that branch. Then GitHub compares with
// its default branch.
func compareBase(w store.Worktree) string {
	if base, ok := strings.CutPrefix(w.Base, remote+"/"); ok {
		return base
	}
	return ""
}

// githubRepo returns the GitHub repo of the origin remote of a repo. It
// returns false when the repo has no origin, or origin is not on GitHub.
func githubRepo(repoPath string) (github.Repo, bool) {
	u, err := git(repoPath, "remote", "get-url", remote)
	if err != nil {
		return github.Repo{}, false
	}
	web, ok := gitremote.WebURL(u)
	if !ok {
		return github.Repo{}, false
	}
	return github.ParseRepo(web)
}
