package run

import (
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

func TestPRBodyHasTheGoalTheChecksAndTheIssue(t *testing.T) {
	widgets := github.Repo{Owner: "example", Name: "widgets"}
	r := store.Run{Title: "Drag a link", Goal: "A link moves by drag.", DoneWhen: []store.Check{{Name: "Tests", Command: "go test ./..."}}}
	cases := map[string]struct {
		src  *store.RunSource
		want string
	}{
		"linear":       {&store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}, "Linear: ENG-523"},
		"same repo":    {&store.RunSource{Kind: "github", Key: "#57", URL: "https://github.com/example/widgets/issues/57"}, "Closes #57"},
		"another repo": {&store.RunSource{Kind: "github", Key: "example/docs#9", URL: "https://github.com/example/docs/issues/9"}, "Closes example/docs#9"},
		"map":          {&store.RunSource{Kind: "map", Key: "map 12", URL: "/Users/me/maps/build/issues/12-plan.md"}, ""},
	}
	for name, c := range cases {
		r.Source = c.src
		body := prBody(r, widgets)
		for _, want := range []string{"A link moves by drag.", "- Tests: `go test ./...`", "- " + CommittedCheck, c.want} {
			if !strings.Contains(body, want) {
				t.Errorf("%s: the body misses %q:\n%s", name, want, body)
			}
		}
		if strings.Contains(body, "/Users/") {
			t.Errorf("%s: the body has a local path:\n%s", name, body)
		}
		// A Linear workspace can be private, and the repo public: the key
		// only, so its URL does not name the workspace or the issue title.
		if strings.Contains(body, "linear.app") {
			t.Errorf("%s: the body has a Linear URL:\n%s", name, body)
		}
	}
}
