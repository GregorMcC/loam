package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/mcpserver"
	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/store"
)

// RunHookTimeout is the timeout of the hooks of a run, in seconds. The Stop
// hook runs the Done when checks, which can take minutes.
const RunHookTimeout = 1800

// runEvents are the hook events of a run session. Each one calls
// `LOAM_HOME=<home> loam run hook <run-id>`.
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
	plan, box, err := prepareRun(s, r, nil, loam, model, effort)
	if err != nil {
		return nil, err
	}
	plan.Args = append(plan.Args, prompt+runNote(box))
	return plan, nil
}

// PrepareRunResume returns the launch plan that gives the session of a run a
// new prompt: claude --bg --resume, with the options of [PrepareRun].
// claude --resume does not keep the options of the session: with no flags,
// the session has no sandbox, no run hooks, and no deny rules. The settings
// file is written again, with the rules of the run as they are now, and the
// prompt ends with the same notes as the first prompt.
func PrepareRunResume(s *store.Store, r store.Run, prompt, loam, model, effort string) (*Plan, error) {
	if r.SessionID == "" {
		return nil, errors.New("the run has no session")
	}
	plan, box, err := prepareRun(s, r, []string{"--resume", r.SessionID}, loam, model, effort)
	if err != nil {
		return nil, err
	}
	plan.Args = append(plan.Args, prompt+runNote(box))
	return plan, nil
}

// prepareRun returns the launch plan of a run session with no prompt, and the
// sandbox rules of the run. idArgs come after --bg.
func prepareRun(s *store.Store, r store.Run, idArgs []string, loam, model, effort string) (*Plan, sandbox.Rules, error) {
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return nil, sandbox.Rules{}, err
	}
	if err := refuseArchived(plot); err != nil {
		return nil, sandbox.Rules{}, err
	}
	claude, err := findClaude()
	if err != nil {
		return nil, sandbox.Rules{}, err
	}
	lead := append(append([]string{"--bg"}, idArgs...), "--name", RunSessionName(r.ID), "--permission-mode", "auto")
	if model != "" {
		lead = append(lead, "--model", model)
	}
	if effort != "" {
		lead = append(lead, "--effort", effort)
	}
	if err := makeRunTemp(RunTemp(s, r.ID)); err != nil {
		return nil, sandbox.Rules{}, err
	}
	// The sandbox lets Bash write each added folder, so a run adds only the
	// plot folder, and its rules deny writes to it. Bash reads the repos and
	// the links through the rules.
	box, err := runRules(s, plot, r.Folder, r.ID)
	if err != nil {
		return nil, sandbox.Rules{}, err
	}
	plan, err := build(s, plot, r.Folder, claude, "run-"+r.ID, lead, loam, runSettings(s.Home(), r.ID, box), false)
	if err != nil {
		return nil, sandbox.Rules{}, err
	}
	plan.SessionID = ""
	return plan, box, nil
}

// runToolsNote tells a run what it can do with the Loam tools. The plot seed
// tells other sessions to change the plot, so a run must know that it is a run.
const runToolsNote = "This session is a Loam run. It has only the read tools of the Loam MCP server, so do not try to change the plot. " +
	"Report in your last message: Loam keeps that."

// runNote returns what each prompt of a run ends with.
func runNote(box sandbox.Rules) string { return box.Prompt() + "\n\n" + runToolsNote }

// runToolRules returns the rules of a run session for the tools of the Loam
// MCP server: allow each read tool, and deny each other tool by name. A deny
// rule wins over an allow rule that the user has, and over the auto mode
// classifier, so a run has no write tool on any plot. The list comes from what
// the server registers, so a new write tool is denied with no change here.
func runToolRules(tools []mcpserver.Tool) (allow, deny []string) {
	var read, write []string
	for _, t := range tools {
		if t.ReadOnly {
			read = append(read, t.Name)
		} else {
			write = append(write, t.Name)
		}
	}
	return rules(read), rules(write)
}

// runSettings returns the settings of a run session: the rules of the Loam
// tools (see [runToolRules]), the deny rules of the credential paths, the run
// hooks, env, and the sandbox of the rules. The background session may start
// from the Claude Code supervisor, which does not pass the environment of the
// loam process, so the settings carry it. The supervisor keeps the environment
// of the first claude --bg call, which can name another LOAM_HOME and the
// socket of a pane. So each hook command names home, the home of the store that
// holds the run, and env sets LOAM_HOME to it and LOAM_PANE_SOCKET to empty,
// which means no pane.
func runSettings(home, runID string, box sandbox.Rules) settingsFunc {
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
			hooks[e] = []group{{Hooks: []hook{{Type: "command", Command: "LOAM_HOME=" + shellQuote(home) + " " + shellQuote(loam) + " run hook " + runID, Timeout: RunHookTimeout}}}}
		}
		vars := map[string]string{}
		for _, kv := range env {
			k, v, _ := strings.Cut(kv, "=")
			vars[k] = v
		}
		vars["LOAM_HOME"] = home
		vars["LOAM_PANE_SOCKET"] = ""
		tools, err := mcpserver.Tools(context.Background())
		if err != nil {
			return nil, fmt.Errorf("list the tools of the Loam MCP server: %w", err)
		}
		allow, deny := runToolRules(tools)
		s := map[string]any{
			"permissions": map[string]any{"allow": allow, "deny": append(box.ToolDenies(), deny...)},
			"hooks":       hooks,
			"env":         vars,
			"sandbox":     box.Settings(),
		}
		return json.MarshalIndent(s, "", "  ")
	}
}

// RunTemp returns the private folder of the run runID: run-temp/<run-id> in
// the Loam home. Loam makes it again each time that it prepares the session
// of the run (see [makeRunTemp]), and removes it when the run ends (see
// [RemoveRunTemp]). The sandbox of the run can read and write it.
//
// The rule of TAS-196 and TAS-199 holds for this folder: no process outside
// the sandbox reads a file that the session writes. The folder holds the
// xcrun cache of the session, and an xcrun shim runs each path that its cache
// names. So only Bash gets xcrun_db (see [RunBashEnv]). Not the env of the
// settings: Claude Code, its hooks, and its MCP servers get that env, and
// they work outside the sandbox. They keep the cache of the user, which the
// sandbox denies.
func RunTemp(s *store.Store, runID string) string {
	return filepath.Join(s.Home(), "run-temp", runID)
}

// makeRunTemp makes the private folder dir of a run again, with a copy of
// the xcrun cache of the user. The session can write the folder, so Loam
// removes what is there and makes a new folder, also on a resume. RemoveAll
// removes a link that the session put there, and not its target. A link that
// the session puts in place of dir while Loam seeds it gets no file but a new
// one (see [sandbox.SeedXcrunCache]), and the rules do not follow it.
func makeRunTemp(dir string) error {
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("remove the private folder of the run: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return fmt.Errorf("make the private folder of the run: %w", err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return fmt.Errorf("make the private folder of the run: %w", err)
	}
	sandbox.SeedXcrunCache(dir)
	return nil
}

// RemoveRunTemp removes the private folder of the run runID. Loam calls it
// when the run ends: when it lands, and when you stop it. A Stopped run keeps
// the folder, because a send-back can resume its session.
func RemoveRunTemp(s *store.Store, runID string) error {
	return os.RemoveAll(RunTemp(s, runID))
}

// RunBashEnv returns what the SessionStart hook of the run runID writes to
// CLAUDE_ENV_FILE: xcrun_db names the xcrun cache in the private folder of
// the run. Claude Code applies that file to the Bash commands of the session
// only, and each one works in the sandbox (allowUnsandboxedCommands is
// false). See [RunTemp] for why the settings do not set it.
func RunBashEnv(s *store.Store, runID string) string {
	return "export xcrun_db=" + shellQuote(filepath.Join(RunTemp(s, runID), sandbox.PrivateXcrunCache)) + "\n"
}

// RunSandboxNote returns what the run must know about its sandbox and its Loam
// tools. The first prompt of the run says it, and the run hook says it again
// after a compact, which can drop that prompt.
func RunSandboxNote(s *store.Store, r store.Run) (string, error) {
	box, err := RunRules(s, r)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(runNote(box)), nil
}

// RunRules returns the sandbox rules of a run, which its session works in.
// The gate runs the checks of the run with the same rules.
func RunRules(s *store.Store, r store.Run) (sandbox.Rules, error) {
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return sandbox.Rules{}, err
	}
	return runRules(s, plot, r.Folder, r.ID)
}

// runRules returns the sandbox rules of the run runID that works in folder.
func runRules(s *store.Store, plot store.Plot, folder, runID string) (sandbox.Rules, error) {
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
	base := gitConfigFiles(admin, git)
	in := sandbox.Input{
		Home:      home,
		Machine:   sandbox.Extra{Read: machine.Read, Write: machine.Write, Hosts: machine.Hosts},
		Plot:      sandbox.Extra{Read: forPlot.Read, Write: forPlot.Write, Hosts: forPlot.Hosts},
		Protected: []string{s.Home()},
		Folder:    folder,
		GitDir:    git,
		Repos:     repos,
		GitConfig: base,
		// The plot folder holds the seed, which only Loam writes.
		NoWrite: []string{s.PlotDir(plot.ID)},
		Getenv:  os.Getenv,
	}
	if runID != "" {
		in.Private = RunTemp(s, runID)
	}
	for _, l := range plot.Links {
		if linkkind.IsLocal(l.Target) {
			in.Links = append(in.Links, linkkind.Expand(l.Target))
		}
	}
	r, err := sandbox.For(in)
	if err != nil {
		return sandbox.Rules{}, err
	}
	// The includes come after the rules, so that Loam knows which files the
	// run can write.
	temps := runTemps()
	inc := gitIncludes(home, base, func(f string) bool { return !r.Writable(f, temps...) && !r.Refuses(f) })
	for _, p := range r.AllowRead(inc.files...) {
		if _, err := os.Stat(p); err == nil {
			r.Notes = append(r.Notes, gitStops("A git config includes "+p+", and Bash cannot read it."))
		}
	}
	for _, f := range inc.skipped {
		r.Notes = append(r.Notes, gitStops("Loam did not follow the includes of the git config "+f+", because the run can write it or the sandbox refuses it. So Bash cannot read the files that it includes."))
	}
	for _, what := range inc.unread {
		r.Notes = append(r.Notes, gitStops("Loam could not follow the git config include "+what+"."))
	}
	if inc.late {
		r.Notes = append(r.Notes, gitStops("Loam did not read every git config include in time."))
	}
	return r, nil
}

// gitStops ends a note about git config that the sandbox does not allow.
func gitStops(what string) string {
	return what + " So git can stop in the sandbox. Do not work around it. Say so in your last message."
}

// gitConfigScopes are the config scopes whose files the sandbox reads. The
// worktree scope is left out: with extensions.worktreeConfig, a run can write
// config.worktree in the git folder, and an include there would name any file
// for the next rules of the run. So is the command scope, which comes from
// the environment.
var gitConfigScopes = []string{"system", "global", "local"}

// runTemps returns the folders that the sandbox of Claude Code lets the run
// write besides the rules: the temporary folders.
var runTemps = func() []string { return append(sandbox.Temps(), "/tmp") }

// gitConfigFiles returns the config files that git reads in the worktree
// with the git folder admin, in the scopes of gitConfigScopes, without the
// files that they include (see gitIncludes). It names the common git folder,
// so that git does not follow a commondir file that the run wrote. A file
// that git cannot name is not read in the sandbox, so an error gives none.
func gitConfigFiles(admin, common string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "config", "--list", "--no-includes", "--show-scope", "--show-origin", "-z")
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
	return files
}

// includeDepth is how many levels of includes git follows below the config
// file that it starts from (MAX_INCLUDE_DEPTH).
const includeDepth = 10

// includes are the files that the sandbox reads for the git config includes.
// skipped are files with includes that Loam did not follow, because the run
// can write them or the sandbox refuses them. unread are config files that
// git could not read and include paths that Loam does not expand. late is
// true when git did not answer in time.
type includes struct {
	files, skipped, unread []string
	late                   bool
}

// gitIncludes follows the include.path and includeIf.*.path entries of the
// base config files, to the depth that git follows, and takes the file of
// each entry whatever its condition. Git opens the file of a hasconfig
// condition also when the condition does not hold (TAS-194). The run can
// change its branch, so an onbranch condition can hold later in the run.
//
// It follows the includes of a file only when follow is true for it. The
// caller gives false for a file that the run can write, because the run
// could name any file there, and for a file that the sandbox refuses.
func gitIncludes(home string, base []string, follow func(string) bool) includes {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Git resolves a relative include from the folder of the name that it
	// opened, so a file that two links in two folders name can include two
	// files. The key holds the real path of the file and of that folder, so a
	// link to its own folder does not give a new key on each pass. On a volume
	// that does not ignore case, two names that differ in case are two files,
	// so the key keeps the case. A file with two names is then read twice, and
	// the depth ends a cycle through such names. The key also holds whether
	// Loam follows the name: a name that the run can write must not stop the
	// walk of another name of the same file that Loam follows.
	type fileKey struct {
		real, dir string
		follows   bool
	}
	seen := map[fileKey]bool{}
	key := func(f string) fileKey {
		return fileKey{sandbox.Real(f), sandbox.Real(filepath.Dir(f)), follow(f)}
	}
	for _, f := range base {
		seen[key(f)] = true
	}
	var inc includes
	next := base
	for depth := 0; depth < includeDepth && len(next) > 0; depth++ {
		var found []string
		for _, f := range next {
			entries, unread, err := includeEntries(ctx, home, f)
			if ctx.Err() != nil {
				inc.late = true
				return inc
			}
			inc.unread = append(inc.unread, unread...)
			if err != nil {
				inc.unread = append(inc.unread, f)
				continue
			}
			if len(entries) > 0 && !follow(f) {
				inc.skipped = append(inc.skipped, f)
				continue
			}
			for _, p := range entries {
				if k := key(p); !seen[k] {
					seen[k] = true
					inc.files = append(inc.files, p)
					// Git skips a missing file, so it has no includes to follow.
					if _, err := os.Stat(p); err == nil {
						found = append(found, p)
					}
				}
			}
		}
		next = found
	}
	return inc
}

// includeEntries returns the files that the include entries of the config
// file f name. Git reads a relative path from the folder of f, and ~/ from
// home. includeEntries leaves out a path that git would not expand in the
// same way, such as ~user/ or %(prefix)/, and returns it in unread. It also
// leaves out a folder, which git cannot read as a config file. A file with
// no include gives none. err is not nil when git cannot read f.
func includeEntries(ctx context.Context, home, f string) (paths, unread []string, err error) {
	out, err := exec.CommandContext(ctx, "git", "config", "--file", f, "--no-includes", "-z", "--get-regexp", `^include(if\..*)?\.path$`).Output()
	// git config exits 1 when it finds no entry.
	if exit := (*exec.ExitError)(nil); errors.As(err, &exit) && exit.ExitCode() == 1 {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	// Each entry is a key and its value, with a newline between them, ended
	// by NUL.
	for _, entry := range strings.Split(string(out), "\x00") {
		_, p, found := strings.Cut(entry, "\n")
		switch {
		case !found || p == "":
			continue
		case strings.HasPrefix(p, "~/"):
			p = gitPath(home + p[1:])
		case strings.HasPrefix(p, "~"), strings.HasPrefix(p, "%("):
			unread = append(unread, p)
			continue
		case filepath.IsAbs(p):
			p = gitPath(p)
		default:
			p = gitPath(filepath.Dir(f) + string(filepath.Separator) + p)
		}
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			continue
		}
		paths = append(paths, p)
	}
	return paths, unread, nil
}

// gitPath returns the file that the system opens for the path raw, as git
// builds it. Git does not clean the path, so the system follows each link
// before a "..". filepath.Clean removes "link/.." by the text, so gitPath
// resolves the folder of raw on disk instead. The last element keeps its
// name: git resolves the includes of a file from the folder of the name that
// it opened, so a link to a config file stays a name in its folder. When the
// folder does not exist, the system opens nothing, and gitPath cleans raw by
// the text.
func gitPath(raw string) string {
	i := strings.LastIndexByte(raw, filepath.Separator)
	if dir, err := filepath.EvalSymlinks(raw[:i+1]); err == nil {
		return filepath.Join(dir, raw[i+1:])
	}
	return filepath.Clean(raw)
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
