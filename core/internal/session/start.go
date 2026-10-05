// Package session starts a seeded Claude Code session (`loam start`) and
// answers its hooks (`loam hook`).
package session

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// StartOptions says how to start a session.
type StartOptions struct {
	PlotID string
	// Repo is the repo to start in, as an ID or a path. Empty means the main repo, or the plot
	// folder when the plot has no repos.
	Repo string
	// SessionID is the session UUID. Empty means Loam picks one.
	SessionID string
	// Loam is the absolute path of the loam binary, for the hook command.
	Loam string
	// Worktree starts the session in a worktree of the plot. It is a worktree
	// ID, a folder name, or a name. Repo then names the repo of the worktree,
	// when two repos have a worktree of that name.
	Worktree string
	// PlotFolder starts the session in the plot folder, also when the plot
	// has repos (ticket 93). Every repo is then an added folder. It does not
	// go with Repo or Worktree.
	PlotFolder bool
}

// Plan is a prepared launch of claude.
type Plan struct {
	Claude       string   // absolute path of the claude binary
	Dir          string   // start folder
	Args         []string // arguments after the program name
	Env          []string // full environment
	SessionID    string
	SettingsPath string
	// Worktree is the worktree that the session starts in, or nil.
	Worktree *store.Worktree
	// Setup is the setup command to run before claude, or "" when there is none
	// or it has succeeded. TrustNote asks for the first-session note.
	Setup string
	// SetupApproved is true when you approved this setup command before.
	SetupApproved bool
	TrustNote     bool
}

var uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// newUUID returns a random version 4 UUID.
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// inheritedClaudeVars are set by a parent Claude Code session. A new session
// must not inherit them: the hook and the MCP server would read the wrong PID
// and session.
var inheritedClaudeVars = []string{"CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "LOAM_PLOT"}

// allowTools are the allow rules of a seeded session (spec section 6). The
// other Loam tools have no rule (ticket 84): in auto mode the classifier
// decides, and in the default mode Claude Code asks as for any tool.
var allowTools = []string{"list_plots", "get_plot", "get_changes", "add_link", "update_link", "list_worktrees"}

func rules(tools []string) []string {
	out := make([]string, len(tools))
	for i, t := range tools {
		out[i] = "mcp__loam__" + t
	}
	return out
}

// shellQuote quotes s for a POSIX shell.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// settingsJSON returns the content of the per-session settings file.
func settingsJSON(loam string) ([]byte, error) {
	type hook struct {
		Type    string `json:"type"`
		Command string `json:"command"`
	}
	type group struct {
		Hooks []hook `json:"hooks"`
	}
	hooks := map[string]any{}
	for _, e := range paneEvents {
		hooks[e] = []group{{Hooks: []hook{{Type: "command", Command: shellQuote(loam) + " hook"}}}}
	}
	s := map[string]any{
		"permissions": map[string]any{"allow": rules(allowTools)},
		"hooks":       hooks,
	}
	return json.MarshalIndent(s, "", "  ")
}

// localDir returns the folder to add for a local link, or "" when the link is
// a web link, the path is missing, or the folder is too broad. A link to a
// file adds its folder.
func localDir(target string) string {
	info := linkkind.Classify(target, nil)
	if !info.Exists || !filepath.IsAbs(info.Path) {
		return ""
	}
	dir := info.Path
	if !info.IsDir {
		dir = filepath.Dir(info.Path)
	}
	if tooBroad(dir) {
		return ""
	}
	return dir
}

// tooBroad reports whether a folder is the root, the home folder, or a parent
// of the home folder. A session must never get one of them as an added
// folder: add_link needs no approval, so a link alone would give the next
// session every file of the account without a prompt.
func tooBroad(dir string) bool {
	dir = filepath.Clean(dir)
	if dir == string(filepath.Separator) {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	home = filepath.Clean(home)
	return dir == home || strings.HasPrefix(home, dir+string(filepath.Separator))
}

// Prepare checks the plot, writes the seed and the settings file, records the
// session, and returns the launch plan. It starts nothing.
func Prepare(s *store.Store, o StartOptions) (*Plan, error) {
	plot, err := s.GetPlot(o.PlotID)
	if err != nil {
		return nil, err
	}
	if err := refuseArchived(plot); err != nil {
		return nil, err
	}

	// Start folder.
	if o.PlotFolder && (o.Repo != "" || o.Worktree != "") {
		return nil, fmt.Errorf("--plot-folder does not go with --repo or --worktree: %w", store.ErrInvalid)
	}
	var wt *store.Worktree
	if o.Worktree != "" {
		w, err := worktree.Find(s, plot.ID, o.Repo, o.Worktree)
		if err != nil {
			return nil, err
		}
		wt = &w
	}
	var startRepo *store.Repo
	if o.Repo != "" && wt == nil { // with a worktree, Repo only picks the worktree
		r, err := worktree.FindRepo(plot, o.Repo)
		if err != nil {
			return nil, err
		}
		startRepo = &r
	} else if wt == nil && !o.PlotFolder {
		startRepo = plot.MainRepo()
	}
	dir := s.PlotDir(plot.ID)
	if wt != nil {
		dir = wt.Path
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			return nil, worktreeGone(dir)
		}
	} else if startRepo != nil {
		dir = startRepo.Path
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			return nil, fmt.Errorf("the repo folder %s is missing. Fix the repo path, then start again", dir)
		}
	}

	// Session ID.
	id := o.SessionID
	if id == "" {
		if id, err = newUUID(); err != nil {
			return nil, err
		}
	} else if !uuidRE.MatchString(id) {
		return nil, fmt.Errorf("--session-id %q is not a UUID: %w", id, store.ErrInvalid)
	}

	claude, err := findClaude()
	if err != nil {
		return nil, err
	}

	plan, err := build(s, plot, dir, claude, id, []string{"--session-id", id}, o.Loam)
	if err != nil {
		return nil, err
	}
	if wt != nil {
		first, err := firstSessionIn(s, plot.ID, dir)
		if err != nil {
			return nil, err
		}
		if err := prepareWorktree(s, plan, *wt, first); err != nil {
			return nil, err
		}
	}
	if err := s.AddSession(store.SessionRecord{SessionID: id, PlotID: plot.ID, StartFolder: dir}); err != nil {
		return nil, err
	}
	return plan, nil
}

// PrepareResume prepares `claude --resume` for a session record. It uses the
// stored start folder and the current plot. It adds no session record.
func PrepareResume(s *store.Store, sessionID, loam string) (*Plan, error) {
	rec, err := s.GetSession(sessionID)
	if err != nil {
		return nil, err
	}
	plot, err := s.GetPlot(rec.PlotID)
	if err != nil {
		return nil, err
	}
	if err := refuseArchived(plot); err != nil {
		return nil, err
	}
	if fi, err := os.Stat(rec.StartFolder); err != nil || !fi.IsDir() {
		if isWorktreeFolder(s, rec.StartFolder) {
			return nil, fmt.Errorf("the worktree folder %s of this session is gone, so the session cannot resume", rec.StartFolder)
		}
		return nil, fmt.Errorf("the start folder %s of this session is missing. Restore the folder, then resume again", rec.StartFolder)
	}
	claude, err := findClaude()
	if err != nil {
		return nil, err
	}
	plan, err := build(s, plot, rec.StartFolder, claude, sessionID, []string{"--resume", sessionID}, loam)
	if err != nil {
		return nil, err
	}
	if w, err := s.WorktreeByPath(rec.StartFolder); err == nil {
		if err := prepareWorktree(s, plan, w, false); err != nil {
			return nil, err
		}
	}
	return plan, nil
}

// refuseArchived fails for an archived plot. A session needs an active plot.
func refuseArchived(p store.Plot) error {
	if p.Archived {
		return fmt.Errorf("%w: unarchive first with \"loam unarchive %s\"", store.ErrArchived, p.ID)
	}
	return nil
}

func findClaude() (string, error) {
	return claudebin.Find()
}

// build writes the seed and the settings file and returns the launch plan.
// idArgs are the first claude arguments: --session-id or --resume.
func build(s *store.Store, plot store.Plot, dir, claude, id string, idArgs []string, loam string) (*Plan, error) {
	extra, err := extraArgs()
	if err != nil {
		return nil, err
	}

	// Added folders: the plot folder, the other repos, the local links.
	var adds []string
	seen := map[string]bool{filepath.Clean(dir): true}
	if w, err := s.WorktreeByPath(dir); err == nil {
		seen[w.Repo] = true // a worktree session does not see the normal checkout
	}
	add := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		adds = append(adds, p)
	}
	adds = append(adds, s.PlotDir(plot.ID))
	seen[s.PlotDir(plot.ID)] = true
	for _, r := range plot.Repos {
		add(r.Path)
	}
	for _, l := range plot.Links {
		add(localDir(l.Target))
	}

	if err := seed.WritePlot(s, plot); err != nil {
		return nil, fmt.Errorf("write the seed: %w", err)
	}
	settingsDir := filepath.Join(s.Home(), "sessions")
	if err := os.MkdirAll(settingsDir, 0o755); err != nil {
		return nil, err
	}
	settingsPath := filepath.Join(settingsDir, id+".json")
	b, err := settingsJSON(loam)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(settingsPath, b, 0o644); err != nil {
		return nil, err
	}

	args := append([]string{}, idArgs...)
	for _, a := range adds {
		args = append(args, "--add-dir", a)
	}
	args = append(args, "--settings", settingsPath)
	args = append(args, extra...)

	env := cleanEnv(os.Environ())
	env = append(env, "LOAM_PLOT="+plot.ID, "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1")
	return &Plan{Claude: claude, Dir: dir, Args: args, Env: env, SessionID: id, SettingsPath: settingsPath}, nil
}

// extraArgs reads LOAM_CLAUDE_EXTRA_ARGS, a JSON array of strings that only
// tests set. The end-to-end suite uses it to run claude in print mode.
func extraArgs() ([]string, error) {
	v := os.Getenv("LOAM_CLAUDE_EXTRA_ARGS")
	if v == "" {
		return nil, nil
	}
	var out []string
	if err := json.Unmarshal([]byte(v), &out); err != nil {
		return nil, fmt.Errorf("LOAM_CLAUDE_EXTRA_ARGS is not a JSON array of strings: %w", store.ErrInvalid)
	}
	return out, nil
}

// cleanEnv removes the variables that a parent session sets, and the two
// variables that Prepare sets again.
func cleanEnv(env []string) []string {
	// LOAM_CLAUDE_EXTRA_ARGS is for tests. Drop it, so it never reaches a
	// session or a loam start that the session runs.
	drop := append([]string{"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "LOAM_CLAUDE_EXTRA_ARGS"}, inheritedClaudeVars...)
	out := make([]string, 0, len(env))
outer:
	for _, kv := range env {
		for _, d := range drop {
			if strings.HasPrefix(kv, d+"=") {
				continue outer
			}
		}
		out = append(out, kv)
	}
	return out
}

// Exec replaces the current process with claude. It returns only on error.
func Exec(p *Plan) error {
	if err := os.Chdir(p.Dir); err != nil {
		return err
	}
	return syscall.Exec(p.Claude, append([]string{"claude"}, p.Args...), p.Env)
}
