package session

import (
	"encoding/json"
	"net"
	"slices"
	"time"
)

// paneEvents is the table of hook events that a session settings file
// registers and that `loam hook` forwards to the pane socket. To forward one
// more event, add its name here and to contract/schema/pane-event.json.
var paneEvents = []string{"SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
	"PermissionRequest", "Notification", "PostToolUse", "StopFailure"}

// attentionNotifications are the notification types that raise an alert. Other
// types, such as idle_prompt, raise nothing. permission_prompt raises one for
// the dialogs that send no PermissionRequest hook. SubagentStop is not in the event
// table, so a subagent stop raises nothing either.
var attentionNotifications = []string{"elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "permission_prompt"}

// PaneEvents returns the names in the event table.
func PaneEvents() []string { return slices.Clone(paneEvents) }

// paneTimeout limits the connect and, separately, the write to the pane
// socket. A hook must not hold up the session.
const paneTimeout = 200 * time.Millisecond

// paneDial connects to the pane socket. Tests replace it.
var paneDial = func(path string) (net.Conn, error) { return net.DialTimeout("unix", path, paneTimeout) }

// PaneLine is the JSON line that loam hook sends to the pane socket. See
// "Pane socket" in docs/contract.md.
type PaneLine struct {
	Event     string `json:"event"`
	SessionID string `json:"session_id"`
	Cwd       string `json:"cwd"`
	// Source is the source of a SessionStart.
	Source string `json:"source,omitempty"`
	// NotificationType is the type of a Notification.
	NotificationType string `json:"notification_type,omitempty"`
	At               string `json:"at"`
}

// paneLine returns the line to send for a hook call, and false when the event
// is not in the table, or is a Notification of a type that raises nothing.
func paneLine(h hookInput, now time.Time) (PaneLine, bool) {
	if !slices.Contains(paneEvents, h.Event) {
		return PaneLine{}, false
	}
	if h.Event == "Notification" && !slices.Contains(attentionNotifications, h.NotificationType) {
		return PaneLine{}, false
	}
	l := PaneLine{Event: h.Event, SessionID: h.SessionID, Cwd: h.Cwd, At: now.UTC().Format(time.RFC3339)}
	if h.Event == "SessionStart" {
		l.Source = h.Source
	}
	if h.Event == "Notification" {
		l.NotificationType = h.NotificationType
	}
	return l, true
}

// sendPane sends the line for a hook call to the Unix socket in
// LOAM_PANE_SOCKET. No variable means no send. It waits at most paneTimeout
// to connect and paneTimeout to write, and logs each error.
func sendPane(h hookInput, getenv func(string) string, logf func(string, ...any)) {
	path := getenv("LOAM_PANE_SOCKET")
	if path == "" {
		return
	}
	line, ok := paneLine(h, time.Now())
	if !ok {
		return
	}
	b, err := json.Marshal(line)
	if err != nil {
		logf("pane line: %v", err)
		return
	}
	conn, err := paneDial(path)
	if err != nil {
		logf("pane socket %s: %v", path, err)
		return
	}
	defer conn.Close()
	if err := conn.SetWriteDeadline(time.Now().Add(paneTimeout)); err != nil {
		logf("pane socket %s: %v", path, err)
		return
	}
	if _, err := conn.Write(append(b, '\n')); err != nil {
		logf("pane socket %s: write: %v", path, err)
	}
}
