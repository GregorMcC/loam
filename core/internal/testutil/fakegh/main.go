// Command fakegh stands in for `gh` in tests. It answers `gh api graphql
// --input -` from a GitHub state in the JSON file named in
// LOAM_FAKE_GH_STATE, and appends each call as one JSON line to the file
// named in LOAM_FAKE_GH_LOG.
//
// The state file holds:
//
//   - "refs": the branches that are on GitHub.
//   - "pulls": pull request nodes for the first query. A branch gets each
//     node whose headRefName is the branch, in the order of the file.
//   - "details": pull request nodes for the second query, keyed by number.
//
// The fake reads the query variables as Loam names them: h<i> is a branch
// in the first query, and n<i> is a PR number in the second query.
//
// LOAM_FAKE_GH_FAIL makes each call fail as gh does: "signed_out" exits 4,
// and "rate_limited" and "offline" exit 1 with the text that gh prints.
// "hang" waits for a minute, as a call with no network can.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

type state struct {
	Refs    []string                   `json:"refs"`
	Pulls   []map[string]any           `json:"pulls"`
	Details map[string]json.RawMessage `json:"details"`
}

func main() {
	body, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	var req struct {
		Variables map[string]any `json:"variables"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		fail(2, "fakegh: the request body is not JSON: "+err.Error())
	}
	logCall(req.Variables)

	switch os.Getenv("LOAM_FAKE_GH_FAIL") {
	case "":
	case "signed_out":
		fail(4, "To get started with GitHub CLI, please run:  gh auth login")
	case "rate_limited":
		fmt.Println(`{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}`)
		fail(1, "gh: API rate limit exceeded for user ID 1.")
	case "offline":
		fail(1, "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com")
	case "hang":
		time.Sleep(time.Minute)
	default:
		fail(2, "fakegh: unknown LOAM_FAKE_GH_FAIL")
	}

	var st state
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &st)
	}
	if err != nil {
		fail(2, "fakegh: state: "+err.Error())
	}
	repo := map[string]any{}
	for name, v := range req.Variables {
		i, isBranch := strings.CutPrefix(name, "h")
		if _, err := strconv.Atoi(i); !isBranch || err != nil || req.Variables["n"+i] != nil {
			continue
		}
		branch, _ := v.(string)
		nodes := []map[string]any{}
		for _, p := range st.Pulls {
			if p["headRefName"] == branch {
				nodes = append(nodes, p)
			}
		}
		repo["pr"+i] = map[string]any{"nodes": nodes}
		repo["ref"+i] = nil
		if slices.Contains(st.Refs, branch) {
			repo["ref"+i] = map[string]any{"name": branch}
		}
	}
	for name, v := range req.Variables {
		if i, ok := strings.CutPrefix(name, "n"); ok {
			number, _ := v.(float64)
			repo["p"+i] = st.Details[strconv.Itoa(int(number))]
		}
	}
	out, _ := json.Marshal(map[string]any{"data": map[string]any{"repository": repo}})
	fmt.Println(string(out))
}

// logCall appends the arguments and the query variables of this call to the log.
func logCall(vars map[string]any) {
	path := os.Getenv("LOAM_FAKE_GH_LOG")
	if path == "" {
		return
	}
	line, _ := json.Marshal(map[string]any{"args": os.Args[1:], "variables": vars})
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	defer f.Close()
	fmt.Fprintln(f, string(line))
}

func fail(code int, msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(code)
}
