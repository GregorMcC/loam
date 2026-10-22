package linkkind

import "testing"

// Ticket 114: a worktree that starts from an issue names it by its key.
func TestIssueKey(t *testing.T) {
	for _, c := range []struct{ target, want string }{
		{"https://linear.app/example/issue/ENG-482/link-kinds-for-figma", "ENG-482"},
		{"https://linear.app/example/issue/ENG-482", "ENG-482"},
		{"  https://linear.app/example/issue/eng-7/x  ", "ENG-7"},
		{"https://github.com/example/widgets/issues/57", "example/widgets#57"},
		{"https://www.github.com/example/widgets/issues/57#issuecomment-1", "example/widgets#57"},
		{"https://github.com/example/widgets/pull/57", ""},
		{"https://github.com/example/widgets/issues", ""},
		{"https://github.com/example/widgets/issues/new", ""},
		{"https://github.com/example/widgets", ""},
		// An owner or a repo name that GitHub does not allow is not an issue,
		// so a control character never reaches the key.
		{"https://github.com/exa%1bmple/widgets/issues/57", ""},
		{"https://github.com/example/wid%0Agets/issues/57", ""},
		{"https://linear.app/example/project/widgets-4f2a9c", ""},
		{"https://linear.app/example/issue/not-a-key/x", ""},
		{"https://example.com/example/issue/ENG-482", ""},
		{"https://example.com/example/widgets/issues/57", ""},
		{"/Users/me/notes/ENG-482.md", ""},
		{"", ""},
	} {
		if got := IssueKey(c.target, ""); got != c.want {
			t.Errorf("IssueKey(%q, \"\") = %q, want %q", c.target, got, c.want)
		}
	}
}

// GitHub reads "Fixes #57" as an issue of the PR's repo. So the key is "#57"
// only when the issue is in the repo that the PR goes to. Else it names the
// repo, as "Fixes example/widgets#57" must.
func TestIssueKeyNamesTheRepoOfAnIssueInAnotherRepo(t *testing.T) {
	const issue = "https://github.com/example/widgets/issues/57"
	for _, c := range []struct{ target, repo, want string }{
		{issue, "https://github.com/example/widgets", "#57"},
		{issue, "https://github.com/Example/Widgets", "#57"},
		{"https://github.com/EXAMPLE/widgets/issues/57", "https://www.github.com/example/widgets/", "#57"},
		{issue, "https://github.com/example/gadgets", "example/widgets#57"},
		{issue, "https://github.com/other/widgets", "example/widgets#57"},
		{issue, "https://github.com/example/widgets/tree/main", "example/widgets#57"},
		// A repo that is not on github.com.
		{issue, "https://gitlab.com/example/widgets", "example/widgets#57"},
		{issue, "https://git.example.com/example/widgets", "example/widgets#57"},
		{issue, "", "example/widgets#57"},
		// A Linear key never names a repo.
		{"https://linear.app/example/issue/ENG-482/x", "https://github.com/example/widgets", "ENG-482"},
	} {
		if got := IssueKey(c.target, c.repo); got != c.want {
			t.Errorf("IssueKey(%q, %q) = %q, want %q", c.target, c.repo, got, c.want)
		}
	}
}
