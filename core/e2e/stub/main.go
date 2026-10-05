// Command stub is a stub MCP server for the e2e suite. Its approve tool is the
// target of --permission-prompt-tool. It logs each call to the file in
// STUB_LOG and denies it, so a logged call means Claude Code would ask.
package main

import (
	"context"
	"encoding/json"
	"log"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type approveIn struct {
	ToolName  string         `json:"tool_name"`
	Input     map[string]any `json:"input"`
	ToolUseID string         `json:"tool_use_id,omitempty"`
}

func main() {
	logPath := os.Getenv("STUB_LOG")
	srv := mcp.NewServer(&mcp.Implementation{Name: "stub", Version: "0"}, nil)
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "approve",
		Description: "Permission prompt stub. Logs the request and denies it.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in approveIn) (*mcp.CallToolResult, any, error) {
		if logPath != "" {
			line, _ := json.Marshal(in)
			if f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				f.Write(append(line, '\n'))
				f.Close()
			}
		}
		deny := `{"behavior":"deny","message":"The e2e stub denies every prompt."}`
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: deny}}}, nil, nil
	})
	if err := srv.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
