// Command fakeclaude stands in for `claude` in tests. It writes its argv, its
// environment, and its working folder as JSON to the file named in
// LOAM_FAKE_CLAUDE_OUT. It then exits 0.
//
// With LOAM_FAKE_CLAUDE_HOOKS=1 it acts as a session instead of exiting. It
// runs the hooks of the --settings file, as Claude Code does, and reads one
// line at a time from stdin. Each hook gets CLAUDE_PID, as in Claude Code.
//
//   - EOF or "/exit": SessionEnd, then exit 0.
//   - "/clear": SessionEnd, then SessionStart with a new session ID and source "clear".
//   - "/branch": SessionEnd, then SessionStart with a new session ID and source "fork". The
//     process stays, as for the /branch command of Claude Code.
//   - "/permission": UserPromptSubmit, a wait of LOAM_FAKE_CLAUDE_TURN, then
//     PermissionRequest. The next line answers: "y" allows (PostToolUse, then
//     Stop). Any other line denies, and no hook follows, as in Claude Code.
//   - "/question": UserPromptSubmit, the wait, then a Notification of type
//     elicitation_dialog. The next line answers: PostToolUse, then Stop.
//   - "/paused": UserPromptSubmit, the wait, then only a Notification of type
//     permission_prompt, as for a "Session paused" dialog. The next line
//     answers: PostToolUse, then Stop.
//   - "/fail": UserPromptSubmit, the wait, then StopFailure (an API error).
//   - any other line is a prompt: UserPromptSubmit, a wait of
//     LOAM_FAKE_CLAUDE_TURN (default 1s), then Stop.
//
// The first SessionStart has source "resume" for --resume and "startup" otherwise.
//
// With LOAM_FAKE_CLAUDE_PROMPTS set to a file, each prompt line is added to
// that file before its UserPromptSubmit, so a test sees what was sent.
// LOAM_FAKE_CLAUDE_TITLES is a JSON object from the base name of the working
// folder to a terminal title. A session in a folder named there sets that
// title at its start, as Claude Code sets the topic of a session.
//
// With LOAM_FAKE_CLAUDE_HUP_WAIT set to a duration, a SIGHUP and the EOF of
// stdin do not end the process at once. It waits that long, then exits 0, as
// Claude Code takes time to end a session. A hang-up gives both: the pane's
// login process exits on SIGHUP, and macOS then revokes the terminal. Without
// it, a SIGHUP ends the process at once.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	// First, so the invocation file shows that the SIGHUP handler is in place.
	hupWait, err := time.ParseDuration(os.Getenv("LOAM_FAKE_CLAUDE_HUP_WAIT"))
	if err == nil {
		slowHangUp(hupWait)
	}
	out := os.Getenv("LOAM_FAKE_CLAUDE_OUT")
	if out == "" {
		fmt.Fprintln(os.Stderr, "fakeclaude: LOAM_FAKE_CLAUDE_OUT is not set")
		os.Exit(2)
	}
	cwd, _ := os.Getwd()
	env := map[string]string{}
	for _, kv := range os.Environ() {
		if k, v, ok := strings.Cut(kv, "="); ok {
			env[k] = v
		}
	}
	b, _ := json.Marshal(map[string]any{"args": os.Args[1:], "env": env, "cwd": cwd})
	if err := os.WriteFile(out, b, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "fakeclaude:", err)
		os.Exit(2)
	}
	if os.Getenv("LOAM_FAKE_CLAUDE_HOOKS") == "1" {
		if eof := session(os.Args[1:], cwd); eof {
			time.Sleep(hupWait)
		}
	}
}

// slowHangUp makes a SIGHUP end the process after the wait d.
func slowHangUp(d time.Duration) {
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	go func() {
		<-hup
		time.Sleep(d)
		os.Exit(0)
	}()
}

// session runs the hook mode. It returns true when stdin ended, and false
// after "/exit".
func session(args []string, cwd string) (eof bool) {
	id, source, settings := "", "startup", ""
	for i := 0; i+1 < len(args); i++ {
		switch args[i] {
		case "--session-id":
			id = args[i+1]
		case "--resume":
			id, source = args[i+1], "resume"
		case "--settings":
			settings = args[i+1]
		}
	}
	if id == "" {
		id = newID()
	}
	hooks := readHooks(settings)
	turn := time.Second
	if d, err := time.ParseDuration(os.Getenv("LOAM_FAKE_CLAUDE_TURN")); err == nil {
		turn = d
	}
	// run runs the hooks of one event. extra holds more fields of the hook
	// input, such as source or notification_type.
	run := func(event string, extra map[string]string) {
		input := map[string]string{"hook_event_name": event, "session_id": id, "cwd": cwd}
		for k, v := range extra {
			input[k] = v
		}
		b, _ := json.Marshal(input)
		for _, command := range hooks[event] {
			cmd := exec.Command("/bin/sh", "-c", command)
			cmd.Stdin = strings.NewReader(string(b))
			// Claude Code gives its hooks its PID. loam hook keys the session record to it.
			cmd.Env = append(os.Environ(), fmt.Sprintf("CLAUDE_PID=%d", os.Getpid()))
			cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
			_ = cmd.Run()
		}
	}

	run("SessionStart", map[string]string{"source": source})
	setTitle(cwd)
	fmt.Printf("fake claude: session %s\n> ", id)
	in := bufio.NewScanner(os.Stdin)
	// answer reads the line that answers a prompt. False at EOF.
	answer := func() (string, bool) {
		if !in.Scan() {
			return "", false
		}
		return strings.TrimSpace(in.Text()), true
	}
	startTurn := func() {
		run("UserPromptSubmit", nil)
		fmt.Println("fake claude: working")
		time.Sleep(turn)
	}
	endTurn := func() {
		run("PostToolUse", nil)
		run("Stop", nil)
		fmt.Println("fake claude: done")
	}
	for in.Scan() {
		switch line := strings.TrimSpace(in.Text()); line {
		case "/exit":
			run("SessionEnd", nil)
			fmt.Println("fake claude: bye")
			return false
		case "/clear":
			run("SessionEnd", nil)
			id = newID()
			run("SessionStart", map[string]string{"source": "clear"})
			fmt.Printf("fake claude: session %s\n", id)
		case "/branch":
			run("SessionEnd", nil)
			id = newID()
			run("SessionStart", map[string]string{"source": "fork"})
			fmt.Printf("fake claude: session %s\n", id)
		case "/permission":
			startTurn()
			run("PermissionRequest", nil)
			fmt.Print("fake claude: allow? (y/n) ")
			reply, ok := answer()
			if !ok {
				run("SessionEnd", nil)
				return true
			}
			if reply == "y" {
				endTurn()
			} else {
				fmt.Println("fake claude: denied")
			}
		case "/question":
			startTurn()
			run("Notification", map[string]string{"notification_type": "elicitation_dialog"})
			fmt.Print("fake claude: question? ")
			if _, ok := answer(); !ok {
				run("SessionEnd", nil)
				return true
			}
			endTurn()
		case "/paused":
			startTurn()
			run("Notification", map[string]string{"notification_type": "permission_prompt"})
			fmt.Print("fake claude: paused, continue? ")
			if _, ok := answer(); !ok {
				run("SessionEnd", nil)
				return true
			}
			endTurn()
		case "/fail":
			startTurn()
			run("StopFailure", nil)
			fmt.Println("fake claude: API error")
		case "":
		default:
			recordPrompt(line)
			startTurn()
			run("Stop", nil)
			fmt.Println("fake claude: done")
		}
		fmt.Print("> ")
	}
	run("SessionEnd", nil)
	return true
}

// recordPrompt adds the prompt to the file named in LOAM_FAKE_CLAUDE_PROMPTS.
func recordPrompt(line string) {
	path := os.Getenv("LOAM_FAKE_CLAUDE_PROMPTS")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		_, err = fmt.Fprintln(f, line)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "fakeclaude: prompts:", err)
	}
}

// setTitle sets the terminal title that LOAM_FAKE_CLAUDE_TITLES gives the
// working folder, with an OSC 2 sequence.
func setTitle(cwd string) {
	titles := map[string]string{}
	if s := os.Getenv("LOAM_FAKE_CLAUDE_TITLES"); s != "" {
		if err := json.Unmarshal([]byte(s), &titles); err != nil {
			fmt.Fprintln(os.Stderr, "fakeclaude: titles:", err)
		}
	}
	if title, ok := titles[filepath.Base(cwd)]; ok {
		fmt.Printf("\x1b]2;%s\x07", title)
	}
}

// readHooks returns the hook commands of each event in a Claude Code settings file.
func readHooks(path string) map[string][]string {
	var s struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	b, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(b, &s)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "fakeclaude: settings:", err)
	}
	out := map[string][]string{}
	for event, groups := range s.Hooks {
		for _, g := range groups {
			for _, h := range g.Hooks {
				out[event] = append(out[event], h.Command)
			}
		}
	}
	return out
}

// newID returns a random UUID version 4.
func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
