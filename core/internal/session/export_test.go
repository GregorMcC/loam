package session

import "net"

// RunToolRules is [runToolRules].
var RunToolRules = runToolRules

// SetPaneDial replaces the pane socket dialer. It returns the undo.
func SetPaneDial(f func(string) (net.Conn, error)) func() {
	old := paneDial
	paneDial = f
	return func() { paneDial = old }
}

// SetRunTemps replaces the temporary folders that a run can write. It returns
// the undo.
func SetRunTemps(f func() []string) func() {
	old := runTemps
	runTemps = f
	return func() { runTemps = old }
}
