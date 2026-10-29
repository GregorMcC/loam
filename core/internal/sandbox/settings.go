package sandbox

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
// outside the sandbox, so [ToolDenies] denies these paths to them.
var credentials = []string{
	"~/.ssh/**",
	"~/.config/gh/**",
	"~/.aws/**",
	"~/.docker/**",
	"~/.netrc",
	"~/.cargo/credentials.toml",
	"~/.npmrc",
	"~/.pypirc",
}

// ToolDenies returns the permission rules that deny the Read and Edit tools
// the credential paths.
func ToolDenies() []string {
	var out []string
	for _, tool := range []string{"Read", "Edit"} {
		for _, p := range credentials {
			out = append(out, tool+"("+p+")")
		}
	}
	return out
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
