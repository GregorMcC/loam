package sandbox

import (
	"encoding/json"
	"testing"
)

// The sandbox block denies home, allows the rule paths, and locks the three
// ways out: it refuses to start with no sandbox, refuses a retry outside the
// sandbox, and refuses a host off the list without a prompt.
func TestSettingsBlock(t *testing.T) {
	r := Rules{Home: "/h", Read: []string{"/w", "/h/.gitconfig"}, Write: []string{"/w"}}
	got, err := json.Marshal(r.Settings())
	if err != nil {
		t.Fatal(err)
	}
	const want = `{"allowUnsandboxedCommands":false,"enabled":true,"failIfUnavailable":true,` +
		`"filesystem":{"allowRead":["/w","/h/.gitconfig"],"allowWrite":["/w"],"denyRead":["/h"],"denyWrite":[]},` +
		`"network":{"allowedDomains":[],"strictAllowlist":true}}`
	if string(got) != want {
		t.Errorf("Settings =\n  %s\nwant\n  %s", got, want)
	}
}

// The Read and Edit tools work outside the sandbox, so permission rules deny
// them the credential paths.
func TestToolDenies(t *testing.T) {
	got := ToolDenies()
	for _, want := range []string{"Read(~/.ssh/**)", "Edit(~/.ssh/**)", "Read(~/.config/gh/**)", "Read(~/.cargo/credentials.toml)"} {
		found := false
		for _, g := range got {
			found = found || g == want
		}
		if !found {
			t.Errorf("ToolDenies has no %q: %q", want, got)
		}
	}
}
