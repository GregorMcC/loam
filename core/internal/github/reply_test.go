package github_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// posted is what the fake gh holds of the posts of Loam.
type posted struct {
	ThreadReplies map[string][]string `json:"thread_replies"`
	Resolved      []string            `json:"resolved"`
	PRComments    map[string][]string `json:"pr_comments"`
}

// fakePosts reads what the fake gh holds now.
func fakePosts(t *testing.T) posted {
	t.Helper()
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err != nil {
		t.Fatal(err)
	}
	var p posted
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatal(err)
	}
	return p
}

// TAS-175: Loam posts the replies of a run session, so the session needs no GitHub access.
func TestReplyToThreadAndResolveThreadPostAsTheUser(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{}`)
	c := client(t)
	if err := c.ReplyToThread(context.Background(), "PRRT_1", "Fixed in the last commit."); err != nil {
		t.Fatal(err)
	}
	if err := c.ResolveThread(context.Background(), "PRRT_1"); err != nil {
		t.Fatal(err)
	}
	calls := testutil.FakeGHCalls(t)
	if len(calls) != 2 || calls[0].Variables["thread"] != "PRRT_1" || calls[0].Variables["body"] != "Fixed in the last commit." ||
		calls[1].Variables["thread"] != "PRRT_1" {
		t.Fatalf("calls %+v", calls)
	}
	p := fakePosts(t)
	if !slices.Equal(p.ThreadReplies["PRRT_1"], []string{"Fixed in the last commit."}) || !slices.Equal(p.Resolved, []string{"PRRT_1"}) {
		t.Fatalf("%+v", p)
	}
}

// A refusal keeps the message of GitHub, and a rate limit is ErrRateLimited.
func TestReplyToThreadKeepsTheMessageOfARefusal(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{"thread_refusals": {"PRRT_9": "Could not resolve to a node with the global id of 'PRRT_9'"}}`)
	err := client(t).ReplyToThread(context.Background(), "PRRT_9", "Done.")
	if err == nil || !strings.Contains(err.Error(), "could not reply on the review thread PRRT_9: Could not resolve to a node") {
		t.Fatalf("err %v", err)
	}
	if err := client(t).ResolveThread(context.Background(), "PRRT_9"); err == nil || !strings.Contains(err.Error(), "could not resolve the review thread PRRT_9") {
		t.Fatalf("err %v", err)
	}
	// Loam can post again later after a rate limit, with no network, or after an HTTP 5xx.
	for fail, want := range map[string]error{"rate_limited": github.ErrRateLimited, "offline": github.ErrOffline,
		"server_error": github.ErrOffline} {
		t.Setenv("LOAM_FAKE_GH_FAIL", fail)
		if err := client(t).ReplyToThread(context.Background(), "PRRT_1", "Done."); !errors.Is(err, want) {
			t.Errorf("%s: err %v", fail, err)
		}
		if err := client(t).CommentPR(context.Background(), widgets, 7, "Done."); !errors.Is(err, want) {
			t.Errorf("%s: comment err %v", fail, err)
		}
	}
}

func TestCommentPRPostsTheBodyFromStdin(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{}`)
	if err := client(t).CommentPR(context.Background(), widgets, 7, "The name stays: it is in the contract.\n"); err != nil {
		t.Fatal(err)
	}
	args := testutil.FakeGHCalls(t)[0].Args
	if !slices.Equal(args, []string{"pr", "comment", "7", "--repo", "github.com/example/widgets", "--body-file", "-"}) {
		t.Fatalf("args %q", args)
	}
	if p := fakePosts(t); !slices.Equal(p.PRComments["7"], []string{"The name stays: it is in the contract.\n"}) {
		t.Fatalf("%+v", p)
	}
	t.Setenv("LOAM_FAKE_GH_FAIL", "forbidden")
	// A refusal is not a failure to reach GitHub, so Loam does not post again.
	if err := client(t).CommentPR(context.Background(), widgets, 7, "x"); err == nil || errors.Is(err, github.ErrOffline) ||
		!strings.Contains(err.Error(), "could not comment on PR #7") {
		t.Fatalf("err %v", err)
	}
}
