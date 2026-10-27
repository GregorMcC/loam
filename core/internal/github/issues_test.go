package github_test

import (
	"context"
	"errors"
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

const issuesState = `{"issues": [
  {"number": 48, "title": "Install fails when ~/.local/bin is missing", "url": "https://github.com/example/widgets/issues/48",
   "labels": [{"name": "bug"}], "updatedAt": "2026-10-20T10:00:00Z"},
  {"number": 52, "title": "Paste a long prompt without a hang", "url": "https://github.com/example/widgets/issues/52",
   "labels": [], "updatedAt": "2026-10-22T09:00:00Z"}
]}`

func TestIssuesListsTheOpenIssuesOfARepo(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, issuesState)
	got, err := client(t).Issues(context.Background(), widgets)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Number != 48 || got[0].Title != "Install fails when ~/.local/bin is missing" ||
		got[0].URL != "https://github.com/example/widgets/issues/48" || !slices.Equal(got[0].Labels, []string{"bug"}) ||
		got[0].UpdatedAt != "2026-10-20T10:00:00Z" || got[1].Labels == nil {
		t.Fatalf("%+v", got)
	}
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 1 || !slices.Contains(calls[0].Args, "github.com/example/widgets") || !slices.Contains(calls[0].Args, "open") {
		t.Fatalf("calls %+v", calls)
	}
}

func TestIssuesGivesTheErrorsOfARead(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, issuesState)
	t.Setenv("LOAM_FAKE_GH_FAIL", "rate_limited")
	if _, err := client(t).Issues(context.Background(), widgets); !errors.Is(err, github.ErrRateLimited) {
		t.Fatalf("err %v", err)
	}
}
