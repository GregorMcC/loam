package cli

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-175: the paths and hosts that the user adds to the sandbox of a run.

func sandboxOut(t *testing.T, args ...string) store.SandboxSettings {
	t.Helper()
	out, code := loam(t, append([]string{"run", "sandbox"}, append(args, "--json")...)...)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got struct {
		Sandbox store.SandboxSettings `json:"sandbox"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Sandbox
}

func TestRunSandboxShowsSetsAndClearsTheSettingsOfAPlot(t *testing.T) {
	s, p := runCLI(t)
	if d := sandboxOut(t, "alpha"); !reflect.DeepEqual(d, store.SandboxSettings{PlotID: p.ID, Read: []string{}, Write: []string{}, Hosts: []string{}}) {
		t.Fatalf("a new plot %+v", d)
	}
	want := store.SandboxSettings{PlotID: p.ID, Read: []string{"~/notes", "/opt/specs"}, Write: []string{"~/out"}, Hosts: []string{"registry.example.com", "*.example.org"}}
	got := sandboxOut(t, "alpha", "--read", "~/notes", "--read", "/opt/specs", "--write", "~/out", "--host", "Registry.Example.com", "--host", "*.example.org")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("set %+v", got)
	}
	// A flag sets the whole list of its kind and leaves the others.
	got = sandboxOut(t, "alpha", "--read", "~/other")
	if !reflect.DeepEqual(got.Read, []string{"~/other"}) || !reflect.DeepEqual(got.Write, want.Write) || !reflect.DeepEqual(got.Hosts, want.Hosts) {
		t.Fatalf("set one list %+v", got)
	}
	// An empty value empties the list.
	got = sandboxOut(t, "alpha", "--host", "")
	if got.Hosts == nil || len(got.Hosts) != 0 || len(got.Read) != 1 {
		t.Fatalf("clear %+v", got)
	}
	if d, err := s.GetSandboxSettings(p.ID); err != nil || !reflect.DeepEqual(d, got) {
		t.Fatalf("stored %+v %v", d, err)
	}
	out, code := loam(t, "run", "sandbox", "alpha")
	if code != 0 || !strings.Contains(out, "read paths: ~/other\nwrite paths: ~/out\nhosts: (none)\n") {
		t.Fatalf("text %q exit %d", out, code)
	}
}

func TestRunSandboxWithNoPlotSetsTheMachineScope(t *testing.T) {
	_, p := runCLI(t)
	machine := sandboxOut(t, "--read", "~/.nvm", "--host", "registry.example.com")
	if machine.PlotID != "" || !reflect.DeepEqual(machine.Read, []string{"~/.nvm"}) {
		t.Fatalf("machine %+v", machine)
	}
	if d := sandboxOut(t, "alpha"); d.PlotID != p.ID || len(d.Read) != 0 || len(d.Hosts) != 0 {
		t.Fatalf("the plot scope %+v", d)
	}
	if d := sandboxOut(t); !reflect.DeepEqual(d, machine) {
		t.Fatalf("show %+v", d)
	}
}

func TestRunSandboxRefusesWhatOpensHomeWithExit2(t *testing.T) {
	runCLI(t)
	for _, args := range [][]string{
		{"--read", "~"}, {"--write", "/"}, {"--read", "~/.ssh"}, {"--read", "relative"}, {"alpha", "--host", "*"},
		{"alpha", "--host", "https://example.com"}, {"--read", "~/ok", "--read", "~/.aws/x"},
	} {
		out, code := loam(t, append([]string{"run", "sandbox"}, args...)...)
		if code != 2 || out == "" {
			t.Errorf("%v: exit %d: %q", args, code, out)
		}
	}
	if d := sandboxOut(t); len(d.Read)+len(d.Write)+len(d.Hosts) != 0 {
		t.Fatalf("stored %+v", d)
	}
	if _, code := loam(t, "run", "sandbox", "nosuchplot"); code == 0 {
		t.Fatal("an unknown plot exited 0")
	}
}
