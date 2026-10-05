package session

import "net"

// SetPaneDial replaces the pane socket dialer. It returns the undo.
func SetPaneDial(f func(string) (net.Conn, error)) func() {
	old := paneDial
	paneDial = f
	return func() { paneDial = old }
}
