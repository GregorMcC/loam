package cli_test

import (
	"context"
	"os/exec"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The real binary serves MCP over stdio with the command `loam mcp` and no other args.
func TestMCPCommandServesOverStdio(t *testing.T) {
	bin := testutil.BuildLoam(t)
	testutil.Home(t)
	ctx := context.Background()
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil).
		Connect(ctx, &mcp.CommandTransport{Command: exec.Command(bin, "mcp")}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	res, err := cs.ListTools(ctx, nil)
	if err != nil || len(res.Tools) != 17 {
		t.Fatalf("tools %v, err %v", res, err)
	}
}
