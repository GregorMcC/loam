package session_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-175: a run session works in a sandbox. Its settings deny home and allow
// the repos and the local links of the plot, the git folder, and the caches
// of the stacks that the repos name. A URL link is not a path, so it is not in
// the lists. The sandbox lets Bash write each --add-dir folder, so the session
// adds only the plot folder, which holds the seed, and the sandbox denies
// writes to it.
func TestPrepareRunSandboxesTheSession(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	if err := os.WriteFile(filepath.Join(other, "Package.swift"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	spec := filepath.Join(t.TempDir(), "spec.md")
	p := e.plot(t, store.PlotInput{
		Name:  "Alpha",
		Repos: []store.RepoInput{{Path: repo}, {Path: other}},
		Links: []store.LinkInput{{Label: "Spec", Target: spec}, {Label: "Site", Target: "https://example.com"}},
	})
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if last := plan.Args[len(plan.Args)-1]; !strings.HasPrefix(last, "go\n\nBash works in a sandbox.") || !strings.Contains(last, "--disable-sandbox") {
		t.Errorf("prompt = %q, want the goal and then the sandbox note of the Swift repo", last)
	}
	plotDir := e.store.PlotDir(p.ID)
	if got := argValues(plan.Args, "--add-dir"); !slices.Equal(got, []string{plotDir}) {
		t.Errorf("--add-dir = %q, want only the plot folder %s", got, plotDir)
	}
	files := argValues(plan.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("args %v have no one --settings", plan.Args)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Permissions struct{ Deny []string }
		Sandbox     struct {
			Enabled, FailIfUnavailable, AllowUnsandboxedCommands bool
			Network                                              struct {
				AllowedDomains  []string
				StrictAllowlist bool
			}
			Filesystem struct{ DenyRead, AllowRead, AllowWrite, DenyWrite []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	sb := got.Sandbox
	if !sb.Enabled || !sb.FailIfUnavailable || sb.AllowUnsandboxedCommands || !sb.Network.StrictAllowlist {
		t.Errorf("sandbox locks = %+v, want enabled, failIfUnavailable, no unsandboxed commands, strict allowlist", sb)
	}
	home, _ := os.UserHomeDir()
	if !slices.Equal(sb.Filesystem.DenyRead, []string{realpath(t, home)}) {
		t.Errorf("denyRead = %q, want the home folder", sb.Filesystem.DenyRead)
	}
	real := realpath(t, repo)
	git := filepath.Join(real, ".git")
	for _, want := range []string{real, git, filepath.Join(realpath(t, filepath.Dir(spec)), "spec.md")} {
		if !slices.Contains(sb.Filesystem.AllowRead, want) {
			t.Errorf("allowRead = %q, want %s", sb.Filesystem.AllowRead, want)
		}
	}
	for _, want := range []string{real, git} {
		if !slices.Contains(sb.Filesystem.AllowWrite, want) {
			t.Errorf("allowWrite = %q, want %s", sb.Filesystem.AllowWrite, want)
		}
	}
	if !slices.Contains(sb.Filesystem.AllowRead, realpath(t, other)) {
		t.Errorf("allowRead = %q, want the other repo", sb.Filesystem.AllowRead)
	}
	if slices.Contains(sb.Filesystem.AllowWrite, realpath(t, other)) {
		t.Errorf("allowWrite = %q has the other repo", sb.Filesystem.AllowWrite)
	}
	if !slices.Contains(sb.Filesystem.DenyWrite, realpath(t, plotDir)) {
		t.Errorf("denyWrite = %q, want the plot folder", sb.Filesystem.DenyWrite)
	}
	if !slices.Contains(got.Permissions.Deny, "Edit(/"+realpath(t, plotDir)+"/**)") {
		t.Errorf("permissions.deny = %q, want the plot folder for the Edit tool", got.Permissions.Deny)
	}
	if slices.Contains(sb.Filesystem.AllowRead, "https://example.com") {
		t.Errorf("allowRead = %q has the URL link", sb.Filesystem.AllowRead)
	}
	if !slices.Contains(sb.Network.AllowedDomains, "proxy.golang.org") {
		t.Errorf("allowedDomains = %q, want the Go proxy", sb.Network.AllowedDomains)
	}
	if !slices.Contains(got.Permissions.Deny, "Read(~/.ssh/**)") {
		t.Errorf("permissions.deny = %q, want the credential paths", got.Permissions.Deny)
	}
}

// Git reads the files that a git config includes, so the sandbox allows each
// config file that git names for the run folder, and not only the usual ones.
func TestPrepareRunAllowsTheGitConfigFilesThatGitReads(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	global := os.Getenv("GIT_CONFIG_GLOBAL")
	extra := filepath.Join(filepath.Dir(global), "extra.gitconfig")
	if err := os.WriteFile(extra, []byte("[core]\n\tautocrlf = false\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(global, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("[include]\n\tpath = extra.gitconfig\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(argValues(plan.Args, "--settings")[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Sandbox struct {
			Filesystem struct{ AllowRead []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{realpath(t, global), realpath(t, extra)} {
		if !slices.Contains(got.Sandbox.Filesystem.AllowRead, want) {
			t.Errorf("allowRead = %q, want %s", got.Sandbox.Filesystem.AllowRead, want)
		}
	}
}

// TAS-194: git opens the file of an includeIf whose condition does not hold
// when the condition is hasconfig, and stops when the sandbox denies it. So
// the sandbox allows the file of each include and includeIf, and the files
// that it includes. It does not follow an include in a file that the run can
// write, also when git takes that include, because the run could name any
// file there.
func TestPrepareRunAllowsTheFilesOfEachIncludeIf(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	global := os.Getenv("GIT_CONFIG_GLOBAL")
	dir := filepath.Dir(global)
	repo, _ := testutil.GitRepo(t)
	work := filepath.Join(dir, "work.gitconfig")
	nested := filepath.Join(dir, "nested", "more.gitconfig")
	local := filepath.Join(repo, "local.gitconfig")
	secret := filepath.Join(dir, "secret")
	other := filepath.Join(dir, "other.gitconfig")
	for f, text := range map[string]string{
		other:  "[user]\n\tname = other\n",
		work:   "[include]\n\tpath = nested/more.gitconfig\n",
		nested: "[core]\n\tautocrlf = false\n",
		local:  "[include]\n\tpath = " + secret + "\n",
		secret: "[user]\n\tname = secret\n",
	} {
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	f, err := os.OpenFile(global, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("[includeIf \"hasconfig:remote.*.url:git@example.com:org/**\"]\n\tpath = work.gitconfig\n" +
		"[include]\n\tpath = " + local + "\n" +
		"[includeIf \"gitdir:/nowhere/\"]\n\tpath = other.gitconfig\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(argValues(plan.Args, "--settings")[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Sandbox struct {
			Filesystem struct{ AllowRead []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	read := got.Sandbox.Filesystem.AllowRead
	for _, want := range []string{realpath(t, work), realpath(t, nested), realpath(t, local)} {
		if !slices.Contains(read, want) {
			t.Errorf("allowRead = %q, want %s", read, want)
		}
	}
	if slices.Contains(read, realpath(t, secret)) {
		t.Errorf("allowRead = %q has %s, which an include in a file of the run names", read, secret)
	}
	// Git does not open the file of a gitdir condition that does not hold.
	if slices.Contains(read, realpath(t, other)) {
		t.Errorf("allowRead = %q has %s, whose includeIf does not hold", read, other)
	}
	if prompt := plan.Args[len(plan.Args)-1]; !strings.Contains(prompt, "The run can write the git config "+realpath(t, local)) && !strings.Contains(prompt, "The run can write the git config "+local) {
		t.Errorf("prompt = %q, want a note on %s", prompt, local)
	}
}

// TAS-175: the machine settings and the plot settings of the sandbox reach
// the settings file of a run. The settings of another plot do not.
func TestPrepareRunAddsTheSandboxSettings(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	other := e.plot(t, store.PlotInput{Name: "Beta"})
	home, _ := os.UserHomeDir()
	for _, set := range []store.SandboxSettings{
		{Read: []string{"~/.nvm"}, Hosts: []string{"machine.example.com"}},
		{PlotID: p.ID, Write: []string{"~/Library/Caches/Loam"}, Hosts: []string{"*.example.org"}},
		{PlotID: other.ID, Read: []string{"~/beta-only"}, Hosts: []string{"beta.example.com"}},
	} {
		if _, err := e.store.SetSandboxSettings(set); err != nil {
			t.Fatal(err)
		}
	}
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(argValues(plan.Args, "--settings")[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Sandbox struct {
			Network    struct{ AllowedDomains []string }
			Filesystem struct{ AllowRead, AllowWrite []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	fs := got.Sandbox.Filesystem
	cache := filepath.Join(realpath(t, home), "Library", "Caches", "Loam")
	if !slices.Contains(fs.AllowRead, filepath.Join(realpath(t, home), ".nvm")) || !slices.Contains(fs.AllowRead, cache) || !slices.Contains(fs.AllowWrite, cache) {
		t.Errorf("allowRead = %q, allowWrite = %q, want ~/.nvm and the Loam cache", fs.AllowRead, fs.AllowWrite)
	}
	for _, d := range []string{"machine.example.com", "*.example.org"} {
		if !slices.Contains(got.Sandbox.Network.AllowedDomains, d) {
			t.Errorf("allowedDomains = %q, want %s", got.Sandbox.Network.AllowedDomains, d)
		}
	}
	if slices.Contains(got.Sandbox.Network.AllowedDomains, "beta.example.com") || slices.Contains(fs.AllowRead, filepath.Join(realpath(t, home), "beta-only")) {
		t.Errorf("the settings of another plot reached the run: %q %q", got.Sandbox.Network.AllowedDomains, fs.AllowRead)
	}
}

// TAS-175: the gate builds the rules again after the session ran, so the
// rules follow no git file that the run can write. A commondir file in the
// git folder does not move the git folder to another repo, and an include in
// config.worktree does not open a file.
func TestRunRulesFollowNoGitFileOfTheRun(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	wt := filepath.Join(t.TempDir(), "wt")
	testutil.Git(t, repo, "worktree", "add", "-q", wt)
	testutil.Git(t, repo, "config", "extensions.worktreeConfig", "true")
	secret := filepath.Join(t.TempDir(), "secret.gitconfig")
	if err := os.WriteFile(secret, []byte("[user]\n\tname = x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git := realpath(t, filepath.Join(repo, ".git"))
	admin := filepath.Join(git, "worktrees", "wt")
	write := func(name, text string) {
		t.Helper()
		if err := os.WriteFile(name, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	run := store.Run{ID: "r1", PlotID: p.ID, Folder: wt}
	write(filepath.Join(admin, "config.worktree"), "[include]\n\tpath = "+secret+"\n")
	if got := testutil.Git(t, wt, "config", "user.name"); got != "x" {
		t.Fatalf("git does not read config.worktree: user.name %q", got)
	}
	r, err := session.RunRules(e.store, run)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(r.Read, realpath(t, secret)) {
		t.Errorf("read = %q has the file that config.worktree includes", r.Read)
	}
	write(filepath.Join(admin, "commondir"), filepath.Join(other, ".git")+"\n")
	write(filepath.Join(git, "commondir"), filepath.Join(other, ".git")+"\n")
	if r, err = session.RunRules(e.store, run); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(r.Write, git) || slices.Contains(r.Write, realpath(t, filepath.Join(other, ".git"))) {
		t.Errorf("write = %q, want %s and not the other repo", r.Write, git)
	}
}

// TAS-175: a run folder whose git folder is in no repo of the plot gets no
// rules.
func TestRunRulesNeedTheGitFolderOfARepoOfThePlot(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	if _, err := session.RunRules(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: other}); err == nil || !strings.Contains(err.Error(), "in no repo of the plot") {
		t.Fatalf("a run in another repo: %v", err)
	}
}

// TAS-175: a run in a repo of the plot can write its .git folder. When it
// puts a .git file there that names another repo of the plot, the run gets
// no rules, so the other repo does not become writable.
func TestRunRulesNeedTheGitFolderOfTheRepoOfTheRun(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}, {Path: other}}})
	run := store.Run{ID: "r1", PlotID: p.ID, Folder: repo}
	if _, err := session.RunRules(e.store, run); err != nil {
		t.Fatal(err)
	}
	dotgit := filepath.Join(repo, ".git")
	if err := os.Rename(dotgit, filepath.Join(repo, "moved.git")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dotgit, []byte("gitdir: "+filepath.Join(other, ".git")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := session.RunRules(e.store, run); err == nil || !strings.Contains(err.Error(), "its .git is not a folder") {
		t.Fatalf("a run whose .git names another repo: %v", err)
	}
}

// TAS-175: the run can write the git folder of its repo, so it can put a link
// in place of its worktree folder, or of the worktrees folder, to the git
// folder of another repo of the plot. The run then gets no rules, so the other
// repo does not become writable.
func TestRunRulesFollowNoLinkInTheGitFolder(t *testing.T) {
	e := setup(t)
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	wt := filepath.Join(t.TempDir(), "wt")
	testutil.Git(t, repo, "worktree", "add", "-q", wt)
	testutil.Git(t, other, "worktree", "add", "-q", filepath.Join(t.TempDir(), "x"))
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}, {Path: other}}})
	run := store.Run{ID: "r1", PlotID: p.ID, Folder: wt}
	if _, err := session.RunRules(e.store, run); err != nil {
		t.Fatal(err)
	}
	git, otherGit := realpath(t, filepath.Join(repo, ".git")), realpath(t, filepath.Join(other, ".git"))
	admin := filepath.Join(git, "worktrees", "wt")
	if err := os.Rename(admin, filepath.Join(git, "moved")); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{otherGit, filepath.Join(otherGit, "worktrees", "x")} {
		if err := os.Symlink(target, admin); err != nil {
			t.Fatal(err)
		}
		if _, err := session.RunRules(e.store, run); err == nil || !strings.Contains(err.Error(), "is not a worktree folder") {
			t.Errorf("a link to %s: %v", target, err)
		}
		if err := os.Remove(admin); err != nil {
			t.Fatal(err)
		}
	}
	worktrees := filepath.Join(git, "worktrees")
	if err := os.Rename(worktrees, filepath.Join(git, "moved-worktrees")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(otherGit, "worktrees"), worktrees); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(otherGit, "worktrees", "x"), filepath.Join(otherGit, "worktrees", "wt")); err != nil {
		t.Fatal(err)
	}
	if _, err := session.RunRules(e.store, run); err == nil || !strings.Contains(err.Error(), "is not a worktree folder") {
		t.Errorf("a link in place of the worktrees folder: %v", err)
	}
}
