package github_test

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestCreatePROpensAPRAndReadsItsNumber(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{"pulls": [{"number": 146, "headRefName": "older"}]}`)
	pr, err := client(t).CreatePR(context.Background(), widgets, github.NewPR{
		Head: "eng-523-drag", Base: "main", Title: "Drag a link to reorder it", Body: "The goal.\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	if pr.Number != 147 || pr.URL != "https://github.com/example/widgets/pull/147" {
		t.Fatalf("%+v", pr)
	}
	args := testutil.FakeGHCalls(t)[0].Args
	for _, want := range [][]string{{"--repo", "github.com/example/widgets"}, {"--head", "eng-523-drag"}, {"--base", "main"},
		{"--title", "Drag a link to reorder it"}, {"--body-file", "-"}} {
		i := slices.Index(args, want[0])
		if i < 0 || i+1 >= len(args) || args[i+1] != want[1] {
			t.Errorf("args %q miss %q", args, want)
		}
	}
}

func TestCreatePRKeepsTheMessageOfARefusal(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{}`)
	_, err := client(t).CreatePR(context.Background(), widgets, github.NewPR{Title: "No head"})
	if err == nil || !strings.Contains(err.Error(), "could not open a PR") {
		t.Fatalf("err %v", err)
	}
}

func TestFailedLogGivesTheLastLinesOfTheFailedJobs(t *testing.T) {
	testutil.Home(t)
	var log strings.Builder
	for i := 1; i <= 300; i++ {
		log.WriteString("test\tgo test\tline " + strings.Repeat("x", i%3) + "\n")
	}
	log.WriteString("test\tgo test\tFAIL: TestDrag\n")
	testutil.FakeGH(t, `{"logs": {"9001": `+quote(log.String())+`}}`)
	got, err := client(t).FailedLog(context.Background(), widgets, 9001, 50)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != 50 || lines[49] != "test\tgo test\tFAIL: TestDrag" {
		t.Fatalf("%d lines, last %q", len(lines), lines[len(lines)-1])
	}
	t.Setenv("LOAM_FAKE_GH_FAIL", "rate_limited")
	if _, err := client(t).FailedLog(context.Background(), widgets, 9001, 50); !errors.Is(err, github.ErrRateLimited) {
		t.Fatalf("err %v", err)
	}
}

// quote gives s as a JSON string.
func quote(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func TestViewPRReadsTheStateByNumber(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{"pulls": [{"number": 45, "state": "MERGED", "headRefName": "gone"}]}`)
	st, err := client(t).ViewPR(context.Background(), widgets, 45)
	if err != nil || st.Number != 45 || st.State != "MERGED" {
		t.Fatalf("%+v %v", st, err)
	}
	args := testutil.FakeGHCalls(t)[0].Args
	if i := slices.Index(args, "--json"); i < 0 || args[i+1] != "state,number" {
		t.Errorf("args %q", args)
	}
	if _, err := client(t).ViewPR(context.Background(), widgets, 46); err == nil {
		t.Fatal("no error for a PR that is not there")
	}
}

func TestPRRepoReadsTheRepoOfAPRURL(t *testing.T) {
	r, ok := github.PRRepo("https://github.com/example/widgets/pull/45")
	if !ok || r != widgets {
		t.Fatalf("%+v %v", r, ok)
	}
	if _, ok := github.PRRepo("https://example.com/example/widgets/pull/45"); ok {
		t.Fatal("another host")
	}
}
