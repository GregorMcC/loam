package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Efforts are the effort levels that Claude Code accepts, lowest first.
var Efforts = []string{"low", "medium", "high", "xhigh", "max"}

// CheckEffort returns an error that wraps [ErrInvalid] when effort is not a
// level that Claude Code accepts. Empty is fine: it means the Claude Code
// setting.
func CheckEffort(effort string) error {
	if effort == "" || slices.Contains(Efforts, effort) {
		return nil
	}
	return fmt.Errorf("%q is not an effort level: use %s: %w", effort, strings.Join(Efforts, ", "), ErrInvalid)
}

// RunDefaults are the model and the effort that a run of a plot uses when
// the run names none. Empty means the Claude Code setting. MCPServers names
// the MCP servers from the Claude Code config that claude -p loads when it
// drafts a run, writes the PR text, or reviews the code. Empty means none.
// Review turns on the code review that Loam runs before it pushes a run of
// the plot, and ReviewEffort is the effort level of that review. They are
// not in the change log, as rules and runs are not.
type RunDefaults struct {
	PlotID       string   `json:"plot_id"`
	Model        string   `json:"model"`
	Effort       string   `json:"effort"`
	MCPServers   []string `json:"mcp_servers"`
	Review       bool     `json:"review"`
	ReviewEffort string   `json:"review_effort"`
}

// GetRunDefaults returns the run defaults of a plot. A plot that has none
// gets empty strings and no MCP servers, and the review is on.
func (s *Store) GetRunDefaults(plotID string) (RunDefaults, error) {
	d := RunDefaults{PlotID: plotID, MCPServers: []string{}, Review: true}
	err := s.readTx(func(q queryer) error {
		var mcp string
		err := q.QueryRowContext(context.Background(), `SELECT model, effort, mcp_servers, review, review_effort FROM run_defaults WHERE plot_id = ?`, plotID).
			Scan(&d.Model, &d.Effort, &mcp, &d.Review, &d.ReviewEffort)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		return json.Unmarshal([]byte(mcp), &d.MCPServers)
	})
	return d, err
}

// cleanNames trims each name and leaves out empty names and repeats, in
// order.
func cleanNames(names []string) []string {
	out := []string{}
	for _, n := range names {
		if n = strings.TrimSpace(n); n != "" && !slices.Contains(out, n) {
			out = append(out, n)
		}
	}
	return out
}

// SetRunDefaults replaces the run defaults of a plot.
func (s *Store) SetRunDefaults(d RunDefaults) (RunDefaults, error) {
	d.Model = strings.TrimSpace(d.Model)
	d.MCPServers = cleanNames(d.MCPServers)
	if err := CheckEffort(d.Effort); err != nil {
		return RunDefaults{}, err
	}
	if err := CheckEffort(d.ReviewEffort); err != nil {
		return RunDefaults{}, err
	}
	tx, err := s.beginWrite()
	if err != nil {
		return RunDefaults{}, err
	}
	defer tx.rollback()
	ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, d.PlotID)
	if err != nil {
		return RunDefaults{}, err
	}
	if !ok {
		return RunDefaults{}, fmt.Errorf("plot %q: %w", d.PlotID, ErrNotFound)
	}
	mcp, err := json.Marshal(d.MCPServers)
	if err != nil {
		return RunDefaults{}, err
	}
	if err := tx.exec(`INSERT INTO run_defaults(plot_id, model, effort, mcp_servers, review, review_effort, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(plot_id) DO UPDATE SET model = excluded.model, effort = excluded.effort, mcp_servers = excluded.mcp_servers,
  review = excluded.review, review_effort = excluded.review_effort, updated_at = excluded.updated_at`,
		d.PlotID, d.Model, d.Effort, string(mcp), d.Review, d.ReviewEffort, time.Now().UnixMilli()); err != nil {
		return RunDefaults{}, err
	}
	return d, tx.commit()
}
