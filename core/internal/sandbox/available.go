package sandbox

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// execEnv names the sandbox-exec binary, for tests. The default is the one
// that macOS ships.
const execEnv = "LOAM_SANDBOX_EXEC"

// Exec returns the path of sandbox-exec.
func Exec() string {
	if p := os.Getenv(execEnv); p != "" {
		return p
	}
	return "/usr/bin/sandbox-exec"
}

// Available returns nil when sandbox-exec runs a command under a profile.
// Claude Code builds its Bash sandbox on the same Seatbelt, and the gate runs
// the checks with it.
func Available() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, Exec(), "-p", "(version 1)(allow default)", "/usr/bin/true").CombinedOutput()
	if err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "" {
			return fmt.Errorf("%s does not run: %s", Exec(), msg)
		}
		return fmt.Errorf("%s does not run: %v", Exec(), err)
	}
	return nil
}
