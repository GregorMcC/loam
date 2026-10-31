package sandbox

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
)

// The sandbox block denies home, allows the rule paths, and locks the three
// ways out: it refuses to start with no sandbox, refuses a retry outside the
// sandbox, and refuses a host off the list without a prompt. Bash can listen
// on a port, and use a unix socket in the temp folder of Claude Code, so
// tests that start a server pass. Bash can reach trustd, which checks a TLS
// certificate, and write the temp folder of the user, but not the xcrun cache
// in it.
func TestSettingsBlock(t *testing.T) {
	old := UserTemp
	t.Cleanup(func() { UserTemp = old })
	UserTemp = func() []string { return []string{"/T"} }
	r := Rules{Home: "/h", Read: []string{"/w", "/h/.gitconfig"}, Write: []string{"/w"}}
	got, err := json.Marshal(r.Settings())
	if err != nil {
		t.Fatal(err)
	}
	want := `{"allowUnsandboxedCommands":false,"enabled":true,"failIfUnavailable":true,` +
		`"filesystem":{"allowRead":["/w","/h/.gitconfig"],"allowWrite":["/w","/T"],"denyRead":["/h"],"denyWrite":["` + XcrunCache() + `"]},` +
		`"network":{"allowLocalBinding":true,"allowMachLookup":["com.apple.trustd.agent"],"allowUnixSockets":["` + ClaudeTemp() + `"],"allowedDomains":[],"strictAllowlist":true}}`
	if string(got) != want {
		t.Errorf("Settings =\n  %s\nwant\n  %s", got, want)
	}
}

// The Read and Edit tools work outside the sandbox, so permission rules deny
// them the credential paths, and deny the Edit tool each denied write.
func TestToolDenies(t *testing.T) {
	got := Rules{DenyWrite: []string{"/p/plot"}}.ToolDenies()
	for _, want := range []string{
		"Read(~/.ssh/**)", "Edit(~/.ssh/**)", "Read(~/.config/gh/**)", "Read(~/.cargo/credentials.toml)", "Read(~/.claude.json)",
		// The Edit and Write tools work outside the sandbox, so they get
		// each denied write too.
		"Edit(//p/plot)", "Edit(//p/plot/**)",
	} {
		found := false
		for _, g := range got {
			found = found || g == want
		}
		if !found {
			t.Errorf("ToolDenies has no %q: %q", want, got)
		}
	}
}

// The temp folder of Claude Code is below /private/tmp, not /private/tmp
// itself, which holds the socket of the launchd SSH agent.
func TestClaudeTemp(t *testing.T) {
	want := filepath.Join(Real("/tmp"), "claude-"+strconv.Itoa(os.Getuid()))
	if got := ClaudeTemp(); got != want {
		t.Errorf("ClaudeTemp = %s, want %s", got, want)
	}
}

// Foundation and mktemp take the temp folder of the user, and ignore TMPDIR.
// The session writes that folder, and the Bash sandbox and the Edit tool deny
// the xcrun cache in it.
func TestUserTemp(t *testing.T) {
	got := UserTemp()
	want := filepath.Dir(XcrunCache())
	if len(got) != 1 || got[0] != want {
		t.Errorf("UserTemp = %q, want %s", got, want)
	}
	if denies := (Rules{}).ToolDenies(); !slices.Contains(denies, "Edit(/"+XcrunCache()+")") {
		t.Errorf("ToolDenies = %q, want the xcrun cache", denies)
	}
}
