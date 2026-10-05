package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type undoChangeIn struct {
	ChangeID  int64 `json:"change_id" jsonschema:"ID of the change to undo, from get_changes"`
	Overwrite bool  `json:"overwrite,omitempty" jsonschema:"write the old values even if a later change edited the same items. Use it only after you read the later changes."`
}

// registerUndo adds the undo_change tool.
func (s *Server) registerUndo(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "undo_change",
		Description: "Undo one change. The old values are written back as a new change by you. " +
			"If a later change edited the same items, nothing is written and the result lists the later changes and what the undo would write. " +
			"Set overwrite to true to write anyway. Plot creation cannot be undone.",
		Annotations: changes("Undo a change"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in undoChangeIn) (*mcp.CallToolResult, any, error) {
		if in.ChangeID < 1 {
			return fail(errors.New("change_id is required"))
		}
		actor, err := s.actor()
		if err != nil {
			return fail(err)
		}
		res, err := s.st.Undo(in.ChangeID, actor, in.Overwrite)
		var ce *store.UndoClashError
		if errors.As(err, &ce) {
			b, _ := json.MarshalIndent(ce, "", "  ")
			return fail(fmt.Errorf("%s. Nothing was changed. Read the later changes. To undo anyway, call undo_change again with overwrite true.\n%s", ce.Error(), b))
		}
		if err != nil {
			return fail(err)
		}
		// The plot changed under the remembered versions. Claude must read it again.
		s.mu.Lock()
		delete(s.versions, res.Plot.ID)
		s.mu.Unlock()
		seed.AfterChange(s.st, res)
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})
}
