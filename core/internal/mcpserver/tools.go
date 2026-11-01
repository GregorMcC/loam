package mcpserver

import (
	"context"
	"slices"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Tool is a tool that the server registers.
type Tool struct {
	Name string
	// ReadOnly is the read-only hint of the tool. A run session can use only
	// the tools that set it (see session.runToolRules), so set it only on a
	// tool that does not change a plot.
	ReadOnly bool
}

// Tools returns the tools that the server registers, by name. A tool with no
// annotations is not ReadOnly, so a new tool is a write tool until its
// registration says otherwise.
func Tools(ctx context.Context) ([]Tool, error) {
	// The SDK does not show the tools of a server, so ask the server as a
	// client does. No tool runs, so the server needs no store.
	serverEnd, clientEnd := mcp.NewInMemoryTransports()
	ss, err := New(Options{}).Connect(ctx, serverEnd, nil)
	if err != nil {
		return nil, err
	}
	defer ss.Close()
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "loam"}, nil).Connect(ctx, clientEnd, nil)
	if err != nil {
		return nil, err
	}
	defer cs.Close()
	var out []Tool
	for t, err := range cs.Tools(ctx, nil) {
		if err != nil {
			return nil, err
		}
		out = append(out, Tool{Name: t.Name, ReadOnly: t.Annotations != nil && t.Annotations.ReadOnlyHint})
	}
	slices.SortFunc(out, func(a, b Tool) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}
