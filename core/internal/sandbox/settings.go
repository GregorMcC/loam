package sandbox

import "strings"

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
			// Tests bind servers on localhost, such as Go's httptest. It lets
			// a command reach a service on localhost too. Other hosts stay
			// denied.
			"allowLocalBinding": true,
		},
		"filesystem": map[string]any{
			"denyRead":   []string{r.Home},
			"allowRead":  nonNil(r.Read),
			"allowWrite": nonNil(r.Write),
			"denyWrite":  nonNil(r.DenyWrite),
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
// the credential paths, and the Edit tool each path of DenyWrite. Edit rules
// cover the Write tool too. A rule path that starts with // is absolute.
func (r Rules) ToolDenies() []string {
	var out []string
	for _, tool := range []string{"Read", "Edit"} {
		for _, p := range credentials {
			out = append(out, tool+"("+p+")")
		}
	}
	for _, p := range r.DenyWrite {
		out = append(out, "Edit(/"+p+")", "Edit(/"+p+"/**)")
	}
	return out
}

// Prompt returns the text that the first prompt of a run adds about the
// sandbox, or "" when its stacks need nothing.
func (r Rules) Prompt() string {
	if len(r.Notes) == 0 {
		return ""
	}
	return "\n\nBash works in a sandbox. " + strings.Join(r.Notes, " ")
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
