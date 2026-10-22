package worktree

import (
	"context"
	"encoding/json"
	"errors"
	"os"
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
	NoteNoGitHubRemote PRNote = "no_github_remote"
	NoteOffline        PRNote = "offline"
	NoteRateLimited    PRNote = "rate_limited"
)

// PRNotes lists every note.
var PRNotes = []PRNote{NoteGHMissing, NoteGHSignedOut, NoteNoGitHubRemote, NoteOffline, NoteRateLimited}

// noteOf returns the note of an error from the github package.
func noteOf(err error) PRNote {
	switch {
	case errors.Is(err, github.ErrGHMissing):
		return NoteGHMissing
	case errors.Is(err, github.ErrSignedOut):
		return NoteGHSignedOut
	case errors.Is(err, github.ErrRateLimited):
		return NoteRateLimited
	}
	return NoteOffline
}

// cachedPR is the data of a row of the PR cache.
type cachedPR struct {
	PR     *github.PR `json:"pr"`
	Pushed bool       `json:"pushed"`
	// Stage is the stage from the GitHub state alone, with no local checks.
	// The next refresh of the same PR reads it as the last stage.
	Stage      Stage  `json:"stage"`
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
// worktree whose folder is gone gets no ship state.
func (st *Status) addPRState(row store.PRState) {
	c := decodeCached(row)
	st.Stage = StageOf(StageInput{PR: c.PR, Pushed: c.Pushed, Missing: st.Missing, Changed: st.Changed, Unpushed: st.Unpushed, Last: c.Stage})
	if st.Missing {
		return
	}
	st.PR = c.PR
	st.PRNote = PRNote(row.Note)
	if !row.CheckedAt.IsZero() {
		at := row.CheckedAt
		st.PRCheckedAt = &at
	}
	if st.Stage == StagePushedNoPR {
		st.CompareURL = c.CompareURL
	}
}

// RefreshPRs asks GitHub for the ship state of the worktrees and writes it to
// the PR cache. It runs the gh queries of each repo (see [github.Client.Fetch])
// at the same time as those of the other repos. It skips a worktree whose
// folder is gone, and a repo whose origin is not on GitHub gets no query.
// When a query fails, the cache keeps the last state, and the note says why.
// RefreshPRs fails only when it cannot write the cache.
func RefreshPRs(s *store.Store, ws []store.Worktree) error {
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
		wg.Go(func() { results[i], errs[i] = refreshRepo(client, clientErr, repo, byRepo[repo], cache) })
	}
	wg.Wait()
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

// repoRefresh is the result of the refresh of one repo: new rows, or a note
// for rows that keep their state.
type repoRefresh struct {
	rows []store.PRState
	note PRNote
	keep []store.PRKey
}

func (r repoRefresh) write(s *store.Store) error {
	if r.note != "" {
		return s.NotePRStates(string(r.note), r.keep)
	}
	return s.SavePRStates(r.rows)
}

// refreshRepo asks GitHub about the worktrees of one repo. clientErr is the
// error of [github.NewClient]. It fails only when it cannot encode a cache row.
func refreshRepo(client *github.Client, clientErr error, repoPath string, ws []store.Worktree, cache map[store.PRKey]store.PRState) (repoRefresh, error) {
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
	got, err := client.Fetch(context.Background(), ghRepo, branches)
	if err != nil {
		return repoRefresh{note: noteOf(err), keep: keys}, nil
	}
	now := time.Now()
	rows := make([]store.PRState, len(ws))
	for i, w := range ws {
		b := got[w.Branch]
		last := StageNone
		if old := decodeCached(cache[keys[i]]); old.PR != nil && b.PR != nil && old.PR.Number == b.PR.Number {
			last = old.Stage
		}
		c := cachedPR{PR: b.PR, Pushed: b.Pushed, Stage: StageOf(StageInput{PR: b.PR, Pushed: b.Pushed, Last: last})}
		if c.Stage == StagePushedNoPR {
			c.CompareURL = ghRepo.CompareURL(strings.TrimPrefix(w.Base, remote+"/"), w.Branch)
		}
		data, err := json.Marshal(c)
		if err != nil {
			return repoRefresh{}, err
		}
		rows[i] = store.PRState{PRKey: keys[i], Data: string(data), CheckedAt: now}
	}
	return repoRefresh{rows: rows}, nil
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
