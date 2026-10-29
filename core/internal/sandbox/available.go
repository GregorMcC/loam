package sandbox

import (
	"fmt"
	"os"
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

// Available returns nil when sandbox-exec is an executable file. Claude Code
// builds its Bash sandbox on the same Seatbelt, and the gate runs the checks
// with it. It does not run sandbox-exec: that fails inside a sandbox, as in
// the Bash of a run that works on Loam. A sandbox that fails to start stops
// the session, because the run settings set failIfUnavailable.
func Available() error {
	info, err := os.Stat(Exec())
	switch {
	case err != nil:
		return fmt.Errorf("%s is missing: %v", Exec(), err)
	case info.IsDir() || info.Mode()&0o111 == 0:
		return fmt.Errorf("%s is not an executable file", Exec())
	}
	return nil
}
