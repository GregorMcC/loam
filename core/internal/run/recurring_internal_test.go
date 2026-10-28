package run

import (
	"context"
	"os"
	"strings"
	"testing"
)

// A precheck that cannot run its command is broken, and says so: it did not
// find "no work".
func TestPrecheckThatCannotRunItsCommandSaysSo(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct{ command, want string }{
		{"exit 1", "found no work (exit 1)"},
		{"loam-no-such-command", "could not run its command (exit 127)"},
		{"./not-executable", "could not run its command (exit 126)"},
	} {
		if tc.command == "./not-executable" {
			if err := os.WriteFile(dir+"/not-executable", []byte("echo hi\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		_, skip := precheck(context.Background(), tc.command, dir)
		if !strings.Contains(skip, tc.want) {
			t.Errorf("%s: skip %q, want %q", tc.command, skip, tc.want)
		}
	}
	if _, skip := precheck(context.Background(), "loam-no-such-command", dir); !strings.Contains(skip, "not found") {
		t.Errorf("the skip does not say what the shell said: %q", skip)
	}
}
