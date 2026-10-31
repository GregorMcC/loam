package sandbox

import (
	"os"
	"slices"
	"strconv"
	"strings"
)

// Settings returns the sandbox block of the Claude Code settings of a run.
// It covers Bash and the processes that Bash starts.
func (r Rules) Settings() map[string]any {
	return map[string]any{
		"enabled": true,
		// With no sandbox, the session does not start: Loam keeps the run
		// Queued.
		"failIfUnavailable": true,
		// Claude Code ignores a command's request to run outside the sandbox.
		"allowUnsandboxedCommands": false,
		"network": map[string]any{
			"allowedDomains": nonNil(r.Hosts),
			// A host off the list is refused, not asked about: nobody answers
			// the prompts of a background session.
			"strictAllowlist": true,
			// Tests start servers. allowLocalBinding lets Bash listen on any
			// address, 0.0.0.0 too, so a device on the network of the Mac
			// can connect to such a server. Bash still reaches no host off
			// the list.
			"allowLocalBinding": true,
			// Bash can bind and connect a unix socket only in the temp
			// folder of Claude Code, which is TMPDIR in Bash. Not /tmp: it
			// holds the socket of the launchd SSH agent.
			"allowUnixSockets": []string{ClaudeTemp()},
			// Go and other tools on macOS check a TLS certificate through
			// trustd. With no lookup of it, each HTTPS fetch fails with
			// OSStatus -26276.
			"allowMachLookup": []string{"com.apple.trustd.agent"},
		},
		"filesystem": map[string]any{
			"denyRead":   []string{r.Home},
			"allowRead":  nonNil(r.Read),
			"allowWrite": nonNil(append(slices.Clone(r.Write), UserTemp()...)),
			"denyWrite":  nonNil(r.sessionDenyWrite()),
		},
	}
}

// credentials are the paths below home that hold credentials. The sandbox
// denies them to Bash with the rest of home. The Read and Edit tools work
// outside the sandbox, so [Rules.ToolDenies] denies these paths to them.
var credentials = []string{
	"~/.ssh/**",
	"~/.gnupg/**",
	"~/.config/gh/**",
	"~/.config/gcloud/**",
	"~/.config/op/**",
	"~/.aws/**",
	"~/.azure/**",
	"~/.kube/**",
	"~/.docker/**",
	"~/Library/Keychains/**",
	"~/.netrc",
	"~/.git-credentials",
	"~/.config/git/credentials",
	"~/.claude.json",
	"~/.cargo/credentials.toml",
	"~/.npmrc",
	"~/.pypirc",
}

// ToolDenies returns the permission rules that deny the Read and Edit tools
// the credential paths, and the Edit tool each path of DenyWrite and the xcrun
// cache. Edit rules cover the Write tool too. A rule path that starts with //
// is absolute.
func (r Rules) ToolDenies() []string {
	var out []string
	for _, tool := range []string{"Read", "Edit"} {
		for _, p := range credentials {
			out = append(out, tool+"("+p+")")
		}
	}
	for _, p := range r.sessionDenyWrite() {
		out = append(out, "Edit(/"+p+")", "Edit(/"+p+"/**)")
	}
	return out
}

// sessionDenyWrite returns DenyWrite and the xcrun cache of the user, which
// is in a folder that the session can write (see [UserTemp]).
func (r Rules) sessionDenyWrite() []string {
	out := slices.Clone(r.DenyWrite)
	if c := XcrunCache(); c != "" {
		out = append(out, Real(c))
	}
	return out
}

// UserTemp returns the temp folder of the user by its real path. Foundation
// and mktemp take it, and ignore TMPDIR, so most Swift tests and many scripts
// write there. The session denies the xcrun cache in it (see [xcrunCache]).
// It returns none when getconf cannot name the folder.
var UserTemp = func() []string {
	if d := getconf("DARWIN_USER_TEMP_DIR"); d != "" {
		return []string{Real(d)}
	}
	return nil
}

// ClaudeTemp returns the temp folder of Claude Code by its real path. Claude
// Code sets TMPDIR to it in sandboxed Bash, and lets Bash write there.
func ClaudeTemp() string { return Real("/tmp/claude-" + strconv.Itoa(os.Getuid())) }

// everyRun is the note of every run: what to do when the sandbox denies a
// command.
const everyRun = "When the sandbox denies a command, say so and go on. Do not work around it."

// Prompt returns the text that the first prompt of a run adds about the
// sandbox.
func (r Rules) Prompt() string {
	return "\n\nBash works in a sandbox. " + strings.Join(append([]string{everyRun}, r.Notes...), " ")
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
