package cli_test

import (
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// jsonError is the error shape on stdout in --json mode.
type jsonError struct {
	Error struct {
		Kind     string          `json:"kind"`
		ExitCode int             `json:"exit_code"`
		Message  string          `json:"message"`
		Details  json.RawMessage `json:"details"`
	} `json:"error"`
}

// fail runs loam, expects a failure, and returns the exit code, stdout, and stderr.
func (e *env) fail(args ...string) (int, string, string) {
	e.t.Helper()
	o, er, err := e.run("", args...)
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		e.t.Fatalf("loam %v: want an exit error, got %v\nstdout: %s", args, err, o)
	}
	return ee.ExitCode(), o, er
}

func (e *env) failJSON(want int, kind string, args ...string) jsonError {
	e.t.Helper()
	code, o, er := e.fail(append(args, "--json")...)
	if code != want {
		e.t.Fatalf("loam %v: exit %d, want %d\n%s%s", args, code, want, o, er)
	}
	if er != "" {
		e.t.Errorf("stderr is not empty in --json mode: %q", er)
	}
	var je jsonError
	if err := json.Unmarshal([]byte(o), &je); err != nil {
		e.t.Fatalf("stdout is not one JSON error: %v\n%s", err, o)
	}
	if je.Error.Kind != kind || je.Error.ExitCode != want || je.Error.Message == "" {
		e.t.Fatalf("error %+v, want kind %s code %d", je.Error, kind, want)
	}
	return je
}

func TestExitStaleWithCurrentValues(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	e.ok("", "set", p.ID, "what", "first")
	stale := e.show(p.ID).Versions["what"] - 1
	e.ok("", "set", p.ID, "what", "second")
	je := e.failJSON(10, "stale", "set", p.ID, "what", "third", "--expect", "what="+itoa(stale))
	var d store.StaleError
	if err := json.Unmarshal(je.Error.Details, &d); err != nil {
		t.Fatal(err)
	}
	if d.PlotID != p.ID || len(d.Items) != 1 || d.Items[0].Item != "what" || d.Items[0].Value != "second" {
		t.Fatalf("details %+v", d)
	}
	// Without --json, the same error exits 10 with a line on stderr.
	code, o, er := e.fail("set", p.ID, "what", "third", "--expect", "what="+itoa(stale))
	if code != 10 || o != "" || !strings.Contains(er, "stale") {
		t.Fatalf("exit %d, stdout %q, stderr %q", code, o, er)
	}
}

func TestExitUnknownPlot(t *testing.T) {
	e := newEnv(t)
	e.failJSON(14, "unknown_plot", "show", "nosuchplot")
	e.failJSON(14, "unknown_plot", "set", "nosuchplot", "what", "x")
}

func TestExitAmbiguousPlot(t *testing.T) {
	e := newEnv(t)
	e.newPlot("alpha one")
	e.newPlot("alpha two")
	e.failJSON(15, "ambiguous", "show", "alpha")
}

func TestExitInvalid(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	e.failJSON(2, "invalid", "set", p.ID, "colour", "x")
	e.failJSON(2, "invalid", "set", p.ID, "what", "x", "--expect", "nonsense")
	e.failJSON(2, "invalid", "show")                // wrong argument count
	e.failJSON(2, "invalid", "show", p.ID, "--bad") // unknown flag
	e.failJSON(2, "invalid", "nosuchcommand")
	e.failJSON(2, "invalid", "set", p.ID, "what", "x", "--actor", "nobody")
	if code, _, _ := e.fail("show"); code != 2 {
		t.Errorf("exit %d without --json", code)
	}
}

func TestExitGeneralError(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	e.failJSON(1, "error", "link", "rm", p.ID, "nolink")
}

func TestActorAppIsRecorded(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	e.ok("", "set", p.ID, "what", "from the cli")
	e.ok("", "--actor", "app", "set", p.ID, "what", "from the app")
	e.ok("", "link", "add", p.ID, "docs", "https://example.com", "--actor", "app")
	s, err := store.Open(e.home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if err != nil {
		t.Fatal(err)
	}
	// create, set (cli), set (app), link add (app)
	want := []store.ActorKind{store.ActorCLI, store.ActorCLI, store.ActorApp, store.ActorApp}
	if len(got) != len(want) {
		t.Fatalf("%d changes", len(got))
	}
	for i, c := range got {
		if c.Actor.Kind != want[i] {
			t.Errorf("change %d: actor %s, want %s", c.ID, c.Actor.Kind, want[i])
		}
	}
}

func TestVersionJSON(t *testing.T) {
	e := newEnv(t)
	var v struct {
		Version         string `json:"version"`
		ContractVersion int    `json:"contract_version"`
	}
	if err := json.Unmarshal([]byte(e.ok("", "version", "--json")), &v); err != nil {
		t.Fatal(err)
	}
	if v.Version == "" || v.ContractVersion != 1 {
		t.Fatalf("%+v", v)
	}
}

func TestListJSONIsAnArrayWhenEmpty(t *testing.T) {
	e := newEnv(t)
	if got := strings.TrimSpace(e.ok("", "list", "--json")); got != "[]" {
		t.Fatalf("%q", got)
	}
}
