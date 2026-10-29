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
		body := prBody(r, widgets, nil)
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

// A run of a group names the other repos of its issue.
func TestPRBodyOfAGroupNamesTheOtherRepos(t *testing.T) {
	widgets := github.Repo{Owner: "example", Name: "widgets"}
	r := store.Run{Title: "Rename the setting", Source: &store.RunSource{Kind: "linear", Key: "ENG-523"}}
	if body := prBody(r, widgets, []string{"example/docs", "site"}); !strings.Contains(body, "\nThe issue also has runs in example/docs and site.\n") {
		t.Fatalf("body:\n%s", body)
	}
	if body := prBody(r, widgets, nil); strings.Contains(body, "also has runs") {
		t.Fatalf("body:\n%s", body)
	}
}

// The body lists the follow-ups that Loam filed, by key. A Linear issue has
// its key only, and a GitHub issue of the same repo has #number.
func TestPRBodyListsTheFollowUpsByKey(t *testing.T) {
	widgets := github.Repo{Owner: "example", Name: "widgets"}
	r := store.Run{Title: "Rename the setting", Shape: &store.RunShape{FollowUps: []store.FollowUp{
		{Title: "A picker in the app", Kept: true, Target: store.FollowUpTarget{Kind: store.TargetLinear},
			Filed: &store.FiledIssue{Key: "ENG-601", URL: "https://linear.app/acme/issue/ENG-601/x"}},
		{Title: "Docs for the setting", Kept: true, Target: store.FollowUpTarget{Kind: store.TargetGitHub},
			Filed: &store.FiledIssue{Key: "example/widgets#61", URL: "https://github.com/example/widgets/issues/61"}},
		{Title: "Dropped work", Kept: false},
		{Title: "Failed work", Kept: true, Error: "Linear refused"},
	}}}
	body := prBody(r, widgets, nil)
	for _, want := range []string{"\n## Follow-ups\n", "- ENG-601\n", "- #61: Docs for the setting\n"} {
		if !strings.Contains(body, want) {
			t.Errorf("the body misses %q:\n%s", want, body)
		}
	}
	for _, not := range []string{"linear.app", "A picker in the app", "Dropped work", "Failed work"} {
		if strings.Contains(body, not) {
			t.Errorf("the body has %q:\n%s", not, body)
		}
	}
	r.Shape.FollowUps = nil
	if body := prBody(r, widgets, nil); strings.Contains(body, "Follow-ups") {
		t.Errorf("the body has a Follow-ups section with no follow-up:\n%s", body)
	}
}
