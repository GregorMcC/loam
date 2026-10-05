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
	tokens  map[string]string
	counts  map[string]int
	entries []Entry
	outputs map[string][]byte // normalized output by fixture name
}

var timeRE = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)`)

const fixedTime = "2026-01-01T00:00:00Z"

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
}

// normalize replaces IDs, times, and temp paths with fixed values.
func (h *harness) normalize(s string) string {
	reals := make([]string, 0, len(h.tokens))
	for real := range h.tokens {
		reals = append(reals, real)
	}
	sort.Strings(reals) // map order is random: keep the replacer deterministic
	// Claude Code names a folder after a path with "/" and "." changed to "-".
	// The temp root is in such a name too.
	dashed := strings.NewReplacer("/", "-", ".", "-")
	pairs := []string{dashed.Replace(h.root), "-tmp-loam-contract"}
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
	h.pane("pane_stop", "pane-event", hookIn("Stop", ""))
	h.pane("pane_notification", "pane-event", hookIn("Notification", `,"notification_type":"agent_needs_input"`))

	h.pane("pane_notification_permission", "pane-event", hookIn("Notification", `,"notification_type":"permission_prompt"`))

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
	gitRepo, _ := testutil.GitRepoAt(t, filepath.Join(h.root, "remote.git"), filepath.Join(h.root, "repos", "web"))
	if err := os.WriteFile(filepath.Join(gitRepo, ".env"), []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitRepo, ".git", "info", "exclude"), []byte(".env\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	parse(h.run("repo_add_git", "repo-add", 0, "repo", "add", loam, gitRepo, "--setup", "make setup", "--copy", ".env"), &c)
	h.run("repo_edit_setup", "repo-edit", 0, "repo", "edit", loam, c.Repo.ID, "--setup", "npm ci")
	h.run("worktree_new", "worktree-new", 0, "worktree", "new", loam, gitRepo, "fix-login")
	h.run("worktree_list", "worktree-list", 0, "worktree", "list", loam)
	h.run("worktree_rm", "worktree-rm", 0, "worktree", "rm", loam, "fix-login")
	h.run("worktree_list_empty", "worktree-list", 0, "worktree", "list", loam)

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
	return h
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
