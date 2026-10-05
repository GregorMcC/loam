package cli_test

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestVersionFlag(t *testing.T) {
	bin := testutil.BuildLoam(t)
	out, err := exec.Command(bin, "--version").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if !strings.Contains(string(out), "loam version") {
		t.Fatalf("output %q", out)
	}
}

func TestGlobalJSONFlagIsAccepted(t *testing.T) {
	bin := testutil.BuildLoam(t)
	out, err := exec.Command(bin, "--json", "--help").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if !strings.Contains(string(out), "--json") {
		t.Fatalf("help does not list --json: %s", out)
	}
}

func TestUnknownCommandFails(t *testing.T) {
	bin := testutil.BuildLoam(t)
	if err := exec.Command(bin, "nosuchcommand").Run(); err == nil {
		t.Fatal("want a non-zero exit")
	}
}
