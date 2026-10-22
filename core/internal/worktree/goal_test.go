package worktree_test

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

const (
	linearIssue = "https://linear.app/example/issue/ENG-482/link-kinds-for-figma"
	githubIssue = "https://github.com/example/widgets/issues/57"
)

// addLink adds a link to the plot of e and returns its ID.
func (e *env) addLink(label, target string) string {
	e.t.Helper()
	res, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S(label), Target: store.S(target)}}})
	if err != nil {
		e.t.Fatal(err)
	}
	return strings.TrimPrefix(res.Added[0], "link:")
}

func (e *env) seedText() string {
	e.t.Helper()
	b, err := os.ReadFile(seed.Path(e.s, e.plot.ID))
	if err != nil {
		e.t.Fatal(err)
	}
	return string(b)
}

func TestCreateWithAGoalAndAPlotLink(t *testing.T) {
	e := setup(t)
	linkID := e.addLink("Link kinds for Figma", linearIssue)
	before, _ := e.s.GetPlot(e.plot.ID)
	res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "eng-482",
		Goal: "Link kinds for Figma", Link: linkID})
	if err != nil {
		t.Fatal(err)
	}
	w := res.Worktree
	want := store.WorktreeLink{Target: linearIssue, Label: "Link kinds for Figma", Key: "ENG-482", LinkID: linkID}
	if w.Goal != "Link kinds for Figma" || w.Link == nil || *w.Link != want {
		t.Fatalf("%+v %+v", w, w.Link)
	}
	if rec, _ := e.s.GetWorktree(w.ID); rec.Goal != w.Goal || *rec.Link != want {
		t.Fatalf("record %+v", rec)
	}
	// A worktree add is not a change.
	if after, _ := e.s.GetPlot(e.plot.ID); after.Revision != before.Revision {
		t.Fatalf("revision moved from %d to %d", before.Revision, after.Revision)
	}
	// The seed lists the worktree.
	if got := e.seedText(); !strings.Contains(got, "- app-eng-482: Link kinds for Figma (ENG-482, from origin/main)\n") {
		t.Fatalf("seed:\n%s", got)
	}
}

func TestCreateWithAnIssueURL(t *testing.T) {
	e := setup(t)
	res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "fix-57", Link: githubIssue})
	if err != nil {
		t.Fatal(err)
	}
	// The origin of the repo is not on GitHub, so the key names the repo.
	want := store.WorktreeLink{Target: githubIssue, Label: "widgets#57", Key: "example/widgets#57"}
	if l := res.Worktree.Link; l == nil || *l != want {
		t.Fatalf("%+v", l)
	}
	// The URL stays on the worktree. It does not go into the plot's links.
	if p, _ := e.s.GetPlot(e.plot.ID); len(p.Links) != 0 {
		t.Fatalf("links %+v", p.Links)
	}
}

// GitHub reads "Fixes #57" as an issue of the repo that the PR goes to. So
// the key of a GitHub issue is "#57" only when the issue is in the repo of
// origin. Else the key names the repo. The record and the seed show the key
// that the worktree got when Loam made it.
func TestTheIssueKeyFollowsTheRepoOfOrigin(t *testing.T) {
	for _, c := range []struct{ name, origin, key string }{
		{"same repo", "git@github.com:Example/Widgets.git", "#57"},
		{"another repo", "https://github.com/example/gadgets.git", "example/widgets#57"},
		// The bare remote of setup is a folder, not a GitHub repo.
		{"no GitHub origin", "", "example/widgets#57"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := setup(t)
			if c.origin != "" {
				// No command may reach GitHub. The fetch of Create fails,
				// and the worktree starts from the last fetched state.
				t.Setenv("GIT_ALLOW_PROTOCOL", "file")
				testutil.Git(t, e.repo, "remote", "set-url", "origin", c.origin)
			}
			linkID := e.addLink("The issue", githubIssue)
			for _, link := range []string{githubIssue, linkID} {
				name := "fix-57-" + strings.ReplaceAll(strings.TrimPrefix(link, "https://"), "/", "-")
				res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: name,
					Goal: "Fix the login form", Link: link})
				if err != nil {
					t.Fatal(err)
				}
				if l := res.Worktree.Link; l == nil || l.Key != c.key {
					t.Fatalf("%s: link %+v, want the key %q", link, l, c.key)
				}
				if rec, _ := e.s.GetWorktree(res.Worktree.ID); rec.Link == nil || rec.Link.Key != c.key {
					t.Fatalf("%s: record %+v", link, rec.Link)
				}
				line := "- app-" + name + ": Fix the login form (" + c.key + ", from origin/main)\n"
				if got := e.seedText(); !strings.Contains(got, line) {
					t.Fatalf("%s: seed has no line %q:\n%s", link, line, got)
				}
			}
		})
	}
}

func TestCreateWithALongGoalWarns(t *testing.T) {
	e := setup(t)
	res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "long",
		Goal: strings.Repeat("word ", 24)})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(res.Warnings, "The goal has 24 words. The soft limit is 20 words. Shorten it.") {
		t.Fatalf("warnings %q", res.Warnings)
	}
}

func TestCreateRefusesABadLinkBeforeItChangesAnything(t *testing.T) {
	e := setup(t)
	notIssue := e.addLink("Spec", "https://example.com/spec")
	for _, c := range []struct {
		link string
		want error
	}{
		{"https://github.com/example/widgets/pull/57", store.ErrInvalid},
		{"https://example.com/spec", store.ErrInvalid},
		{"https://linear.app/example/project/widgets", store.ErrInvalid},
		{"nosuchlink", store.ErrNotFound},
	} {
		_, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "bad", Link: c.link})
		if !errors.Is(err, c.want) {
			t.Errorf("%s: %v", c.link, err)
		}
	}
	if ws, _ := e.s.ListWorktrees(e.plot.ID); len(ws) != 0 {
		t.Fatalf("records %+v", ws)
	}
	if _, err := os.Stat(filepath.Join(e.home, "worktrees", e.plot.ID, "app-bad")); !os.IsNotExist(err) {
		t.Fatalf("folder: %v", err)
	}
	if out := testutil.Git(t, e.repo, "branch", "--list", "bad"); out != "" {
		t.Fatalf("branch %q", out)
	}
	// A plot link that is not an issue is fine: only a URL must be an issue.
	res, err := worktree.Create(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "spec", Link: notIssue})
	if err != nil || res.Worktree.Link.Key != "" || res.Worktree.Link.LinkID != notIssue {
		t.Fatalf("%+v %v", res, err)
	}
}

func TestNewAndRemoveRewriteTheSeed(t *testing.T) {
	e := setup(t)
	if err := seed.Write(e.s, e.plot.ID); err != nil {
		t.Fatal(err)
	}
	if got := e.seedText(); strings.Contains(got, "## Worktrees") {
		t.Fatalf("seed:\n%s", got)
	}
	w := e.create("fix-x", "").Worktree
	if got := e.seedText(); !strings.Contains(got, "## Worktrees\n\n- app-fix-x (from origin/main)\n") {
		t.Fatalf("after new:\n%s", got)
	}
	if _, err := worktree.Remove(e.s, e.plot.ID, w.ID, worktree.RemoveOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := e.seedText(); strings.Contains(got, "## Worktrees") || strings.Contains(got, "app-fix-x") {
		t.Fatalf("after rm:\n%s", got)
	}
}

// refs lists every ref of the repo, so a test can see that a dry run moved none.
func refs(t *testing.T, repo string) string {
	t.Helper()
	return testutil.Git(t, repo, "for-each-ref", "--format=%(refname) %(objectname)")
}

func TestCheckChangesNothing(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "checkout", "-b", "develop")
	commit(t, e.repo, "dev.txt", "d\n")
	testutil.Git(t, e.repo, "push", "origin", "develop")
	testutil.Git(t, e.repo, "checkout", "main")
	// The remote has a branch that the repo has not fetched.
	other := filepath.Join(t.TempDir(), "other")
	testutil.Git(t, filepath.Dir(other), "clone", e.remote, other)
	testutil.Git(t, other, "checkout", "-b", "unfetched")
	testutil.Git(t, other, "push", "origin", "unfetched")
	before := refs(t, e.repo)

	check := func(name string) *worktree.CheckResult {
		t.Helper()
		res, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: name})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return res
	}

	got := check("fix-login")
	if !got.ValidName || got.NameError != "" || got.BranchExists || got.WorktreeExists || got.Folder != "app-fix-login" ||
		got.DefaultBase != "origin/main" {
		t.Fatalf("new name: %+v", got)
	}
	if !slices.Equal(got.Bases, []string{"origin/main", "origin/develop", "develop", "main"}) {
		t.Fatalf("bases %q", got.Bases)
	}
	if got := check("a b"); got.ValidName || !strings.Contains(got.NameError, "branch name") || got.BranchExists {
		t.Fatalf("bad name: %+v", got)
	}
	if got := check("develop"); !got.ValidName || !got.BranchExists {
		t.Fatalf("local and remote branch: %+v", got)
	}
	testutil.Git(t, e.repo, "branch", "local-only")
	before = refs(t, e.repo)
	if got := check("local-only"); !got.BranchExists {
		t.Fatalf("local branch: %+v", got)
	}
	// The dry run does not fetch, so it knows only the last fetched branches.
	if got := check("unfetched"); got.BranchExists {
		t.Fatalf("unfetched branch: %+v", got)
	}
	e.create("taken", "")
	before = refs(t, e.repo)
	if got := check("taken"); !got.WorktreeExists {
		t.Fatalf("existing worktree: %+v", got)
	}

	if after := refs(t, e.repo); after != before {
		t.Fatalf("a dry run moved refs:\n%s\nwant:\n%s", after, before)
	}
	if ws, _ := e.s.ListWorktrees(e.plot.ID); len(ws) != 1 {
		t.Fatalf("records %+v", ws)
	}
	if _, err := os.Stat(filepath.Join(e.home, "worktrees", e.plot.ID, "app-fix-login")); !os.IsNotExist(err) {
		t.Fatalf("folder: %v", err)
	}
}

func TestCheckRefusesWhatCreateRefuses(t *testing.T) {
	e := setup(t)
	check := func(o worktree.CreateOptions) error {
		o.PlotID = e.plot.ID
		if o.Repo == "" {
			o.Repo = e.repo
		}
		_, err := worktree.Check(e.s, o)
		return err
	}
	if err := check(worktree.CreateOptions{Name: "x", Repo: "/not/a/repo"}); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("repo: %v", err)
	}
	if err := check(worktree.CreateOptions{Name: "x", Link: "https://example.com/spec"}); !errors.Is(err, store.ErrInvalid) {
		t.Errorf("link: %v", err)
	}
	if err := check(worktree.CreateOptions{Name: "x", Base: "no-such-base"}); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("base: %v", err)
	}
}

// The New worktree sheet runs the dry run as you type, with the base that it
// shows. A name whose branch exists is a result: the branch exists, and the
// base does not apply. worktree new still refuses a base for it.
func TestCheckSkipsTheBaseForABranchThatExists(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "branch", "local-only")
	for _, c := range []struct{ name, base string }{
		{"main", "main"},              // a local branch and a branch of origin
		{"local-only", "origin/main"}, // a local branch
		{"main", "no-such-base"},      // the base is not checked at all
	} {
		o := worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: c.name, Base: c.base}
		res, err := worktree.Check(e.s, o)
		if err != nil {
			t.Fatalf("%s from %s: %v", c.name, c.base, err)
		}
		if !res.ValidName || !res.BranchExists || res.WorktreeExists {
			t.Fatalf("%s from %s: %+v", c.name, c.base, res)
		}
		if _, err := worktree.Create(e.s, o); !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), "--base does not apply") {
			t.Fatalf("create %s from %s: %v", c.name, c.base, err)
		}
	}
	// A new branch still needs a base that works.
	if _, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "new", Base: "no-such-base"}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("new branch from a missing base: %v", err)
	}
}

// The New worktree sheet shows the seed line of the worktree before it exists.
// The dry run builds it with the code that writes the seed, so the line in the
// sheet is the line that Create then puts in the seed.
func TestCheckShowsTheSeedLineThatCreateWrites(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "branch", "local-only")
	for _, c := range []struct {
		name string
		o    worktree.CreateOptions
		line string
	}{
		{"goal, link and the default base", worktree.CreateOptions{Name: "eng-482", Goal: "Link kinds for Figma", Link: linearIssue},
			"- app-eng-482: Link kinds for Figma (ENG-482, from origin/main)"},
		// A base that names a local branch uses the local branch.
		{"a base that the app picked", worktree.CreateOptions{Name: "fix-57", Base: "main", Link: githubIssue},
			"- app-fix-57 (example/widgets#57, from main)"},
		{"nothing but the name", worktree.CreateOptions{Name: "plain"}, "- app-plain (from origin/main)"},
		// A branch that exists keeps its history, so the worktree has no base.
		{"a branch that exists", worktree.CreateOptions{Name: "local-only", Goal: "Pick it up"}, "- app-local-only: Pick it up"},
	} {
		t.Run(c.name, func(t *testing.T) {
			c.o.PlotID, c.o.Repo = e.plot.ID, e.repo
			res, err := worktree.Check(e.s, c.o)
			if err != nil {
				t.Fatal(err)
			}
			if res.SeedLine != c.line {
				t.Fatalf("seed line %q, want %q", res.SeedLine, c.line)
			}
			if _, err := worktree.Create(e.s, c.o); err != nil {
				t.Fatal(err)
			}
			if got := e.seedText(); !strings.Contains(got, c.line+"\n") {
				t.Fatalf("the seed has no line %q:\n%s", c.line, got)
			}
		})
	}
	// A name that is not a branch name has no worktree, so it has no line.
	res, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "a b"})
	if err != nil || res.SeedLine != "" {
		t.Fatalf("%+v %v", res, err)
	}
}

// The sheet opens before you type a name, and it lists the bases at once. An
// empty name is a result, not a failure.
func TestCheckListsTheBasesForAnEmptyName(t *testing.T) {
	e := setup(t)
	res, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: ""})
	if err != nil {
		t.Fatal(err)
	}
	if res.ValidName || res.NameError == "" || res.SeedLine != "" || res.BranchExists || res.WorktreeExists ||
		res.DefaultBase != "origin/main" || !slices.Equal(res.Bases, []string{"origin/main", "main"}) {
		t.Fatalf("%+v", res)
	}
}

func TestCheckWithoutARemote(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "remote", "remove", "origin")
	res, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if res.DefaultBase != "" || !slices.Equal(res.Bases, []string{"main"}) {
		t.Fatalf("%+v", res)
	}
}

// The dry run never asks the remote. Without origin/HEAD from a fetch, it
// does not know the default base, though the remote would say main.
func TestCheckDoesNotAskTheRemote(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "remote", "set-head", "origin", "--delete")
	res, err := worktree.Check(e.s, worktree.CreateOptions{PlotID: e.plot.ID, Repo: e.repo, Name: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if res.DefaultBase != "" || !slices.Equal(res.Bases, []string{"origin/main", "main"}) {
		t.Fatalf("%+v", res)
	}
}
