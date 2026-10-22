package linkkind

import (
	"net/url"
	"regexp"
	"strings"
)

// linearID is the shape of a Linear issue ID, such as ENG-482.
var linearID = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9]*-[0-9]+$`)

// githubNumber is the shape of a GitHub issue number.
var githubNumber = regexp.MustCompile(`^[0-9]+$`)

// IssueKey returns the key of an issue link: the ID of a Linear issue, such
// as "ENG-482", or "#" and the number of a GitHub issue, such as "#57". It
// returns "" for any other target, a GitHub pull request included.
func IssueKey(target string) string {
	t := strings.TrimSpace(target)
	if IsLocal(t) {
		return ""
	}
	u, err := url.Parse(t)
	if err != nil {
		return ""
	}
	parts := strings.FieldsFunc(u.Path, func(r rune) bool { return r == '/' })
	switch urlKind(t) {
	case Linear:
		if len(parts) >= 3 && parts[1] == "issue" && linearID.MatchString(parts[2]) {
			return strings.ToUpper(parts[2])
		}
	case GitHub:
		if len(parts) >= 4 && parts[2] == "issues" && githubNumber.MatchString(parts[3]) {
			return "#" + parts[3]
		}
	}
	return ""
}
