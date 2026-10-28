// Package contract holds the contract test. It runs the real loam binary for
// every command that has --json output, saves each output as a fixture in
// contract/fixtures/, and checks each output against a JSON Schema in
// contract/schema/. See contract/README.md at the repo root.
package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

var update = flag.Bool("update", false, "rewrite the fixtures in contract/fixtures")

// contractDir is the contract folder at the repo root.
var contractDir = filepath.Join("..", "..", "..", "contract")

func updating() bool { return *update || os.Getenv("LOAM_CONTRACT_UPDATE") == "1" }

// Entry is one line of manifest.json: how a fixture was made.
type Entry struct {
	// Name is the fixture file name without .json.
	Name string `json:"name"`
	// Args are the arguments of loam, with IDs normalized.
	Args []string `json:"args"`
	// ExitCode is the exit code of the run.
	ExitCode int `json:"exit_code"`
	// Schema is the schema file name without .json.
	Schema string `json:"schema"`
}

// harness runs the binary in a temp store and normalizes what it prints.
type harness struct {
	t       *testing.T
	bin     string
	env     []string
	root    string // temp root, resolved
	home    string // LOAM_HOME
	ghState string // the state file of the fake gh
	tokens  map[string]string
	counts  map[string]int
	entries []Entry
	outputs map[string][]byte // normalized output by fixture name
	stdin   string            // the input of the next command
}

var timeRE = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)`)

const fixedTime = "2026-01-01T00:00:00Z"

// headStandIn is the PR head in testdata/github.json that the scenario
// replaces with the commit of the worktrees. fixedHead replaces that commit
// in the fixtures.
const (
	headStandIn = "LOCAL_HEAD"
	fixedHead   = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
)

func newHarness(t *testing.T) *harness {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t, root: root, tokens: map[string]string{}, counts: map[string]int{}, outputs: map[string][]byte{}}
	h.home = filepath.Join(root, "loamhome")
	for _, d := range []string{h.home, filepath.Join(root, "userhome"), filepath.Join(root, "repos")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("LOAM_HOME", h.home)
	testutil.GitEnv(t)
	h.bin = testutil.BuildLoam(t)
	fake := testutil.FakeClaude(t)
	// A fake gh answers each refresh from a made-up GitHub repo.
	state, err := os.ReadFile(filepath.Join("testdata", "github.json"))
	if err != nil {
		t.Fatal(err)
	}
	h.ghState = testutil.FakeGH(t, string(state))
	// The editor writes a fixed brief into the file that loam gives it.
	ed := filepath.Join(root, "ed.sh")
	script := "#!/bin/sh\nprintf '# Name\\nLoam\\n\\n# What\\nA personal tool.\\n\\n# Why\\nTo keep work in one place.\\n\\n# Where it stands\\nBuilding.\\n' > \"$1\"\n"
	if err := os.WriteFile(ed, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	// A fake open command, and an Obsidian config with one vault. The vault
	// holds one note.
	vault := filepath.Join(root, "vault")
	if err := os.MkdirAll(vault, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vault, "note.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfgDir := filepath.Join(root, "userhome", "Library", "Application Support", "obsidian")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg, _ := json.Marshal(map[string]any{"vaults": map[string]any{"v1": map[string]any{"path": vault}}})
	if err := os.WriteFile(filepath.Join(cfgDir, "obsidian.json"), cfg, 0o644); err != nil {
		t.Fatal(err)
	}
	fakeOpen := filepath.Join(root, "open.sh")
	if err := os.WriteFile(fakeOpen, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h.env = append(os.Environ(),
		"LOAM_OPEN="+fakeOpen,
		"LOAM_HOME="+h.home,
		"HOME="+filepath.Join(root, "userhome"),
		"CLAUDE_CONFIG_DIR="+filepath.Join(root, "userhome"),
		"VISUAL="+ed,
		"PATH="+fake+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	return h
}

// token returns the stable stand-in for a random ID. Tokens have the shape of
// a real ID: 10 characters from a to z and 2 to 7.
func (h *harness) token(kind, real string) string {
	if tok, ok := h.tokens[real]; ok {
		return tok
	}
	h.counts[kind]++
	tok := kind + strings.Repeat("a", 5) + string(rune('a'+h.counts[kind]))
	h.tokens[real] = tok
	return tok
}

// raw runs loam and returns stdout, stderr, and the exit code.
func (h *harness) raw(args ...string) (string, string, int) {
	h.t.Helper()
	cmd := exec.Command(h.bin, args...)
	cmd.Env = h.env
	cmd.Stdin = strings.NewReader(h.stdin)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	err := cmd.Run()
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code = ee.ExitCode()
	} else if err != nil {
		h.t.Fatalf("loam %v: %v", args, err)
	}
	return o.String(), e.String(), code
}

// harvest reads the store and gives each plot, link, and repo ID its token.
// Run it after each write and before normalizing the output of that write.
func (h *harness) harvest() {
	h.t.Helper()
	out, _, code := h.raw("list", "--json")
	if code != 0 {
		h.t.Fatalf("harvest list: exit %d", code)
	}
	var plots []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(out), &plots); err != nil {
		h.t.Fatal(err)
	}
	for _, p := range plots {
		h.token("plot", p.ID)
		out, _, _ := h.raw("show", p.ID, "--json")
		var full struct {
			Links []struct{ ID string } `json:"links"`
			Repos []struct{ ID string } `json:"repos"`
		}
		if err := json.Unmarshal([]byte(out), &full); err != nil {
			h.t.Fatal(err)
		}
		for _, l := range full.Links {
			h.token("link", l.ID)
		}
		for _, r := range full.Repos {
			h.token("repo", r.ID)
		}
	}
	// A worktree ID gets a token of 10 characters too, so it matches the ID pattern.
	out, _, _ = h.raw("worktree", "list", "--json")
	var wts []struct {
		Worktree struct {
			ID string `json:"id"`
		} `json:"worktree"`
	}
	if err := json.Unmarshal([]byte(out), &wts); err != nil {
		h.t.Fatal(err)
	}
	for _, w := range wts {
		h.token("wtre", w.Worktree.ID)
	}
	out, _, _ = h.raw("run", "list", "--json")
	var runs []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		h.t.Fatal(err)
	}
	for _, r := range runs {
		h.token("runr", r.ID)
	}
	out, _, _ = h.raw("recurring", "list", "--json")
	var recurring struct {
		Recurring []struct{ ID string } `json:"recurring"`
	}
	if err := json.Unmarshal([]byte(out), &recurring); err != nil {
		h.t.Fatal(err)
	}
	for _, r := range recurring.Recurring {
		h.token("recu", r.ID)
	}
	out, _, _ = h.raw("rule", "list", "--json")
	var rules struct {
		Rules []struct{ ID string } `json:"rules"`
	}
	if err := json.Unmarshal([]byte(out), &rules); err != nil {
		h.t.Fatal(err)
	}
	for _, r := range rules.Rules {
		h.token("rule", r.ID)
	}
}

// normalize replaces IDs, times, and temp paths with fixed values.
func (h *harness) normalize(s string) string {
	reals := make([]string, 0, len(h.tokens))
	for real := range h.tokens {
		reals = append(reals, real)
	}
	sort.Strings(reals) // map order is random: keep the replacer deterministic
	// Claude Code names a folder after a path (see claudeProjectName). The
	// temp root is in such a name too.
	pairs := []string{claudeProjectName(h.root), claudeProjectName("/tmp/loam-contract")}
	for _, real := range reals {
		pairs = append(pairs, real, h.tokens[real])
	}
	s = strings.NewReplacer(append(pairs,
		h.home, "/tmp/loam-contract/loamhome",
		h.root, "/tmp/loam-contract")...).Replace(s)
	return timeRE.ReplaceAllString(s, fixedTime)
}

// run runs loam with --json, checks the exit code, checks that stderr is
// empty on a failure, and records the normalized output as a fixture.
func (h *harness) run(name, schema string, wantExit int, args ...string) []byte {
	h.t.Helper()
	full := append(append([]string{}, args...), "--json")
	return h.record(name, schema, wantExit, full)
}

// runInput is run with input on stdin.
func (h *harness) runInput(name, schema, input string, wantExit int, args ...string) []byte {
	h.t.Helper()
	h.stdin = input
	defer func() { h.stdin = "" }()
	return h.run(name, schema, wantExit, args...)
}

// record is run without the added --json flag.
func (h *harness) record(name, schema string, wantExit int, args []string) []byte {
	h.t.Helper()
	out, errOut, code := h.raw(args...)
	if code != wantExit {
		h.t.Fatalf("%s: loam %v exited %d, want %d\nstdout: %s\nstderr: %s", name, args, code, wantExit, out, errOut)
	}
	if wantExit != 0 && errOut != "" {
		h.t.Errorf("%s: stderr must be empty with --json: %q", name, errOut)
	}
	h.harvest()
	norm := h.normalize(out)
	var v any
	if err := json.Unmarshal([]byte(norm), &v); err != nil {
		h.t.Fatalf("%s: stdout is not one JSON document: %v\n%s", name, err, out)
	}
	pretty, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		h.t.Fatal(err)
	}
	pretty = append(pretty, '\n')
	nargs := make([]string, len(args))
	for i, a := range args {
		nargs[i] = h.normalize(a)
	}
	h.entries = append(h.entries, Entry{Name: name, Args: nargs, ExitCode: code, Schema: schema})
	h.outputs[name] = pretty
	return []byte(out) // the raw output, so the scenario can read real IDs
}

// pane runs `loam hook` with the hook JSON on stdin and a pane socket in the
// environment, and records the line that arrives at the socket as a fixture.
func (h *harness) pane(name, schema, stdin string) {
	h.t.Helper()
	dir, err := os.MkdirTemp("", "lp") // a short path: Unix socket paths are short on macOS
	if err != nil {
		h.t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "s")
	l, err := net.Listen("unix", sock)
	if err != nil {
		h.t.Fatal(err)
	}
	defer l.Close()
	lines := make(chan []byte, 1)
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		var b bytes.Buffer
		b.ReadFrom(c)
		lines <- b.Bytes()
	}()
	cmd := exec.Command(h.bin, "hook")
	cmd.Env = append(append([]string{}, h.env...), "LOAM_PANE_SOCKET="+sock)
	cmd.Stdin = strings.NewReader(stdin)
	if out, err := cmd.CombinedOutput(); err != nil || len(out) != 0 {
		h.t.Fatalf("%s: loam hook: %v, output %q", name, err, out)
	}
	var raw []byte
	select {
	case raw = <-lines:
	case <-time.After(5 * time.Second):
		h.t.Fatalf("%s: no line on the pane socket", name)
	}
	if !bytes.HasSuffix(raw, []byte("\n")) || bytes.Count(raw, []byte("\n")) != 1 {
		h.t.Fatalf("%s: want one line that ends in a newline, got %q", name, raw)
	}
	var v any
	if err := json.Unmarshal([]byte(h.normalize(string(raw))), &v); err != nil {
		h.t.Fatalf("%s: the line is not JSON: %v\n%s", name, err, raw)
	}
	pretty, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		h.t.Fatal(err)
	}
	h.entries = append(h.entries, Entry{Name: name, Args: []string{"hook"}, ExitCode: 0, Schema: schema})
	h.outputs[name] = append(pretty, '\n')
}

// scenario runs every command with --json, in an order that makes each one
// print something useful. It fills h.entries and h.outputs.
func scenario(t *testing.T) *harness {
	h := newHarness(t)

	type changeOut struct {
		ChangeID int64 `json:"change_id"`
		Link     struct{ ID string }
		Repo     struct{ ID string }
	}
	var plot struct {
		ID       string           `json:"id"`
		Versions map[string]int64 `json:"versions"`
	}
	parse := func(b []byte, v any) {
		t.Helper()
		if err := json.Unmarshal(b, v); err != nil {
			t.Fatal(err)
		}
	}
	repo := func(n string) string {
		p := filepath.Join(h.root, "repos", n)
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
		return p
	}

	h.run("version", "version", 0, "version")
	h.run("list_empty", "list", 0, "list")
	h.run("sessions_empty", "sessions", 0, "sessions")
	h.run("changes_empty", "changes", 0, "changes")

	parse(h.run("new", "new", 0, "new", "Loam"), &plot)
	loam := plot.ID
	h.run("new_app", "new", 0, "new", "Loam Docs", "--actor", "app")
	h.run("list", "list", 0, "list")
	h.run("show", "show", 0, "show", loam)
	h.run("set", "set", 0, "set", loam, "what", "A personal tool for plots.")
	h.run("edit", "edit", 0, "edit", loam)

	var c changeOut
	parse(h.run("link_add", "link-add", 0, "link", "add", loam, "Spec", "https://example.com/spec", "--note", "The v1 spec"), &c)
	linkA := c.Link.ID
	parse(h.run("link_add_app", "link-add", 0, "link", "add", loam, "Board", "https://example.com/board", "--actor", "app"), &c)
	linkB := c.Link.ID
	h.run("link_edit", "link-edit", 0, "link", "edit", loam, linkA, "--label", "Spec v1")
	h.run("link_rm", "link-rm", 0, "link", "rm", loam, linkB)

	parse(h.run("repo_add", "repo-add", 0, "repo", "add", loam, repo("core"), "--note", "Go core"), &c)
	repoA := c.Repo.ID
	parse(h.run("repo_add_second", "repo-add", 0, "repo", "add", loam, repo("app")), &c)
	repoB := c.Repo.ID
	h.run("repo_edit", "repo-edit", 0, "repo", "edit", loam, repoB, "--note", "Swift app")
	h.run("repo_main", "repo-main", 0, "repo", "main", loam, repoB)
	h.run("repo_rm", "repo-rm", 0, "repo", "rm", loam, repoA)
	parse(h.run("repo_add_third", "repo-add", 0, "repo", "add", loam, repo("docs")), &c)
	h.run("repo_rm_main", "repo-rm", 0, "repo", "rm", loam, repoB, "--main", repo("docs"))
	h.run("show_full", "show", 0, "show", loam)

	// Sessions: loam start runs the fake claude and records the session.
	if _, errOut, code := h.raw("start", loam, "--session-id", "11111111-2222-4333-8444-555555555555"); code != 0 {
		t.Fatalf("loam start: exit %d: %s", code, errOut)
	}
	h.run("sessions", "sessions", 0, "sessions")
	h.run("sessions_plot", "sessions", 0, "sessions", loam)

	// Pane socket: loam hook writes one line for each event in the table.
	hookIn := func(event, extra string) string {
		return fmt.Sprintf(`{"session_id":"11111111-2222-4333-8444-555555555555","cwd":%q,"hook_event_name":%q%s}`,
			filepath.Join(h.root, "repos", "core"), event, extra)
	}
	h.pane("pane_session_start", "pane-event", hookIn("SessionStart", `,"source":"startup"`))
	h.pane("pane_user_prompt_submit", "pane-event", hookIn("UserPromptSubmit", `,"source":"user"`))
	h.pane("pane_stop", "pane-event", hookIn("Stop", ""))
	h.pane("pane_notification", "pane-event", hookIn("Notification", `,"notification_type":"agent_needs_input"`))

	h.pane("pane_notification_permission", "pane-event", hookIn("Notification", `,"notification_type":"permission_prompt"`))
	h.pane("pane_notification_elicitation_response", "pane-event",
		hookIn("Notification", `,"notification_type":"elicitation_response"`))
	h.pane("pane_post_tool_use_failure", "pane-event", hookIn("PostToolUseFailure", `,"tool_name":"Bash","error":"exit 1"`))

	h.run("move", "move", 0, "move", "Loam Docs", "1")

	// Setup check: one step done, one not done.
	cfg := fmt.Sprintf(`{"projects":{%q:{"hasTrustDialogAccepted":true}}}`, filepath.Join(h.home, "plots"))
	if err := os.WriteFile(filepath.Join(h.root, "userhome", ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	h.run("setup_check", "setup-check", 0, "setup", "--check")

	// Undo. The edit step changed "what" after the set step, so the undo of the
	// set clashes. The undo of the link edit does not.
	h.run("undo", "undo", 0, "undo", fmt.Sprint(lastChangeOf(t, h, loam, "link:")), "--actor", "app")
	setID := firstChangeOf(t, h, loam, "what")
	h.run("error_undo_clash", "error", 11, "undo", fmt.Sprint(setID))
	h.run("undo_overwrite", "undo", 0, "undo", fmt.Sprint(setID), "--overwrite")

	h.run("changes", "changes", 0, "changes")
	h.run("changes_plot", "changes", 0, "changes", loam)
	h.run("changes_since", "changes", 0, "changes", "--since", "9")
	h.run("export", "export", 0, "export")
	h.run("export_changes", "export", 0, "export", "--changes")

	// Link kinds and loam open. The links cover each kind. The vault note
	// exists, the missing note does not.
	for _, l := range [][2]string{
		{"Notion page", "https://www.notion.so/Loam-0123456789abcdef"},
		{"Linear issue", "https://linear.app/acme/issue/ENG-1/fix"},
		{"GitHub repo", "https://github.com/GregorMcC/loam"},
		{"Core folder", repo("core")},
		{"Vault note", filepath.Join(h.root, "vault", "note.md")},
		{"Missing note", filepath.Join(h.root, "vault", "missing.md")},
	} {
		if _, errOut, code := h.raw("link", "add", loam, l[0], l[1]); code != 0 {
			t.Fatalf("link add %s: exit %d: %s", l[0], code, errOut)
		}
	}
	h.run("show_links", "show", 0, "show", loam)
	h.run("open_url", "open", 0, "open", loam, "GitHub repo")
	h.run("open_vault", "open", 0, "open", loam, "Vault note")
	h.run("open_folder", "open", 0, "open", loam, "Core folder")
	h.run("error_link_path_missing", "error", 12, "open", loam, "Missing note")

	// Errors, one for each exit code that loam returns today.
	h.run("error_generic", "error", 1, "undo", "9999")
	h.run("error_invalid", "error", 2, "move", loam, "99")
	h.run("error_stale", "error", 10, "set", loam, "what", "x", "--expect", "what=1")
	h.run("error_unknown_plot", "error", 14, "show", "nosuchplot")
	h.run("error_ambiguous", "error", 15, "show", "lo")

	// Worktrees. The scenario runs them last, so they keep the change IDs above.
	// The repo has a bare remote and an ignored .env file to copy.
	gitRepo, gitRemote := testutil.GitRepoAt(t, filepath.Join(h.root, "remote.git"), filepath.Join(h.root, "repos", "web"))
	if err := os.WriteFile(filepath.Join(gitRepo, ".env"), []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitRepo, ".git", "info", "exclude"), []byte(".env\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	parse(h.run("repo_add_git", "repo-add", 0, "repo", "add", loam, gitRepo, "--setup", "make setup", "--copy", ".env"), &c)
	h.run("repo_edit_setup", "repo-edit", 0, "repo", "edit", loam, c.Repo.ID, "--setup", "npm ci")
	h.run("repo_edit_after_merge", "repo-edit", 0, "repo", "edit", loam, c.Repo.ID, "--after-merge", "remove")
	h.run("worktree_new_dry_run", "worktree-new-dry-run", 0, "worktree", "new", loam, gitRepo, "fix-login", "--dry-run",
		"--goal", "Fix the login form", "--link", "https://github.com/example/widgets/issues/57")
	h.run("worktree_new", "worktree-new", 0, "worktree", "new", loam, gitRepo, "fix-login",
		"--goal", "Fix the login form", "--link", "https://github.com/example/widgets/issues/57")
	h.run("worktree_list", "worktree-list", 0, "worktree", "list", loam)
	h.run("worktree_rm_dry_run", "worktree-rm", 0, "worktree", "rm", loam, "fix-login", "--dry-run")
	h.run("worktree_rm", "worktree-rm", 0, "worktree", "rm", loam, "fix-login")
	h.run("worktree_list_empty", "worktree-list", 0, "worktree", "list", loam)

	// Ship state: one worktree for each stage, in the order of the rule, and
	// then a second Ready to merge whose optional checks failed (UNSTABLE).
	// Each worktree comes from the local remote. Then origin names a made-up
	// GitHub repo over SSH, and a fake ssh serves the local remote, so git
	// can still fetch and push. testdata/github.json holds what the fake gh
	// answers.
	for _, name := range []string{"add-search", "old-theme", "fix-login", "new-api", "rename-users", "native-panel", "deploy-docs",
		"try-dark-mode", "update-deps", "speed-up-tests", "add-billing", "sign-commits", "link-labels", "pushed-only", "local-work",
		"tidy-styles"} {
		if _, errOut, code := h.raw("worktree", "new", loam, gitRepo, name); code != 0 {
			t.Fatalf("worktree new %s: exit %d: %s", name, code, errOut)
		}
	}
	if err := os.WriteFile(filepath.Join(h.home, "worktrees", loam, "web-local-work", "notes.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A removal that would lose work, and a removal with a pane open, give
	// details. The app words them, since the messages name flags (ticket 113).
	h.run("error_worktree_rm_unsafe", "error", 1, "worktree", "rm", loam, "local-work", "--dry-run")
	h.run("error_worktree_rm_panes_open", "error", 1, "worktree", "rm", loam, "local-work",
		"--open-pane", filepath.Join(h.home, "worktrees", loam, "web-local-work"))
	// A merged or closed PR shows only when the worktree has its head checked
	// out. Each worktree starts at the same commit, which changes from run to
	// run, so the PR head in the state is a stand-in, and the fixture gets a
	// fixed value.
	localHead := testutil.Git(t, filepath.Join(h.home, "worktrees", loam, "web-add-search"), "rev-parse", "HEAD")
	ghState, err := os.ReadFile(h.ghState)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.ghState, []byte(strings.ReplaceAll(string(ghState), headStandIn, localHead)), 0o644); err != nil {
		t.Fatal(err)
	}
	h.tokens[localHead] = fixedHead
	// A land needs a repo on GitHub.
	h.run("error_gh_unavailable", "error", 17, "worktree", "land", loam, "add-search")
	testutil.FakeGitHub(t, gitRemote)
	h.env = append(h.env, "GIT_SSH_COMMAND="+os.Getenv("GIT_SSH_COMMAND"), "GIT_SSH_VARIANT="+os.Getenv("GIT_SSH_VARIANT"))
	testutil.Git(t, gitRepo, "remote", "set-url", "origin", testutil.GitHubOrigin)
	h.run("worktree_list_stages", "worktree-list", 0, "worktree", "list", loam, "--refresh")

	// Land, rerun, and update. The fake gh merges the PR and deletes the
	// branch in its state. link-labels is ready to merge, rename-users has
	// changes requested, new-api has conflicts, try-dark-mode is a draft,
	// and sign-commits is blocked. GitHub does not run run 302 of
	// native-panel again.
	h.run("worktree_land_dry_run", "worktree-land", 0, "worktree", "land", loam, "link-labels", "--dry-run")
	h.run("worktree_land_dry_run_blocked", "worktree-land", 0, "worktree", "land", loam, "rename-users", "--dry-run")
	h.run("error_not_ready", "error", 16, "worktree", "land", loam, "new-api")
	h.run("error_not_ready_draft", "error", 16, "worktree", "land", loam, "try-dark-mode", "--auto")
	// The head that the caller looked at is not the PR head: no check blocks, and nothing merges.
	h.run("error_not_ready_head", "error", 16, "worktree", "land", loam, "link-labels", "--head", strings.Repeat("b", 40))
	h.run("worktree_land", "worktree-land", 0, "worktree", "land", loam, "link-labels", "--method", "rebase")
	h.run("worktree_land_auto", "worktree-land", 0, "worktree", "land", loam, "sign-commits", "--auto")
	h.run("worktree_rerun", "worktree-rerun", 0, "worktree", "rerun", loam, "native-panel")
	// GitHub adds a merge commit to update-deps. The fetch after the update
	// needs the branch on the remote.
	testutil.Git(t, filepath.Join(h.home, "worktrees", loam, "web-update-deps"), "push", "origin", "update-deps")
	h.run("worktree_update", "worktree-update", 0, "worktree", "update", loam, "update-deps")

	// Archive, unarchive, and delete. They run last too.
	h.run("archive", "show", 0, "archive", "Loam Docs")
	h.run("list_archived", "list", 0, "list", "--archived")
	h.run("unarchive", "show", 0, "unarchive", "Loam Docs")
	// A plot to delete. It has one session, and Claude Code has a folder for it.
	var scrap struct {
		ID string `json:"id"`
	}
	out, errOut, code := h.raw("new", "Scrap", "--json")
	if code != 0 {
		t.Fatalf("new Scrap: exit %d: %s", code, errOut)
	}
	parse([]byte(out), &scrap)
	h.harvest() // the plot is gone after the delete, so its token must exist before
	if _, errOut, code := h.raw("start", scrap.ID, "--session-id", "44444444-2222-4333-8444-555555555555"); code != 0 {
		t.Fatalf("start Scrap: exit %d: %s", code, errOut)
	}
	claudeDir := filepath.Join(h.root, "userhome", "projects", claudeProjectName(filepath.Join(h.home, "plots", scrap.ID)))
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	h.run("error_delete_not_archived", "error", 1, "delete", scrap.ID)
	if _, errOut, code := h.raw("archive", scrap.ID); code != 0 {
		t.Fatalf("archive Scrap: exit %d: %s", code, errOut)
	}
	h.run("delete", "delete", 0, "delete", scrap.ID)

	// A checkout with uncommitted changes keeps its branch, and the add warns (ticket 91).
	// It runs last, so it moves no change ID above.
	dirty, _ := testutil.GitRepoAt(t, filepath.Join(h.root, "dirty.git"), filepath.Join(h.root, "repos", "dirty"))
	if err := os.WriteFile(filepath.Join(dirty, "README.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.run("repo_add_dirty", "repo-add", 0, "repo", "add", loam, dirty)

	// A goal edit is a change, so it runs last too. A stale --expect gives
	// the current worktree.
	var edit struct {
		Worktree struct{ ID string } `json:"worktree"`
	}
	parse(h.run("worktree_edit", "worktree-edit", 0, "worktree", "edit", loam, "fix-login", "--goal", "Fix the login form on phones"), &edit)
	h.run("error_stale_worktree", "error", 10, "worktree", "edit", loam, "fix-login", "--goal", "x",
		"--expect", "worktree:"+edit.Worktree.ID+"=0")

	// Runs, in a plot of their own, so the lists above keep their worktrees.
	// Claude Code must trust the repo. The setup command of the repo must
	// pass in the new worktree. The fake claude stands in for claude --bg and
	// claude stop, so no hook records a session.
	cfg = fmt.Sprintf(`{"projects":{%q:{"hasTrustDialogAccepted":true},%q:{"hasTrustDialogAccepted":true}}}`,
		filepath.Join(h.home, "plots"), gitRepo)
	if err := os.WriteFile(filepath.Join(h.root, "userhome", ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"new", "Runs"}, {"repo", "add", "Runs", gitRepo}, {"repo", "edit", "Runs", gitRepo, "--setup", "true"}} {
		if _, errOut, code := h.raw(args...); code != 0 {
			t.Fatalf("%v: exit %d: %s", args, code, errOut)
		}
	}
	var started struct {
		Run struct{ ID string } `json:"run"`
	}
	parse(h.run("run_start", "run-start", 0, "run", "start", "Runs", "--title", "Fix the login form",
		"--goal", "The login form works on phones.", "--check", "Go tests=go test ./...",
		"--link", "https://github.com/example/widgets/issues/57"), &started)
	h.run("run_list", "run-list", 0, "run", "list", "Runs")
	h.run("run_events", "run-events", 0, "run", "events")
	h.run("run_events_plot_since", "run-events", 0, "run", "events", "--plot", "Runs", "--since", "2020-01-01T00:00:00Z")
	// The intake of the plot: the issues of its GitHub repo, from the fake gh,
	// and the tickets of a map in its links. Issue 57 has the run above.
	tickets := filepath.Join(h.root, "build", "issues")
	if err := os.MkdirAll(tickets, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{
		"../map.md":           "# Build\n",
		"12-run-page-plan.md": "Status: open\nBlocked by: none\n\n# Run page: show the plan\n",
		"13-run-page-diff.md": "Status: open\nBlocked by: 12\n\n# Run page: show the diff\n",
		"9-first-ticket.md":   "Status: resolved\n\n# The first ticket\n",
	} {
		if err := os.WriteFile(filepath.Join(tickets, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, errOut, code := h.raw("link", "add", "Runs", "Build map", filepath.Join(h.root, "build", "map.md")); code != 0 {
		t.Fatalf("link add: exit %d: %s", code, errOut)
	}
	// Linear: a fake API, and a secrets file in place of the Keychain. The
	// key goes in with linear key set, and a team link gives the plot Linear
	// issues.
	lin := testutil.FakeLinear(t)
	secrets := filepath.Join(h.root, "secrets.json")
	h.env = append(h.env, "LOAM_LINEAR_URL="+lin.URL, "LOAM_SECRETS_FILE="+secrets)
	h.run("linear_status_none", "linear-status", 0, "linear", "status")
	h.runInput("linear_key_set", "linear-key", testutil.LinearKey+"\n", 0, "linear", "key", "set")
	h.run("linear_status", "linear-status", 0, "linear", "status")
	if _, errOut, code := h.raw("link", "add", "Runs", "ENG team", "https://linear.app/acme/team/ENG/active"); code != 0 {
		t.Fatalf("link add: exit %d: %s", code, errOut)
	}
	h.run("intake_list", "intake-list", 0, "intake", "list", "Runs")
	h.run("linear_key_rm", "linear-key", 0, "linear", "key", "rm")
	h.run("run_status", "run-status", 0, "run", "status", started.Run.ID)
	h.run("run_stop", "run-stop", 0, "run", "stop", started.Run.ID)

	// Ship (ticket 206). A run with no checks passes its gate at once, when
	// its session ends a turn. The repo is on GitHub, so the run ships: the
	// tick pushes the branch over the fake ssh and opens the PR on the fake gh.
	out, errOut, code = h.raw("run", "start", "Runs", "--title", "Tidy the README", "--json")
	if code != 0 {
		t.Fatalf("run start: exit %d: %s", code, errOut)
	}
	var tidy struct {
		Run struct{ ID, Folder string } `json:"run"`
	}
	parse([]byte(out), &tidy)
	hook := func(event string) {
		t.Helper()
		h.stdin = fmt.Sprintf(`{"hook_event_name":%q,"session_id":"c57ef956-3136-4e86-bfde-da8facfe0523"}`, event)
		defer func() { h.stdin = "" }()
		if _, errOut, code := h.raw("run", "hook", tidy.Run.ID); code != 0 {
			t.Fatalf("run hook %s: exit %d: %s", event, code, errOut)
		}
	}
	hook("SessionStart")
	// The session commits one change, which the diff of ticket 207 shows.
	if err := os.WriteFile(filepath.Join(tidy.Run.Folder, "README.md"), []byte("# Loam\n\nA terminal for plots.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, tidy.Run.Folder, "commit", "-qam", "Tidy the README")
	h.tokens[testutil.Git(t, tidy.Run.Folder, "rev-parse", "HEAD")] = runHead
	hook("Stop")
	h.run("run_tick", "run-tick", 0, "run", "tick")

	// Land (ticket 207). CI passes on #25, so a tick makes the run Ready. A
	// send-back takes it round the gate and Ship again, and the land merges
	// #25.
	passCI(t, h.ghState, 25, testutil.Git(t, tidy.Run.Folder, "rev-parse", "HEAD"))
	if _, errOut, code := h.raw("run", "tick"); code != 0 {
		t.Fatalf("run tick: exit %d: %s", code, errOut)
	}
	h.run("run_diff", "run-diff", 0, "run", "diff", tidy.Run.ID)
	h.run("run_send_back", "run-send-back", 0, "run", "send-back", tidy.Run.ID,
		"--note", "README.md:3: Say what a plot is.", "--note", "Keep the README short.")
	hook("Stop")
	if _, errOut, code := h.raw("run", "tick"); code != 0 {
		t.Fatalf("run tick: exit %d: %s", code, errOut)
	}
	h.run("run_land_dry_run", "run-land", 0, "run", "land", tidy.Run.ID, "--dry-run")
	h.run("run_land", "run-land", 0, "run", "land", tidy.Run.ID)
	h.run("error_run_land_not_ready", "error", 2, "run", "land", started.Run.ID)

	// Shape (ticket 207). The fake claude prints a draft for claude -p. A
	// redraft takes a change, and the approve starts the run with your edits.
	testutil.FakeClaudePrint(t, `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"goal": "The run page shows the plan of the run.",
  "checks": [{"name": "Go tests", "command": "go test ./..."}],
  "assumptions": ["The plan shows as a numbered list."],
  "plan": ["Read the plan from the run.", "Show it on the run page."],
  "size": "About 60 lines in the app."}}`)
	h.env = append(h.env, "LOAM_FAKE_CLAUDE_PRINT="+os.Getenv("LOAM_FAKE_CLAUDE_PRINT"))
	var shaped struct {
		Run struct{ ID string } `json:"run"`
	}
	parse(h.run("run_shape", "run-shape", 0, "run", "shape", "Runs", "--title", "Show the plan on the run page",
		"--ticket", filepath.Join(tickets, "12-run-page-plan.md")), &shaped)
	h.run("run_redraft", "run-shape", 0, "run", "redraft", shaped.Run.ID, "--change", "Add a check for a run with no plan")
	h.run("error_run_approve_no_assumption", "error", 2, "run", "approve", shaped.Run.ID, "--answer", "5=No")
	h.run("run_approve", "run-start", 0, "run", "approve", shaped.Run.ID,
		"--goal", "The run page shows the plan of the run, or says that it has none.", "--answer", "1=The plan shows as steps with checkboxes.")

	// Recurring runs and loam tick (ticket 208). Both are due daily at the
	// same time, so they list in the order that they were added. The chore's
	// precheck finds no work, and the Shape run has a draft that waits for you,
	// so the tick starts nothing. A fake launchctl stands in for launchd.
	h.run("recurring_add", "recurring", 0, "recurring", "add", "Runs", "--title", "Bump Go dependencies",
		"--prompt", "Bump the Go modules that have updates.", "--kind", "chore", "--days", "daily", "--at", "02:00",
		"--precheck", "false", "--check", "Go tests=go test ./...")
	var recurring struct {
		Recurring struct{ ID string } `json:"recurring"`
	}
	out, errOut, code = h.raw("recurring", "add", "Runs", "--title", "Shape new issues", "--prompt", "Shape a run for each new bug.",
		"--kind", "shape", "--days", "daily", "--at", "02:00", "--if-asleep", "skip", "--json")
	if code != 0 {
		t.Fatalf("recurring add: exit %d: %s", code, errOut)
	}
	parse([]byte(out), &recurring)
	h.run("recurring_run", "recurring-run", 0, "recurring", "run", recurring.Recurring.ID)
	h.run("recurring_list", "recurring-list", 0, "recurring", "list", "Runs")
	h.run("tick", "tick", 0, "tick", "--now", "2099-01-01T12:00:00Z")
	launchctl := filepath.Join(h.root, "launchctl")
	if err := os.WriteFile(launchctl, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h.env = append(h.env, "LOAM_LAUNCHCTL="+launchctl)
	h.run("tick_install", "tick-status", 0, "tick", "install")
	h.run("tick_status", "tick-status", 0, "tick", "status")
	h.run("tick_uninstall", "tick-status", 0, "tick", "uninstall")
	h.run("recurring_rm", "recurring", 0, "recurring", "rm", recurring.Recurring.ID)

	// Rules (ticket 209). A run fails its one try and stops. Its send-back
	// has a note like the note on the README run, so Loam offers a rule.
	out, errOut, code = h.raw("run", "start", "Runs", "--title", "Write the guide", "--check", "Guide=test -f GUIDE.md",
		"--max-tries", "1", "--json")
	if code != 0 {
		t.Fatalf("run start: exit %d: %s", code, errOut)
	}
	parse([]byte(out), &tidy)
	hook("SessionStart")
	hook("Stop")
	h.run("run_send_back_rule_offer", "run-send-back", 0, "run", "send-back", tidy.Run.ID, "--note", "Keep the README short, please.")
	var rule struct {
		Rule struct{ ID string } `json:"rule"`
	}
	parse(h.run("rule_add", "rule", 0, "rule", "add", "Runs", "--name", "Short README",
		"--command", "test $(wc -l < README.md) -lt 40", "--note", "Keep the README short, please."), &rule)
	h.token("rule", rule.Rule.ID)
	h.run("rule_list", "rule-list", 0, "rule", "list", "Runs")
	h.run("rule_rm", "rule", 0, "rule", "rm", rule.Rule.ID)
	h.run("error_rule_add_no_command", "error", 2, "rule", "add", "Runs", "--name", "Short README")

	// Run defaults: the model and effort of the runs of a plot.
	h.run("run_defaults_get", "run-defaults", 0, "run", "defaults", "Runs")
	h.run("run_defaults_set", "run-defaults", 0, "run", "defaults", "Runs", "--model", "opus", "--effort", "high")
	h.run("error_run_defaults_bad_effort", "error", 2, "run", "defaults", "Runs", "--effort", "extreme")
	h.run("run_defaults_clear", "run-defaults", 0, "run", "defaults", "Runs", "--model", "", "--effort", "")

	// Linked runs. A second repo joins the plot, and Claude splits one issue
	// into a run in each repo. The two runs share a group.
	docs, _ := testutil.GitRepoAt(t, filepath.Join(h.root, "docs.git"), filepath.Join(h.root, "repos", "docs"))
	cfg = fmt.Sprintf(`{"projects":{%q:{"hasTrustDialogAccepted":true},%q:{"hasTrustDialogAccepted":true},%q:{"hasTrustDialogAccepted":true}}}`,
		filepath.Join(h.home, "plots"), gitRepo, docs)
	if err := os.WriteFile(filepath.Join(h.root, "userhome", ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, errOut, code := h.raw("repo", "add", "Runs", docs); code != 0 {
		t.Fatalf("repo add: exit %d: %s", code, errOut)
	}
	out, errOut, code = h.raw("show", "Runs", "--json")
	if code != 0 {
		t.Fatalf("show: exit %d: %s", code, errOut)
	}
	var runsPlot struct {
		Repos []struct{ ID, Path string } `json:"repos"`
	}
	parse([]byte(out), &runsPlot)
	repoIDs := map[string]string{}
	for _, r := range runsPlot.Repos {
		repoIDs[r.Path] = r.ID
	}
	testutil.FakeClaudePrint(t, fmt.Sprintf(`{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"runs": [
  {"repo": %q, "goal": "The app names the setting Plan view.", "checks": [{"name": "Go tests", "command": "go test ./..."}],
   "assumptions": ["The docs can say the new name before the app ships it."], "plan": ["Rename the setting."], "size": "About 20 lines."},
  {"repo": %q, "goal": "The docs name the setting Plan view.", "checks": [{"name": "Docs", "command": "grep -q 'Plan view' README.md"}],
   "assumptions": [], "plan": ["Rename the setting in the README."], "size": "One line."}]}}`, repoIDs[gitRepo], repoIDs[docs]))
	h.env = append(h.env, "LOAM_FAKE_CLAUDE_PRINT="+os.Getenv("LOAM_FAKE_CLAUDE_PRINT"))
	var split struct {
		Runs []struct {
			ID      string `json:"id"`
			GroupID string `json:"group_id"`
		} `json:"runs"`
	}
	parse(h.run("run_shape_split", "run-shape", 0, "run", "shape", "Runs", "--title", "Rename the plan setting", "--split"), &split)
	if len(split.Runs) != 2 || split.Runs[0].GroupID != split.Runs[0].ID || split.Runs[1].GroupID != split.Runs[0].ID {
		t.Fatalf("split runs %+v", split.Runs)
	}
	h.run("error_run_shape_split_repo", "error", 2, "run", "shape", "Runs", "--title", "Rename the plan setting", "--split", "--repo", docs)
	return h
}

// runHead is the fixed stand-in for the commit of the run that the scenario
// lands.
const runHead = "1234512345123451234512345123451234512345"

// passCI gives the PR, at head, a passed check in the state of the fake gh,
// and makes it ready to merge.
func passCI(t *testing.T, stateFile string, number int, head string) {
	t.Helper()
	data, err := os.ReadFile(stateFile)
	if err != nil {
		t.Fatal(err)
	}
	var state map[string]any
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	for _, p := range state["pulls"].([]any) {
		if pull := p.(map[string]any); pull["number"] == float64(number) {
			pull["mergeable"], pull["mergeStateStatus"], pull["headRefOid"] = "MERGEABLE", "CLEAN", head
		}
	}
	var details map[string]any
	if err := json.Unmarshal([]byte(`{"baseRef": {"compare": {"behindBy": 0}}, "reviewThreads": {"nodes": []},
  "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"totalCount": 1, "nodes": [
    {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true}]}}}}]}}`), &details); err != nil {
		t.Fatal(err)
	}
	state["details"].(map[string]any)[strconv.Itoa(number)] = details
	if data, err = json.Marshal(state); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stateFile, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

type changeRec struct {
	ID      int64 `json:"id"`
	Entries []struct {
		Item string `json:"item"`
	} `json:"entries"`
}

// changeLog returns the changes of a plot, oldest first.
func changeLog(t *testing.T, h *harness, plot string) []changeRec {
	t.Helper()
	out, _, code := h.raw("changes", plot, "--json")
	if code != 0 {
		t.Fatalf("changes: exit %d", code)
	}
	var v struct {
		Changes []changeRec `json:"changes"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatal(err)
	}
	return v.Changes
}

// firstChangeOf returns the ID of the first change after the plot was made
// that touched an item with the prefix.
func firstChangeOf(t *testing.T, h *harness, plot, prefix string) int64 {
	t.Helper()
	for _, c := range changeLog(t, h, plot)[1:] {
		for _, e := range c.Entries {
			if strings.HasPrefix(e.Item, prefix) {
				return c.ID
			}
		}
	}
	t.Fatalf("no change of %q", prefix)
	return 0
}

// lastChangeOf returns the ID of the last change that touched an item with the prefix.
func lastChangeOf(t *testing.T, h *harness, plot, prefix string) int64 {
	t.Helper()
	var id int64
	for _, c := range changeLog(t, h, plot) {
		for _, e := range c.Entries {
			if strings.HasPrefix(e.Item, prefix) {
				id = c.ID
			}
		}
	}
	if id == 0 {
		t.Fatalf("no change of %q", prefix)
	}
	return id
}

// claudeProjectName is how Claude Code names the projects folder of a start
// folder: every character that is not an ASCII letter or digit becomes "-".
// A macOS temp folder has "_" in it, so replacing only "/" and "." is not enough.
func claudeProjectName(start string) string {
	return regexp.MustCompile(`[^A-Za-z0-9]`).ReplaceAllString(start, "-")
}
