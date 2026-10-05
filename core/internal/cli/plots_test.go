package cli_test

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

type env struct {
	t    *testing.T
	bin  string
	home string
	edit string // fake editor folder
}

func newEnv(t *testing.T) *env {
	t.Helper()
	home := testutil.Home(t)
	return &env{t: t, bin: testutil.BuildLoam(t), home: home}
}

// run runs loam and returns stdout, stderr, and the error.
func (e *env) run(stdin string, args ...string) (string, string, error) {
	e.t.Helper()
	cmd := exec.Command(e.bin, args...)
	cmd.Env = append(os.Environ(), "LOAM_HOME="+e.home)
	if e.edit != "" {
		cmd.Env = append(cmd.Env, "VISUAL="+filepath.Join(e.edit, "ed.sh"), "FAKE_EDIT_DIR="+e.edit)
	}
	cmd.Stdin = strings.NewReader(stdin)
	var o, er bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &er
	err := cmd.Run()
	return o.String(), er.String(), err
}

func (e *env) ok(stdin string, args ...string) string {
	e.t.Helper()
	o, er, err := e.run(stdin, args...)
	if err != nil {
		e.t.Fatalf("loam %v: %v\nstderr: %s", args, err, er)
	}
	return o
}

// fakeEditor installs a scripted editor. Call n of the editor runs pre.<n>
// (a shell script) if it exists, saves the file it was given as seen.<n>,
// then replaces the file with body.<n> if that exists.
func (e *env) fakeEditor() {
	e.t.Helper()
	e.edit = e.t.TempDir()
	script := `#!/bin/sh
d="$FAKE_EDIT_DIR"
n=$(($(cat "$d/count" 2>/dev/null || echo 0) + 1))
echo $n > "$d/count"
[ -f "$d/pre.$n" ] && sh "$d/pre.$n"
cp "$1" "$d/seen.$n"
[ -f "$d/body.$n" ] && cp "$d/body.$n" "$1"
exit 0
`
	e.writeEdit("ed.sh", script)
	if err := os.Chmod(filepath.Join(e.edit, "ed.sh"), 0o755); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) writeEdit(name, text string) {
	e.t.Helper()
	if err := os.WriteFile(filepath.Join(e.edit, name), []byte(text), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) seen(n string) string {
	e.t.Helper()
	b, err := os.ReadFile(filepath.Join(e.edit, "seen."+n))
	if err != nil {
		e.t.Fatalf("the editor did not run %s times: %v", n, err)
	}
	return string(b)
}

func (e *env) newPlot(name string) store.Plot {
	e.t.Helper()
	var p store.Plot
	if err := json.Unmarshal([]byte(e.ok("", "new", name, "--json")), &p); err != nil {
		e.t.Fatal(err)
	}
	return p
}

func (e *env) show(id string) store.Plot {
	e.t.Helper()
	var p store.Plot
	if err := json.Unmarshal([]byte(e.ok("", "show", id, "--json")), &p); err != nil {
		e.t.Fatal(err)
	}
	return p
}

func TestNewJSONSkipsEditorAndWritesSeed(t *testing.T) {
	e := newEnv(t)
	e.fakeEditor()
	p := e.newPlot("Billing")
	if p.Name != "Billing" || len(p.ID) != 10 {
		t.Fatalf("plot %+v", p)
	}
	if _, err := os.Stat(filepath.Join(e.edit, "count")); err == nil {
		t.Fatal("the editor ran with --json")
	}
	st, err := store.Open(e.home)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := os.Stat(seed.Path(st, p.ID)); err != nil {
		t.Fatalf("no seed: %v", err)
	}
}

func TestNewOpensBriefInEditor(t *testing.T) {
	e := newEnv(t)
	e.fakeEditor()
	e.writeEdit("body.1", "# What\nShip invoices.\n\n# Why\nTax law.\n\n# Where it stands\nStarted.\n")
	e.ok("", "new", "Invoices")
	if !strings.Contains(e.seen("1"), "# What") {
		t.Fatalf("template %q", e.seen("1"))
	}
	p := e.show("Invoices")
	if p.What != "Ship invoices." || p.Why != "Tax law." || p.Where != "Started." {
		t.Fatalf("plot %+v", p)
	}
	st, _ := store.Open(e.home)
	defer st.Close()
	b, err := os.ReadFile(seed.Path(st, p.ID))
	if err != nil || !strings.Contains(string(b), "Ship invoices.") {
		t.Fatalf("seed lacks the brief: %v %s", err, b)
	}
	ch, _ := st.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(ch) != 1 || ch[0].Actor.Kind != store.ActorCLI {
		t.Fatalf("changes %+v", ch)
	}
}

func TestListInOrderAndJSON(t *testing.T) {
	e := newEnv(t)
	e.newPlot("Zeta")
	e.newPlot("Alpha")
	out := e.ok("", "list")
	if strings.Index(out, "Zeta") > strings.Index(out, "Alpha") || !strings.Contains(out, "Alpha") {
		t.Fatalf("order: %s", out)
	}
	var rows []store.PlotSummary
	if err := json.Unmarshal([]byte(e.ok("", "list", "--json")), &rows); err != nil || len(rows) != 2 || rows[0].Name != "Zeta" {
		t.Fatalf("json: %v %+v", err, rows)
	}
	empty := newEnv(t)
	if got := empty.ok("", "list", "--json"); strings.TrimSpace(got) != "[]" {
		t.Fatalf("empty list json %q", got)
	}
}

func TestShowHumanAndJSON(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("Billing")
	e.ok("some text", "set", p.ID, "what", "-")
	out := e.ok("", "show", "Bill")
	for _, want := range []string{"Billing", p.ID, "some text"} {
		if !strings.Contains(out, want) {
			t.Fatalf("show lacks %q: %s", want, out)
		}
	}
	got := e.show(p.ID)
	if got.What != "some text" || got.Versions["what"] <= got.Versions["why"] {
		t.Fatalf("versions %+v", got.Versions)
	}
}

func TestSetFieldsAndStdin(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("Billing")
	e.ok("", "set", p.ID, "why", "Because")
	e.ok("line one\nline two\n", "set", p.ID, "where-it-stands", "-")
	e.ok("", "set", p.ID, "name", "Billing 2")
	got := e.show(p.ID)
	if got.Why != "Because" || got.Where != "line one\nline two" || got.Name != "Billing 2" {
		t.Fatalf("plot %+v", got)
	}
	if _, er, err := e.run("", "set", p.ID, "colour", "red"); err == nil || !strings.Contains(er, "colour") {
		t.Fatalf("bad field: %v %s", err, er)
	}
}

func TestSetStaleExpect(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("Billing")
	old := p.Versions["what"]
	e.ok("", "set", p.ID, "what", "first")
	_, er, err := e.run("", "set", p.ID, "what", "second", "--expect", "what="+itoa(old))
	if err == nil || !strings.Contains(er, "stale") || !strings.Contains(er, "first") {
		t.Fatalf("want a stale error with the current text: %v %s", err, er)
	}
	if got := e.show(p.ID); got.What != "first" {
		t.Fatalf("stale write changed the plot: %+v", got)
	}
	cur := e.show(p.ID).Versions["what"]
	e.ok("", "set", p.ID, "what", "third", "--expect", "what="+itoa(cur))
	if got := e.show(p.ID); got.What != "third" {
		t.Fatalf("plot %+v", got)
	}
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func TestResolvePrefixAmbiguousAndUnknown(t *testing.T) {
	e := newEnv(t)
	e.newPlot("Billing")
	e.newPlot("Billboard")
	e.newPlot("Search")
	if out := e.ok("", "show", "sea"); !strings.Contains(out, "Search") {
		t.Fatalf("prefix: %s", out)
	}
	if _, er, err := e.run("", "show", "bill"); err == nil || !strings.Contains(er, "Billing") || !strings.Contains(er, "Billboard") {
		t.Fatalf("ambiguous: %v %s", err, er)
	}
	if _, er, err := e.run("", "show", "nothing"); err == nil || !strings.Contains(er, "nothing") {
		t.Fatalf("unknown: %v %s", err, er)
	}
}

func TestLongBriefWarns(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("Billing")
	_, er, err := e.run(strings.Repeat("word ", 301), "set", p.ID, "what", "-")
	if err != nil || !strings.Contains(er, "warning") {
		t.Fatalf("want a warning: %v %s", err, er)
	}
}

func TestEditChangesNameAndBrief(t *testing.T) {
	e := newEnv(t)
	e.fakeEditor()
	p := e.newPlot("Billing")
	e.writeEdit("body.1", "# Name\nInvoicing\n\n# What\nNew what\n\n# Why\n\n# Where it stands\nHere\n")
	e.ok("", "edit", "Billing")
	if !strings.Contains(e.seen("1"), "Billing") {
		t.Fatalf("editor text %q", e.seen("1"))
	}
	got := e.show(p.ID)
	if got.Name != "Invoicing" || got.What != "New what" || got.Where != "Here" || got.Why != "" {
		t.Fatalf("plot %+v", got)
	}
	st, _ := store.Open(e.home)
	defer st.Close()
	ch, _ := st.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(ch) != 2 || ch[1].Actor.Kind != store.ActorCLI {
		t.Fatalf("an edit must make one change: %+v", ch)
	}
}

func TestEditStaleSaveReopensWithCurrentText(t *testing.T) {
	e := newEnv(t)
	e.fakeEditor()
	p := e.newPlot("Billing")
	e.ok("", "set", p.ID, "what", "original")
	// During the first editor run, someone else changes "what".
	e.writeEdit("pre.1", "'"+e.bin+"' set '"+p.ID+"' what 'changed elsewhere'\n")
	e.writeEdit("body.1", "# Name\nBilling\n\n# What\nmy edit\n\n# Why\n\n# Where it stands\n\n")
	e.writeEdit("body.2", "# Name\nBilling\n\n# What\nmerged\n\n# Why\n\n# Where it stands\n\n")
	e.ok("", "edit", p.ID)
	if !strings.Contains(e.seen("2"), "changed elsewhere") {
		t.Fatalf("second run must show the current text: %q", e.seen("2"))
	}
	if got := e.show(p.ID); got.What != "merged" {
		t.Fatalf("plot %+v", got)
	}
}

func TestEditNoChange(t *testing.T) {
	e := newEnv(t)
	e.fakeEditor()
	p := e.newPlot("Billing")
	e.ok("", "edit", p.ID)
	st, _ := store.Open(e.home)
	defer st.Close()
	ch, _ := st.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(ch) != 1 {
		t.Fatalf("an unchanged save must write nothing: %+v", ch)
	}
}
