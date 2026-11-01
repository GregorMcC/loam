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

// TAS-191: a file that a git config includes, and that a run can write, reaches
// the git that Loam runs outside the sandbox. So a run does not start with such
// an include.

// gitConfigCase is a plot with one repo, and a global git config outside the
// temporary folders, which a run can write.
type gitConfigCase struct {
	e      env
	repo   string
	global string // the global config
	dir    string // the folder of the global config, outside each write path
	home   string
	plot   store.Plot
}

func newGitConfigCase(t *testing.T) gitConfigCase {
	t.Helper()
	e := setup(t)
	testutil.GitEnv(t)
	t.Cleanup(session.SetRunTemps(func() []string { return nil }))
	home := realpath(t, t.TempDir())
	t.Setenv("HOME", home)
	repo, _ := testutil.GitRepo(t)
	global := os.Getenv("GIT_CONFIG_GLOBAL")
	return gitConfigCase{
		e: e, repo: repo, global: global, dir: realpath(t, filepath.Dir(global)), home: home,
		plot: e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}}),
	}
}

func writeFile(t *testing.T, name, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendFile(t *testing.T, name, text string) {
	t.Helper()
	f, err := os.OpenFile(name, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(text); err != nil {
		t.Fatal(err)
	}
}

func include(path string) string { return "[include]\n\tpath = " + path + "\n" }

func (c gitConfigCase) prepare(t *testing.T) error {
	t.Helper()
	_, err := session.PrepareRun(c.e.store, store.Run{ID: "r1", PlotID: c.plot.ID, Folder: c.repo}, "go", "loam", "", "")
	return err
}

// wantRefused checks the error of a run that does not start: it names each of
// the texts, and it says to remove the include.
func wantRefused(t *testing.T, err error, names ...string) {
	t.Helper()
	if err == nil {
		t.Fatal("the run starts")
	}
	for _, n := range append(names, "Remove the include") {
		if !strings.Contains(err.Error(), n) {
			t.Errorf("error %q does not have %q", err, n)
		}
	}
}

// A chain from the global config, through a file outside the write paths, to
// a file in the run folder.
func TestARunDoesNotStartWithAnIncludeChainToAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	target := filepath.Join(c.repo, "shared.gitconfig")
	writeFile(t, target, "[core]\n\tautocrlf = false\n")
	mid := filepath.Join(c.dir, "mid.gitconfig")
	writeFile(t, mid, include(target))
	appendFile(t, c.global, include("mid.gitconfig"))
	wantRefused(t, c.prepare(t), mid, target, realpath(t, c.repo))
}

// The sandbox refuses a file in a credential folder, so Bash cannot read it.
// Git outside the sandbox reads it, so the check walks it.
func TestARunDoesNotStartWithAnIncludeChainThroughAFileThatTheSandboxRefuses(t *testing.T) {
	c := newGitConfigCase(t)
	target := filepath.Join(c.repo, "shared.gitconfig")
	refused := filepath.Join(c.home, ".ssh", "extra.gitconfig")
	writeFile(t, refused, include(target))
	appendFile(t, c.global, include("~/.ssh/extra.gitconfig"))
	wantRefused(t, c.prepare(t), refused, target, realpath(t, c.repo))
}

// A run can make a missing file, so a missing target counts: in a folder that
// exists, in a folder that does not, and through a link whose target is
// missing.
func TestARunDoesNotStartWithAMissingIncludeTargetInAWritePath(t *testing.T) {
	for _, tc := range []struct {
		name string
		path func(c gitConfigCase, t *testing.T) string
	}{
		{"in a folder that exists", func(c gitConfigCase, _ *testing.T) string { return filepath.Join(c.repo, "missing.gitconfig") }},
		{"in a folder that does not", func(c gitConfigCase, _ *testing.T) string {
			return filepath.Join(c.repo, "no", "such", "folder", "x.gitconfig")
		}},
		{"through a link to a missing file", func(c gitConfigCase, t *testing.T) string {
			link := filepath.Join(c.dir, "dangling.gitconfig")
			if err := os.Symlink(filepath.Join(c.repo, "missing.gitconfig"), link); err != nil {
				t.Fatal(err)
			}
			return link
		}},
		{"through a link before a missing folder", func(c gitConfigCase, t *testing.T) string {
			link := filepath.Join(c.dir, "repo-link")
			if err := os.Symlink(c.repo, link); err != nil {
				t.Fatal(err)
			}
			return link + "/no/such/x.gitconfig"
		}},
		{"through a link and a dot dot", func(c gitConfigCase, t *testing.T) string {
			link := filepath.Join(c.dir, "core-link")
			if err := os.Symlink(filepath.Join(c.repo, "sub", "deep"), link); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(c.repo, "sub", "deep"), 0o755); err != nil {
				t.Fatal(err)
			}
			return link + "/../missing/x.gitconfig"
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newGitConfigCase(t)
			target := tc.path(c, t)
			appendFile(t, c.global, include(target))
			wantRefused(t, c.prepare(t), c.global, target, realpath(t, c.repo))
		})
	}
}

// A folder is no config file now, but the run can replace it with a file. Git
// stops on an include of a folder when the condition holds, so this one does
// not hold.
func TestARunDoesNotStartWithAnIncludeOfAFolderInAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	target := filepath.Join(c.repo, "folder")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	appendFile(t, c.global, "[includeIf \"gitdir:/nowhere/\"]\n\tpath = "+target+"\n")
	wantRefused(t, c.prepare(t), c.global, target, realpath(t, c.repo))
}

// The volume of a Mac does not tell case or Unicode forms apart, so a name in
// another form opens the same file.
func TestARunDoesNotStartWithAnIncludeTargetInAnotherCase(t *testing.T) {
	c := newGitConfigCase(t)
	target := strings.ToUpper(c.repo) + "/shared.gitconfig"
	appendFile(t, c.global, include(target))
	wantRefused(t, c.prepare(t), c.global, target)
}

func TestARunDoesNotStartWithAnIncludeTargetInAnotherUnicodeForm(t *testing.T) {
	for name, forms := range map[string][2]string{
		"decomposed folder, composed include": {"cafe\u0301", "caf\u00e9"},
		"composed folder, decomposed include": {"caf\u00e9", "cafe\u0301"},
	} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			testutil.GitEnv(t)
			t.Cleanup(session.SetRunTemps(func() []string { return nil }))
			root := realpath(t, t.TempDir())
			repo, _ := testutil.GitRepoAt(t, filepath.Join(root, "remote.git"), filepath.Join(root, forms[0], "app"))
			global := os.Getenv("GIT_CONFIG_GLOBAL")
			target := filepath.Join(root, forms[1], "app", "shared.gitconfig")
			appendFile(t, global, include(target))
			p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
			_, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
			wantRefused(t, err, global, target)
		})
	}
}

// Each form of condition counts, whether it holds now or not: the run can
// change its branch, and git opens the file of a hasconfig condition anyway.
func TestARunDoesNotStartWithAnIncludeInAConditionThatDoesNotHoldNow(t *testing.T) {
	for _, cond := range []string{
		"gitdir:/nowhere/",
		"gitdir/i:/nowhere/",
		"onbranch:nowhere",
		"hasconfig:remote.*.url:git@example.com:nobody/**",
	} {
		t.Run(cond, func(t *testing.T) {
			c := newGitConfigCase(t)
			target := filepath.Join(c.repo, "shared.gitconfig")
			writeFile(t, target, "")
			appendFile(t, c.global, "[includeIf \""+cond+"\"]\n\tpath = "+target+"\n")
			wantRefused(t, c.prepare(t), c.global, target, realpath(t, c.repo))
		})
	}
}

// The local config counts too, and a target in a temporary folder.
func TestARunDoesNotStartWithALocalIncludeToAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	testutil.Git(t, c.repo, "config", "include.path", "../team.gitconfig")
	wantRefused(t, c.prepare(t), "team.gitconfig", realpath(t, c.repo))
}

func TestARunDoesNotStartWithAnIncludeTargetInATemporaryFolder(t *testing.T) {
	c := newGitConfigCase(t)
	temp := realpath(t, t.TempDir())
	t.Cleanup(session.SetRunTemps(func() []string { return []string{temp} }))
	target := filepath.Join(temp, "x.gitconfig")
	appendFile(t, c.global, include(target))
	wantRefused(t, c.prepare(t), c.global, target, temp)
}

// Loam cannot say where such a path points, so it refuses.
func TestARunDoesNotStartWithAnIncludePathThatLoamCannotExpand(t *testing.T) {
	for _, value := range []string{"~nobody/x.gitconfig", "%(prefix)/x.gitconfig"} {
		t.Run(value, func(t *testing.T) {
			c := newGitConfigCase(t)
			appendFile(t, c.global, include(value))
			err := c.prepare(t)
			if err == nil || !strings.Contains(err.Error(), c.global) || !strings.Contains(err.Error(), value) {
				t.Fatalf("error %v, want %s and %s", err, c.global, value)
			}
		})
	}
}

// A value that git cannot read as a bool stops git too. Loam cannot say whether
// the extension is on, so it refuses.
func TestARunDoesNotStartWithAWorktreeConfigValueThatLoamCannotRead(t *testing.T) {
	c := newGitConfigCase(t)
	config := filepath.Join(realpath(t, c.repo), ".git", "config")
	appendFile(t, config, "[extensions]\n\tworktreeConfig = maybe\n")
	err := c.prepare(t)
	if err == nil || !strings.Contains(err.Error(), "extensions.worktreeConfig") || !strings.Contains(err.Error(), config) {
		t.Fatalf("error %v, want the extension and %s", err, config)
	}
}

// A file that git cannot read can hold any include, so Loam refuses.
func TestARunDoesNotStartWithAnIncludedFileThatGitCannotRead(t *testing.T) {
	c := newGitConfigCase(t)
	bad := filepath.Join(c.dir, "bad.gitconfig")
	writeFile(t, bad, "[bad\n")
	appendFile(t, c.global, "[includeIf \"gitdir:/nowhere/\"]\n\tpath = bad.gitconfig\n")
	err := c.prepare(t)
	if err == nil || !strings.Contains(err.Error(), bad) {
		t.Fatalf("error %v, want %s", err, bad)
	}
}

// A global config in a write path: the run can write it, with no include.
func TestARunDoesNotStartWithAGlobalConfigInAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	inRepo := filepath.Join(c.repo, "global.gitconfig")
	writeFile(t, inRepo, "[user]\n\tname = x\n\temail = x@example.com\n")
	link := filepath.Join(c.dir, "global-link")
	if err := os.Symlink(inRepo, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", link)
	err := c.prepare(t)
	if err == nil || !strings.Contains(err.Error(), link) || !strings.Contains(err.Error(), realpath(t, c.repo)) {
		t.Fatalf("error %v, want %s and the write path", err, link)
	}
}

// With extensions.worktreeConfig on, git reads config.worktree in the git
// folder, which the run can write.
func TestARunDoesNotStartWithWorktreeConfigOn(t *testing.T) {
	for _, value := range []string{"true", "yes", "on", "1"} {
		t.Run(value, func(t *testing.T) {
			c := newGitConfigCase(t)
			testutil.Git(t, c.repo, "config", "extensions.worktreeConfig", value)
			err := c.prepare(t)
			if err == nil {
				t.Fatal("the run starts")
			}
			config := filepath.Join(realpath(t, c.repo), ".git", "config")
			for _, want := range []string{"extensions.worktreeConfig", "config.worktree", "git config --file '" + config + "' --unset-all extensions.worktreeConfig"} {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error %q does not have %q", err, want)
				}
			}
		})
	}
}

// The command in the error turns it off, and the run then starts.
func TestTheCommandInTheWorktreeConfigErrorTurnsItOff(t *testing.T) {
	c := newGitConfigCase(t)
	testutil.Git(t, c.repo, "config", "extensions.worktreeConfig", "true")
	if err := c.prepare(t); err == nil {
		t.Fatal("the run starts")
	}
	testutil.Git(t, c.repo, "config", "--file", filepath.Join(realpath(t, c.repo), ".git", "config"), "--unset-all", "extensions.worktreeConfig")
	if err := c.prepare(t); err != nil {
		t.Fatal(err)
	}
}

// A worktree of a repo with the extension on does not start, and neither does
// one with the extension off in a worktree whose commondir names another
// folder: git takes the config of that folder, which can turn the extension
// on. A worktree that nothing changed starts.
func TestARunInAWorktreeChecksTheConfigThatGitReads(t *testing.T) {
	c := newGitConfigCase(t)
	wt := filepath.Join(realpath(t, t.TempDir()), "wt")
	testutil.Git(t, c.repo, "worktree", "add", "-q", wt)
	run := store.Run{ID: "r1", PlotID: c.plot.ID, Folder: wt}
	prepare := func() error {
		_, err := session.PrepareRun(c.e.store, run, "go", "loam", "", "")
		return err
	}
	if err := prepare(); err != nil {
		t.Fatalf("a worktree with no change: %v", err)
	}
	admin := filepath.Join(realpath(t, c.repo), ".git", "worktrees", "wt")
	fake := filepath.Join(wt, "fake")
	writeFile(t, filepath.Join(fake, "config"), "[extensions]\n\tworktreeConfig = true\n")
	writeFile(t, filepath.Join(fake, "HEAD"), "ref: refs/heads/main\n")
	if err := os.MkdirAll(filepath.Join(fake, "objects"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(fake, "refs"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(admin, "commondir"), fake+"\n")
	if got := testutil.Git(t, wt, "config", "extensions.worktreeConfig"); got != "true" {
		t.Fatalf("git does not follow the commondir file: %q", got)
	}
	err := prepare()
	if err == nil || !strings.Contains(err.Error(), "commondir") || !strings.Contains(err.Error(), fake) {
		t.Fatalf("error %v, want the commondir file and %s", err, fake)
	}
	writeFile(t, filepath.Join(admin, "commondir"), "../..\n")
	testutil.Git(t, c.repo, "config", "extensions.worktreeConfig", "true")
	if err := prepare(); err == nil || !strings.Contains(err.Error(), "extensions.worktreeConfig") {
		t.Fatalf("error %v, want the extension", err)
	}
}

// A main checkout has no commondir file, so git takes its own config. With
// one, git takes the config of the folder that the file names.
func TestARunInAMainCheckoutRefusesACommondirFile(t *testing.T) {
	c := newGitConfigCase(t)
	file := filepath.Join(realpath(t, c.repo), ".git", "commondir")
	other := filepath.Join(c.repo, "fake")
	writeFile(t, file, other+"\n")
	err := c.prepare(t)
	if err == nil || !strings.Contains(err.Error(), file) || !strings.Contains(err.Error(), other) {
		t.Fatalf("error %v, want %s and %s", err, file, other)
	}
}

// The same check runs before a resume.
func TestARunDoesNotResumeWithAnIncludeToAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	run := store.Run{ID: "r1", PlotID: c.plot.ID, Folder: c.repo, SessionID: "s1"}
	if _, err := session.PrepareRunResume(c.e.store, run, "go", "loam", "", ""); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(c.repo, "shared.gitconfig")
	appendFile(t, c.global, include(target))
	_, err := session.PrepareRunResume(c.e.store, run, "go", "loam", "", "")
	wantRefused(t, err, c.global, target, realpath(t, c.repo))
}

// The gate builds the rules of the run again, so a change to the git config
// stops it too.
func TestRunRulesRefuseAnIncludeToAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	run := store.Run{ID: "r1", PlotID: c.plot.ID, Folder: c.repo}
	target := filepath.Join(c.repo, "shared.gitconfig")
	appendFile(t, c.global, include(target))
	_, err := session.RunRules(c.e.store, run)
	wantRefused(t, err, c.global, target, realpath(t, c.repo))
}

// A normal ~/.gitconfig, with includeIf and hasconfig forms and with files
// outside the write paths, still starts. The run reads each file that exists.
func TestARunStartsWithIncludesOutsideTheWritePaths(t *testing.T) {
	c := newGitConfigCase(t)
	work := filepath.Join(c.home, ".config", "git", "work")
	nested := filepath.Join(c.home, ".config", "git", "nested.gitconfig")
	writeFile(t, work, include("nested.gitconfig"))
	writeFile(t, nested, "[user]\n\temail = work@example.com\n")
	home := filepath.Join(c.home, ".gitconfig")
	writeFile(t, home, "[user]\n\tname = Someone\n\temail = someone@example.com\n"+
		"[includeIf \"hasconfig:remote.*.url:git@github.com:Org/**\"]\n\tpath = ~/.config/git/work\n"+
		"[includeIf \"hasconfig:remote.*.url:https://github.com/Org/**\"]\n\tpath = ~/.config/git/work\n"+
		"[includeIf \"gitdir:~/work/\"]\n\tpath = ~/.config/git/work\n"+
		"[includeIf \"onbranch:work/**\"]\n\tpath = "+work+"\n"+
		"[include]\n\tpath = ~/.config/git/missing\n")
	t.Setenv("GIT_CONFIG_GLOBAL", "")
	if err := os.Unsetenv("GIT_CONFIG_GLOBAL"); err != nil {
		t.Fatal(err)
	}
	plan, err := session.PrepareRun(c.e.store, store.Run{ID: "r1", PlotID: c.plot.ID, Folder: c.repo}, "go", "loam", "", "")
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
	for _, want := range []string{work, nested} {
		if !slices.Contains(got.Sandbox.Filesystem.AllowRead, want) {
			t.Errorf("allowRead = %q, want %s", got.Sandbox.Filesystem.AllowRead, want)
		}
	}
}

// An include in the name of a folder that only looks like a write path is
// outside it: the check compares whole path elements.
func TestARunStartsWithAnIncludeBesideAWritePath(t *testing.T) {
	c := newGitConfigCase(t)
	beside := c.repo + "-beside.gitconfig"
	writeFile(t, beside, "[core]\n\tautocrlf = false\n")
	t.Cleanup(func() { os.Remove(beside) })
	appendFile(t, c.global, include(beside))
	if err := c.prepare(t); err != nil {
		t.Fatal(err)
	}
}

// fakeCommonDir makes a folder that git takes as a common git folder, and whose
// config turns the extension on.
func fakeCommonDir(t *testing.T, dir string) {
	t.Helper()
	writeFile(t, filepath.Join(dir, "config"), "[extensions]\n\tworktreeConfig = true\n")
	writeFile(t, filepath.Join(dir, "HEAD"), "ref: refs/heads/main\n")
	for _, d := range []string{"objects", "refs"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

// Git follows a link before a "..". By the text, x/../../.. in the metadata
// folder names the git folder of the repo. With x a link, it names a folder of
// the run.
func TestARunDoesNotStartWithACommondirThatGoesThroughALink(t *testing.T) {
	c := newGitConfigCase(t)
	wt := filepath.Join(realpath(t, t.TempDir()), "wt")
	testutil.Git(t, c.repo, "worktree", "add", "-q", wt)
	admin := filepath.Join(realpath(t, c.repo), ".git", "worktrees", "wt")
	fake := filepath.Join(wt, "fake")
	fakeCommonDir(t, fake)
	deep := filepath.Join(fake, "a", "b", "c")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(deep, filepath.Join(admin, "x")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(admin, "commondir"), "x/../../..\n")
	if got := testutil.Git(t, wt, "config", "extensions.worktreeConfig"); got != "true" {
		t.Fatalf("git does not follow the link in the commondir file: %q", got)
	}
	_, err := session.PrepareRun(c.e.store, store.Run{ID: "r1", PlotID: c.plot.ID, Folder: wt}, "go", "loam", "", "")
	if err == nil || !strings.Contains(err.Error(), "commondir") {
		t.Fatalf("error %v, want the commondir file", err)
	}
}

// A run in a worktree can write the commondir file of the shared git folder.
// Git in the main checkout then takes the config of the folder that it names.
func TestARunInAWorktreeRefusesACommondirFileInTheSharedGitFolder(t *testing.T) {
	c := newGitConfigCase(t)
	wt := filepath.Join(realpath(t, t.TempDir()), "wt")
	testutil.Git(t, c.repo, "worktree", "add", "-q", wt)
	fake := filepath.Join(wt, "fake")
	fakeCommonDir(t, fake)
	file := filepath.Join(realpath(t, c.repo), ".git", "commondir")
	writeFile(t, file, fake+"\n")
	if got := testutil.Git(t, c.repo, "config", "extensions.worktreeConfig"); got != "true" {
		t.Fatalf("git in the main checkout does not follow the commondir file: %q", got)
	}
	_, err := session.PrepareRun(c.e.store, store.Run{ID: "r1", PlotID: c.plot.ID, Folder: wt}, "go", "loam", "", "")
	if err == nil || !strings.Contains(err.Error(), file) || !strings.Contains(err.Error(), fake) {
		t.Fatalf("error %v, want %s and %s", err, file, fake)
	}
}

// Git names a config file only when it holds an entry. A config file that is
// missing or empty and that the run can write is still one that git reads after
// the run writes it. So each path that git can read for the system and global
// scopes counts, whether it exists or not.
func TestARunDoesNotStartWithAConfigPathOfGitInAWritePath(t *testing.T) {
	for _, tc := range []struct {
		name string
		// set returns the path of the config, and the write path that holds it.
		set func(t *testing.T, c gitConfigCase) (string, string)
	}{
		{"GIT_CONFIG_GLOBAL, missing", func(t *testing.T, c gitConfigCase) (string, string) {
			p := filepath.Join(c.repo, "global.gitconfig")
			t.Setenv("GIT_CONFIG_GLOBAL", p)
			return p, realpath(t, c.repo)
		}},
		{"GIT_CONFIG_GLOBAL, empty", func(t *testing.T, c gitConfigCase) (string, string) {
			p := filepath.Join(c.repo, "global.gitconfig")
			writeFile(t, p, "")
			t.Setenv("GIT_CONFIG_GLOBAL", p)
			return p, realpath(t, c.repo)
		}},
		{"GIT_CONFIG_GLOBAL, missing in a temporary folder", func(t *testing.T, c gitConfigCase) (string, string) {
			temp := realpath(t, t.TempDir())
			t.Cleanup(session.SetRunTemps(func() []string { return []string{temp} }))
			p := filepath.Join(temp, "global.gitconfig")
			t.Setenv("GIT_CONFIG_GLOBAL", p)
			return p, temp
		}},
		{"XDG_CONFIG_HOME, missing", func(t *testing.T, c gitConfigCase) (string, string) {
			unsetGlobal(t)
			t.Setenv("XDG_CONFIG_HOME", filepath.Join(c.repo, "xdg"))
			return filepath.Join(c.repo, "xdg", "git", "config"), realpath(t, c.repo)
		}},
		{"XDG_CONFIG_HOME, missing in a temporary folder", func(t *testing.T, c gitConfigCase) (string, string) {
			temp := realpath(t, t.TempDir())
			t.Cleanup(session.SetRunTemps(func() []string { return []string{temp} }))
			unsetGlobal(t)
			t.Setenv("XDG_CONFIG_HOME", filepath.Join(temp, "xdg"))
			return filepath.Join(temp, "xdg", "git", "config"), temp
		}},
		{"a write path of ~/.gitconfig, missing", func(t *testing.T, c gitConfigCase) (string, string) {
			unsetGlobal(t)
			if _, err := c.e.store.SetSandboxSettings(store.SandboxSettings{Write: []string{"~/.gitconfig"}}); err != nil {
				t.Fatal(err)
			}
			p := filepath.Join(c.home, ".gitconfig")
			return p, p
		}},
		{"GIT_CONFIG_SYSTEM, missing", func(t *testing.T, c gitConfigCase) (string, string) {
			p := filepath.Join(c.repo, "system.gitconfig")
			t.Setenv("GIT_CONFIG_SYSTEM", p)
			return p, realpath(t, c.repo)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newGitConfigCase(t)
			path, write := tc.set(t, c)
			err := c.prepare(t)
			if err == nil {
				t.Fatal("the run starts")
			}
			for _, want := range []string{path, write} {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error %q does not have %q", err, want)
				}
			}
		})
	}
}

// The default paths of the global scope are outside each write path, so a run
// starts with none of them there.
func TestARunStartsWithNoConfigFileOfGit(t *testing.T) {
	c := newGitConfigCase(t)
	unsetGlobal(t)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(c.home, "xdg"))
	if err := c.prepare(t); err != nil {
		t.Fatal(err)
	}
}

// unsetGlobal removes GIT_CONFIG_GLOBAL for the test, so git takes the default
// paths of the global scope.
func unsetGlobal(t *testing.T) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", "")
	if err := os.Unsetenv("GIT_CONFIG_GLOBAL"); err != nil {
		t.Fatal(err)
	}
}
