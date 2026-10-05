package session_test

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// socketPath returns a short socket path. Unix socket paths are short on macOS.
func socketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "lp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s")
}

// listen starts a pane socket. Each line that arrives goes to the channel.
func listen(t *testing.T) (string, <-chan string) {
	t.Helper()
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	lines := make(chan string, 16)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				sc := bufio.NewScanner(c)
				for sc.Scan() {
					lines <- sc.Text()
				}
			}()
		}
	}()
	return path, lines
}

func nextLine(t *testing.T, lines <-chan string) string {
	t.Helper()
	select {
	case l := <-lines:
		return l
	case <-time.After(3 * time.Second):
		t.Fatal("no line on the pane socket")
		return ""
	}
}

func noLine(t *testing.T, lines <-chan string) {
	t.Helper()
	select {
	case l := <-lines:
		t.Fatalf("unexpected line %q", l)
	case <-time.After(100 * time.Millisecond):
	}
}

func hookLog(t *testing.T, home string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(home, "hook.log"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func hookJSON(event, extra string) string {
	return `{"session_id":"s1","cwd":"/work/here","hook_event_name":"` + event + `"` + extra + `}`
}

func TestPaneNoSocketSendsAndLogsNothing(t *testing.T) {
	e := setup(t)
	for _, ev := range session.PaneEvents() {
		if out := runHook(t, hookJSON(ev, `,"source":"startup"`), map[string]string{}); out != "" {
			t.Errorf("%s: output %q", ev, out)
		}
	}
	if log := hookLog(t, e.home); log != "" {
		t.Errorf("hook.log %q", log)
	}
}

func TestPaneDeadSocketLogsAndKeepsSessionStartWork(t *testing.T) {
	e := setup(t)
	// A stale socket file: the listener is gone, the file stays.
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	l.Close()
	for name, p := range map[string]string{"stale file": path, "missing file": path + "-none"} {
		start := time.Now()
		runHook(t, hookJSON("SessionStart", `,"source":"startup"`), map[string]string{"LOAM_PANE_SOCKET": p, "CLAUDE_PID": "4242"})
		if d := time.Since(start); d > time.Second {
			t.Errorf("%s: the hook took %v", name, d)
		}
		if !strings.Contains(hookLog(t, e.home), "pane socket "+p) {
			t.Errorf("%s: hook.log %q", name, hookLog(t, e.home))
		}
	}
	if id, ok, _ := e.store.SessionForPID(4242); !ok || id != "s1" {
		t.Errorf("pid record %q %v", id, ok)
	}
}

// A listener with a backlog of zero that never accepts: when its queue is
// full, a new connect does not finish (Linux) or is refused (macOS). Either
// way the hook must end fast and log the error.
func TestPaneSlowListenerTimesOut(t *testing.T) {
	e := setup(t)
	path := socketPath(t)
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Close(fd) })
	if err := syscall.Bind(fd, &syscall.SockaddrUnix{Name: path}); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Listen(fd, 0); err != nil {
		t.Fatal(err)
	}
	// Fill the queue. Linux queues 1 connection. macOS queues about 128, so
	// dial until a connect fails or times out.
	for i := 0; i < 1024; i++ {
		c, err := net.DialTimeout("unix", path, 50*time.Millisecond)
		if err != nil {
			break
		}
		t.Cleanup(func() { c.Close() })
	}
	start := time.Now()
	runHook(t, hookJSON("Stop", ""), map[string]string{"LOAM_PANE_SOCKET": path})
	if d := time.Since(start); d > time.Second {
		t.Errorf("the hook took %v", d)
	}
	if !strings.Contains(hookLog(t, e.home), "pane socket") {
		t.Errorf("hook.log %q", hookLog(t, e.home))
	}
}

// A listener that takes the connection and never reads: the write blocks, and
// the write timeout ends it. A pipe stands in for the socket, because a real
// socket buffer is larger than one line.
func TestPaneWriteTimesOut(t *testing.T) {
	e := setup(t)
	server, client := net.Pipe()
	t.Cleanup(func() { server.Close(); client.Close() })
	defer session.SetPaneDial(func(string) (net.Conn, error) { return client, nil })()
	start := time.Now()
	runHook(t, hookJSON("Stop", ""), map[string]string{"LOAM_PANE_SOCKET": "/unused"})
	if d := time.Since(start); d < 100*time.Millisecond || d > time.Second {
		t.Errorf("the hook took %v", d)
	}
	if log := hookLog(t, e.home); !strings.Contains(log, "write") || !strings.Contains(log, "timeout") {
		t.Errorf("hook.log %q", log)
	}
}

func TestPaneLiveListenerGetsEachEvent(t *testing.T) {
	setup(t)
	path, lines := listen(t)
	env := map[string]string{"LOAM_PANE_SOCKET": path}
	for _, ev := range session.PaneEvents() {
		before := time.Now().Add(-time.Second)
		runHook(t, hookJSON(ev, `,"source":"startup","notification_type":"agent_needs_input","prompt":"secret"`), env)
		raw := nextLine(t, lines)
		var got map[string]any
		if err := json.Unmarshal([]byte(raw), &got); err != nil {
			t.Fatalf("%s: line %q: %v", ev, raw, err)
		}
		if got["event"] != ev || got["session_id"] != "s1" || got["cwd"] != "/work/here" {
			t.Errorf("%s: line %q", ev, raw)
		}
		if _, has := got["source"]; has != (ev == "SessionStart") {
			t.Errorf("%s: source in line %q", ev, raw)
		}
		if nt, has := got["notification_type"]; has != (ev == "Notification") || has && nt != "agent_needs_input" {
			t.Errorf("%s: notification_type in line %q", ev, raw)
		}
		at, err := time.Parse(time.RFC3339, got["at"].(string))
		if err != nil || at.Before(before) || at.After(time.Now().Add(time.Second)) {
			t.Errorf("%s: at %v, %v", ev, got["at"], err)
		}
		if strings.Contains(raw, "secret") {
			t.Errorf("%s: line %q holds the prompt", ev, raw)
		}
	}
	noLine(t, lines)
}

func TestPaneEventTableHasTheAttentionEvents(t *testing.T) {
	for _, ev := range []string{"SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
		"PermissionRequest", "Notification", "PostToolUse", "StopFailure"} {
		if !slices.Contains(session.PaneEvents(), ev) {
			t.Errorf("the event table has no %s", ev)
		}
	}
}

func TestPaneNotificationFilter(t *testing.T) {
	setup(t)
	path, lines := listen(t)
	env := map[string]string{"LOAM_PANE_SOCKET": path}
	for _, typ := range []string{"elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "permission_prompt"} {
		runHook(t, hookJSON("Notification", `,"notification_type":"`+typ+`"`), env)
		var got session.PaneLine
		if err := json.Unmarshal([]byte(nextLine(t, lines)), &got); err != nil {
			t.Fatal(err)
		}
		if got.Event != "Notification" || got.NotificationType != typ {
			t.Errorf("%s: line %+v", typ, got)
		}
	}
	for _, typ := range []string{"idle_prompt", "auth_success", "elicitation_complete", "elicitation_response", "something_new", ""} {
		runHook(t, hookJSON("Notification", `,"notification_type":"`+typ+`"`), env)
		noLine(t, lines)
	}
	runHook(t, hookJSON("Notification", ""), env)
	noLine(t, lines)
}

func TestPaneSubagentStopRaisesNothing(t *testing.T) {
	setup(t)
	path, lines := listen(t)
	runHook(t, hookJSON("SubagentStop", `,"agent_id":"a1"`), map[string]string{"LOAM_PANE_SOCKET": path})
	noLine(t, lines)
}

func TestPaneNotificationWithoutSocketSendsNothing(t *testing.T) {
	e := setup(t)
	runHook(t, hookJSON("Notification", `,"notification_type":"agent_needs_input"`), map[string]string{})
	if log := hookLog(t, e.home); log != "" {
		t.Errorf("hook.log %q", log)
	}
}

func TestPaneSessionStartLineHoldsSource(t *testing.T) {
	setup(t)
	path, lines := listen(t)
	runHook(t, hookJSON("SessionStart", `,"source":"resume"`), map[string]string{"LOAM_PANE_SOCKET": path})
	var got session.PaneLine
	if err := json.Unmarshal([]byte(nextLine(t, lines)), &got); err != nil {
		t.Fatal(err)
	}
	if got.Source != "resume" {
		t.Errorf("source %q", got.Source)
	}
}

func TestPaneIgnoresEventsOutsideTheTable(t *testing.T) {
	setup(t)
	path, lines := listen(t)
	runHook(t, hookJSON("PreToolUse", ""), map[string]string{"LOAM_PANE_SOCKET": path})
	runHook(t, `{"session_id":"s1"}`, map[string]string{"LOAM_PANE_SOCKET": path})
	noLine(t, lines)
}

func TestPaneLiveSessionStartStillRecordsPID(t *testing.T) {
	e := setup(t)
	path, lines := listen(t)
	runHook(t, hookJSON("SessionStart", `,"source":"startup"`), map[string]string{"LOAM_PANE_SOCKET": path, "CLAUDE_PID": "4243"})
	nextLine(t, lines)
	if id, ok, _ := e.store.SessionForPID(4243); !ok || id != "s1" {
		t.Errorf("pid record %q %v", id, ok)
	}
}

func TestOtherEventsDoNotTouchTheStore(t *testing.T) {
	e := setup(t)
	for _, ev := range []string{"Stop", "UserPromptSubmit", "SessionEnd"} {
		runHook(t, hookJSON(ev, `,"source":"clear"`), map[string]string{"CLAUDE_PID": "4244"})
	}
	if id, ok, _ := e.store.SessionForPID(4244); ok {
		t.Errorf("pid record %q", id)
	}
}

// settingsEvents reads the per-session settings file that the last fake
// claude run got, and returns the hook command of each event.
func settingsEvents(t *testing.T, path string) map[string][]string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var s struct {
		Hooks map[string][]struct {
			Hooks []struct{ Type, Command string }
		}
	}
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for ev, groups := range s.Hooks {
		for _, g := range groups {
			for _, h := range g.Hooks {
				if h.Type != "command" {
					t.Errorf("%s: hook type %q", ev, h.Type)
				}
				out[ev] = append(out[ev], h.Command)
			}
		}
	}
	return out
}

func TestStartAndResumeRegisterTheEventTable(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	want := session.PaneEvents()
	slices.Sort(want)
	for _, args := range [][]string{{"start", p.ID, "--session-id", fixedID}, {"resume", fixedID}} {
		if out, err := e.run(t, args...); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		files := argValues(testutil.FakeClaudeInvocation(t).Args, "--settings")
		if len(files) != 1 {
			t.Fatalf("%s: --settings %v", args[0], files)
		}
		got := settingsEvents(t, files[0])
		events := make([]string, 0, len(got))
		for ev, cmds := range got {
			events = append(events, ev)
			if len(cmds) != 1 || !strings.HasSuffix(cmds[0], " hook") || !strings.HasPrefix(cmds[0], "'/") {
				t.Errorf("%s: %s commands %q", args[0], ev, cmds)
			}
		}
		slices.Sort(events)
		if !slices.Equal(events, want) {
			t.Errorf("%s: events %v, want %v", args[0], events, want)
		}
		os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	}
}
