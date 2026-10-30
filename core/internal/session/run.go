package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/store"
)

// RunHookTimeout is the timeout of the hooks of a run, in seconds. The Stop
// hook runs the Done when checks, which can take minutes.
const RunHookTimeout = 1800

// runEvents are the hook events of a run session. Each one calls
// `loam run hook <run-id>`.
var runEvents = []string{"SessionStart", "Stop", "StopFailure"}

// RunSessionName is the name of the background session of a run. claude
// attach, logs, and stop take it.
func RunSessionName(runID string) string { return "loam-run-" + runID }

// PrepareRun writes the seed and the settings file of a run, and returns the
// launch plan of its background session: claude --bg in the run's folder,
// with the prompt as the last argument. The session works in auto mode,
// because nobody answers its prompts. It starts nothing and records no
// session: the SessionStart hook of the run records it, because claude --bg
// picks its own session ID.
func PrepareRun(s *store.Store, r store.Run, prompt, loam, model, effort string) (*Plan, error) {
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return nil, err
	}
	if err := refuseArchived(plot); err != nil {
		return nil, err
	}
	claude, err := findClaude()
	if err != nil {
		return nil, err
	}
	lead := []string{"--bg", "--name", RunSessionName(r.ID), "--permission-mode", "auto"}
	if model != "" {
		lead = append(lead, "--model", model)
	}
	if effort != "" {
		lead = append(lead, "--effort", effort)
	}
	// The sandbox lets Bash write each added folder, so a run adds only the
	// plot folder, and its rules deny writes to it. Bash reads the repos and
	// the links through the rules.
	box, err := runRules(s, plot, r.Folder)
	if err != nil {
		return nil, err
	}
	plan, err := build(s, plot, r.Folder, claude, "run-"+r.ID, lead, loam, runSettings(r.ID, box), false)
	if err != nil {
		return nil, err
	}
	plan.SessionID = ""
	plan.Args = append(plan.Args, prompt+box.Prompt())
	return plan, nil
}

// runSettings returns the settings of a run session: the allow rules of a
// seeded session, the deny rules of the credential paths, the run hooks, env,
// and the sandbox of the rules. The background session may start from the
// Claude Code supervisor, which does not pass the environment of the loam
// process, so the settings carry it.
func runSettings(runID string, box sandbox.Rules) settingsFunc {
	return func(loam string, env []string) ([]byte, error) {
		type hook struct {
			Type    string `json:"type"`
			Command string `json:"command"`
			Timeout int    `json:"timeout"`
		}
		type group struct {
			Hooks []hook `json:"hooks"`
		}
		hooks := map[string]any{}
		for _, e := range runEvents {
			hooks[e] = []group{{Hooks: []hook{{Type: "command", Command: shellQuote(loam) + " run hook " + runID, Timeout: RunHookTimeout}}}}
		}
		vars := map[string]string{}
		for _, kv := range env {
			k, v, _ := strings.Cut(kv, "=")
			vars[k] = v
		}
		s := map[string]any{
			"permissions": map[string]any{"allow": rules(allowTools), "deny": box.ToolDenies()},
			"hooks":       hooks,
			"env":         vars,
			"sandbox":     box.Settings(),
		}
		return json.MarshalIndent(s, "", "  ")
	}
}

// RunSandboxNote returns what the stacks of the run need in the sandbox, or ""
// when they need nothing. The first prompt of the run says it, and the run
// hook says it again after a compact, which can drop that prompt.
func RunSandboxNote(s *store.Store, r store.Run) (string, error) {
	box, err := RunRules(s, r)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(box.Prompt()), nil
}

// RunRules returns the sandbox rules of a run, which its session works in.
// The gate runs the checks of the run with the same rules.
func RunRules(s *store.Store, r store.Run) (sandbox.Rules, error) {
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return sandbox.Rules{}, err
	}
	return runRules(s, plot, r.Folder)
}

// runRules returns the sandbox rules of a run that works in folder.
func runRules(s *store.Store, plot store.Plot, folder string) (sandbox.Rules, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return sandbox.Rules{}, fmt.Errorf("the sandbox needs the home folder: %w", err)
	}
	var repos []string
	for _, r := range plot.Repos {
		repos = append(repos, r.Path)
	}
	admin, git, err := gitDirs(folder, repos)
	if err != nil {
		return sandbox.Rules{}, err
	}
	machine, err := s.GetSandboxSettings("")
	if err != nil {
		return sandbox.Rules{}, err
	}
	forPlot, err := s.GetSandboxSettings(plot.ID)
	if err != nil {
		return sandbox.Rules{}, err
	}
	in := sandbox.Input{
		Home:      home,
		Machine:   sandbox.Extra{Read: machine.Read, Write: machine.Write, Hosts: machine.Hosts},
		Plot:      sandbox.Extra{Read: forPlot.Read, Write: forPlot.Write, Hosts: forPlot.Hosts},
		Protected: []string{s.Home()},
		Folder:    folder,
		GitDir:    git,
		Repos:     repos,
		GitConfig: gitConfigFiles(home, folder, admin, git),
		// The plot folder holds the seed, which only Loam writes.
		NoWrite: []string{s.PlotDir(plot.ID)},
		Getenv:  os.Getenv,
	}
	for _, l := range plot.Links {
		if linkkind.IsLocal(l.Target) {
			in.Links = append(in.Links, linkkind.Expand(l.Target))
		}
	}
	return sandbox.For(in)
}

// gitConfigScopes are the config scopes whose files the sandbox reads. The
// worktree scope is left out: with extensions.worktreeConfig, a run can write
// config.worktree in the git folder, and an include there would name any file
// for the next rules of the run. So is the command scope, which comes from
// the environment.
var gitConfigScopes = []string{"system", "global", "local"}

// includeDepth is how deep git follows includes (MAX_INCLUDE_DEPTH).
const includeDepth = 10

// gitConfigFiles returns the config files that git reads in the worktree
// folder with the git folder admin, with the files that they include, in the
// scopes of gitConfigScopes. It names the common git folder, so that git
// does not follow a commondir file that the run wrote. A file that git
// cannot name is not read in the sandbox, so an error gives none.
//
// git config --list names only the includes that git took. Git also opens
// the file of an includeIf whose condition does not hold: for a hasconfig
// condition it reads the file to find the remote URLs, and it stops when
// the sandbox denies the file (TAS-194). So gitConfigFiles adds the file of
// each include and includeIf, to the depth that git follows. It does not
// follow the includes of a file that the run can write.
func gitConfigFiles(home, folder, admin, common string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "config", "--list", "--show-scope", "--show-origin", "-z")
	cmd.Env = append(os.Environ(), "GIT_DIR="+admin, "GIT_COMMON_DIR="+common)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	// Each entry is a scope, an origin, and a key with its value, each one
	// ended by NUL.
	var files []string
	parts := strings.Split(string(out), "\x00")
	for i := 0; i+2 < len(parts); i += 3 {
		if !slices.Contains(gitConfigScopes, parts[i]) {
			continue
		}
		if f, ok := strings.CutPrefix(parts[i+1], "file:"); ok && filepath.IsAbs(f) && !slices.Contains(files, f) {
			files = append(files, f)
		}
	}
	// The run writes its folder and the git folders, except the config of
	// the repo, which the rules deny.
	writable := func(f string) bool {
		f = sandbox.Real(f)
		return inside(f, folder) || inside(f, admin) || inside(f, common) && f != sandbox.Real(filepath.Join(common, "config"))
	}
	next := files
	for depth := 0; depth < includeDepth && len(next) > 0; depth++ {
		var found []string
		for _, f := range next {
			if writable(f) {
				continue
			}
			for _, inc := range gitIncludes(ctx, home, f) {
				if !slices.Contains(files, inc) {
					files = append(files, inc)
					found = append(found, inc)
				}
			}
		}
		next = found
	}
	return files
}

// gitIncludes returns the files that the include.path and includeIf.*.path
// entries of the config file f name, whatever their condition. Git reads a
// relative path from the folder of f, and ~/ from home. It leaves out a path
// that git would not expand, such as ~user/.
func gitIncludes(ctx context.Context, home, f string) []string {
	out, err := exec.CommandContext(ctx, "git", "config", "--file", f, "--no-includes", "-z", "--get-regexp", `^include(if\..*)?\.path$`).Output()
	if err != nil {
		return nil
	}
	// Each entry is a key and its value, with a newline between them, ended
	// by NUL.
	var files []string
	for _, entry := range strings.Split(string(out), "\x00") {
		_, p, ok := strings.Cut(entry, "\n")
		switch {
		case !ok || p == "":
			continue
		case strings.HasPrefix(p, "~/"):
			p = filepath.Join(home, p[2:])
		case strings.HasPrefix(p, "~"):
			continue
		case !filepath.IsAbs(p):
			p = filepath.Join(filepath.Dir(f), p)
		}
		files = append(files, filepath.Clean(p))
	}
	return files
}

// inside reports whether path, with its symlinks resolved, is dir or a path
// inside it. It resolves the symlinks of dir.
func inside(path, dir string) bool {
	if dir == "" {
		return false
	}
	dir = sandbox.Real(dir)
	return path == dir || strings.HasPrefix(path, dir+string(filepath.Separator))
}

// gitDirs returns the git folder of the worktree in folder (admin) and the
// git folder that it shares with the other worktrees of its repo (common). A
// commit in a worktree writes to common, so a run cannot commit without it.
// gitDirs does not ask git for common: git follows a commondir file in the
// git folder, and the run can write one there to name another repo. It reads
// the .git of folder, which the run cannot write, and takes the .git folder
// of the repo of the plot that holds that worktree. It returns an error when
// no repo of the plot holds it, and when folder is a repo of the plot whose
// .git is not a folder.
func gitDirs(folder string, repos []string) (admin, common string, err error) {
	dotgit := filepath.Join(folder, ".git")
	fi, err := os.Lstat(dotgit)
	if err != nil {
		return "", "", fmt.Errorf("find the git folder of %s for the sandbox: %w", folder, err)
	}
	// The run can replace the .git folder of a repo that it works in with a
	// .git file that names the git folder of another repo of the plot.
	for _, repo := range repos {
		if sandbox.Real(repo) == sandbox.Real(folder) && !fi.IsDir() {
			return "", "", fmt.Errorf("the sandbox cannot hold the run in %s: it is a repo of the plot, and its .git is not a folder", folder)
		}
	}
	var candidate string
	switch {
	case fi.IsDir():
		admin, candidate = dotgit, dotgit
	case fi.Mode().IsRegular():
		b, err := os.ReadFile(dotgit)
		if err != nil {
			return "", "", fmt.Errorf("find the git folder of %s for the sandbox: %w", folder, err)
		}
		p, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
		if !ok {
			return "", "", fmt.Errorf("find the git folder of %s for the sandbox: %s names no gitdir", folder, dotgit)
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(folder, p)
		}
		admin = filepath.Clean(p)
		// The .git file names <git folder>/worktrees/<name>. The run can
		// write the git folder, so it can put a link in place of either
		// folder below it, to the git folder of another repo. Each one must
		// be a folder, not a link.
		parent := filepath.Dir(admin)
		if filepath.Base(parent) != "worktrees" || !isRealDir(admin) || !isRealDir(parent) {
			return "", "", fmt.Errorf("the sandbox cannot hold the run in %s: its git folder %s is not a worktree folder of a git folder", folder, admin)
		}
		candidate = filepath.Dir(parent)
	default:
		return "", "", fmt.Errorf("find the git folder of %s for the sandbox: %s is not a file or a folder", folder, dotgit)
	}
	if isRealDir(candidate) {
		resolved := sandbox.Real(candidate)
		for _, repo := range repos {
			if git := sandbox.Real(filepath.Join(repo, ".git")); resolved == git && isRealDir(git) {
				return admin, git, nil
			}
		}
	}
	return "", "", fmt.Errorf("the sandbox cannot hold the run in %s: its git folder %s is in no repo of the plot", folder, admin)
}

// isRealDir reports whether path is a folder, and not a link to one.
func isRealDir(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.IsDir()
}
