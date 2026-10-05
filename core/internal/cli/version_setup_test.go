package cli_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestVersionCommand(t *testing.T) {
	bin := testutil.BuildLoam(t)
	out, err := exec.Command(bin, "version").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if !strings.HasPrefix(string(out), "loam version ") {
		t.Fatalf("output %q", out)
	}
}

func TestSetupCommandUsesFakeClaude(t *testing.T) {
	home := testutil.Home(t)
	testutil.FakeClaude(t)
	t.Setenv("HOME", t.TempDir())
	bin := testutil.BuildLoam(t)
	out, err := exec.Command(bin, "setup", "--yes").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	want, _ := filepath.EvalSymlinks(filepath.Join(home, "plots"))
	if inv.Cwd != want && inv.Cwd != filepath.Join(home, "plots") {
		t.Errorf("last claude run in %s", inv.Cwd)
	}
	if !strings.Contains(string(out), "mcp__loam__get_plot") {
		t.Errorf("no allow rules:\n%s", out)
	}
}
