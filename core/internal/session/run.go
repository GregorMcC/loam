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
	git, err := gitCommonDir(folder)
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
		GitConfig: gitConfigFiles(folder),
		// The plot folder holds the seed, which only Loam writes.
		NoWrite: []string{s.PlotDir(plot.ID)},
		Getenv:  os.Getenv,
	}
	for _, r := range plot.Repos {
		in.Repos = append(in.Repos, r.Path)
	}
	for _, l := range plot.Links {
		if linkkind.IsLocal(l.Target) {
			in.Links = append(in.Links, linkkind.Expand(l.Target))
		}
	}
	return sandbox.For(in)
}

// gitConfigFiles returns the config files that git reads in dir, with the
// files that they include. A file that git cannot name is not read in the
// sandbox, so an error gives none.
func gitConfigFiles(dir string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "config", "--list", "--show-origin", "-z").Output()
	if err != nil {
		return nil
	}
	// Each entry is an origin and a key with its value, each one ended by NUL.
	var files []string
	parts := strings.Split(string(out), "\x00")
	for i := 0; i+1 < len(parts); i += 2 {
		if f, ok := strings.CutPrefix(parts[i], "file:"); ok && filepath.IsAbs(f) && !slices.Contains(files, f) {
			files = append(files, f)
		}
	}
	return files
}

// gitCommonDir returns the git folder that the checkout in dir shares with its
// worktrees. A commit in a worktree writes to it, so a run cannot commit
// without it.
func gitCommonDir(dir string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return "", fmt.Errorf("find the git folder of %s for the sandbox: %w", dir, err)
	}
	return strings.TrimSpace(string(out)), nil
}
