package linkkind

import "testing"

// Ticket 114: a worktree that starts from an issue names it by its key.
func TestIssueKey(t *testing.T) {
	for _, c := range []struct{ target, want string }{
		{"https://linear.app/example/issue/ENG-482/link-kinds-for-figma", "ENG-482"},
		{"https://linear.app/example/issue/ENG-482", "ENG-482"},
		{"  https://linear.app/example/issue/eng-7/x  ", "ENG-7"},
		{"https://github.com/example/widgets/issues/57", "#57"},
		{"https://www.github.com/example/widgets/issues/57#issuecomment-1", "#57"},
		{"https://github.com/example/widgets/pull/57", ""},
		{"https://github.com/example/widgets/issues", ""},
		{"https://github.com/example/widgets/issues/new", ""},
		{"https://github.com/example/widgets", ""},
		{"https://linear.app/example/project/widgets-4f2a9c", ""},
		{"https://linear.app/example/issue/not-a-key/x", ""},
		{"https://example.com/example/issue/ENG-482", ""},
		{"https://example.com/example/widgets/issues/57", ""},
		{"/Users/me/notes/ENG-482.md", ""},
		{"", ""},
	} {
		if got := IssueKey(c.target); got != c.want {
			t.Errorf("IssueKey(%q) = %q, want %q", c.target, got, c.want)
		}
	}
}
