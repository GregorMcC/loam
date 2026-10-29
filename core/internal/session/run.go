package session

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
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
	plan, err := build(s, plot, r.Folder, claude, "run-"+r.ID, lead, loam, runSettings(r.ID, runRules(s, plot, r.Folder)), false)
	if err != nil {
		return nil, err
	}
	plan.SessionID = ""
	plan.Args = append(plan.Args, prompt)
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
			"permissions": map[string]any{"allow": rules(allowTools), "deny": sandbox.ToolDenies()},
			"hooks":       hooks,
			"env":         vars,
			"sandbox":     box.Settings(),
		}
		return json.MarshalIndent(s, "", "  ")
	}
}

// runRules returns the sandbox rules of a run that works in folder.
func runRules(s *store.Store, plot store.Plot, folder string) sandbox.Rules {
	home, _ := os.UserHomeDir()
	in := sandbox.Input{
		Home:   realPath(home),
		Folder: realPath(folder),
		GitDir: realPath(gitCommonDir(folder)),
		// The plot folder holds the seed, which only Loam writes.
		NoWrite: []string{realPath(s.PlotDir(plot.ID))},
		Getenv:  os.Getenv,
	}
	for _, r := range plot.Repos {
		in.Repos = append(in.Repos, realPath(r.Path))
	}
	for _, l := range plot.Links {
		if linkkind.IsLocal(l.Target) {
			in.Links = append(in.Links, realPath(linkkind.Expand(l.Target)))
		}
	}
	return sandbox.For(in)
}

// gitCommonDir returns the git folder that the checkout in dir shares with its
// worktrees, or "" when dir is not a checkout. A commit in a worktree writes
// to it.
func gitCommonDir(dir string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// realPath resolves the symlinks of path, because the sandbox matches real
// paths: on macOS, /var is a link to /private/var. A path that does not exist
// yet keeps its name below its resolved parent.
func realPath(path string) string {
	if path == "" {
		return ""
	}
	if r, err := filepath.EvalSymlinks(path); err == nil {
		return r
	}
	if r, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		return filepath.Join(r, filepath.Base(path))
	}
	return filepath.Clean(path)
}
