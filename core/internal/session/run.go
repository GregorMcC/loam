package session

import (
	"encoding/json"
	"strings"

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
func PrepareRun(s *store.Store, r store.Run, prompt, loam, model string) (*Plan, error) {
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
	plan, err := build(s, plot, r.Folder, claude, "run-"+r.ID, lead, loam, runSettings(r.ID))
	if err != nil {
		return nil, err
	}
	plan.SessionID = ""
	plan.Args = append(plan.Args, prompt)
	return plan, nil
}

// runSettings returns the settings of a run session: the allow rules of a
// seeded session, the run hooks, and env. The background session may start
// from the Claude Code supervisor, which does not pass the environment of
// the loam process, so the settings carry it.
func runSettings(runID string) settingsFunc {
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
			"permissions": map[string]any{"allow": rules(allowTools)},
			"hooks":       hooks,
			"env":         vars,
		}
		return json.MarshalIndent(s, "", "  ")
	}
}
