package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"time"

	"github.com/GregorMcC/loam/core/internal/sandbox"
)

// SandboxSettings are the paths and hosts that the user adds to the sandbox
// of a run, on top of what the stack presets give. An empty PlotID is the
// machine scope, which holds for the runs of every plot. A write path is also
// a read path. Only the CLI and the app set them, never an MCP tool. They are
// not in the change log, as runs are not.
type SandboxSettings struct {
	PlotID string   `json:"plot_id"`
	Read   []string `json:"read"`
	Write  []string `json:"write"`
	Hosts  []string `json:"hosts"`
}

// GetSandboxSettings returns the settings of a plot, or of the machine when
// plotID is empty. A scope that has none gets empty lists.
func (s *Store) GetSandboxSettings(plotID string) (SandboxSettings, error) {
	d := SandboxSettings{PlotID: plotID, Read: []string{}, Write: []string{}, Hosts: []string{}}
	err := s.readTx(func(q queryer) error {
		var read, write, hosts string
		err := q.QueryRowContext(context.Background(), `SELECT read_paths, write_paths, hosts FROM sandbox_settings WHERE scope = ?`, plotID).
			Scan(&read, &write, &hosts)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		for _, f := range []struct {
			text string
			to   *[]string
		}{{read, &d.Read}, {write, &d.Write}, {hosts, &d.Hosts}} {
			if err := json.Unmarshal([]byte(f.text), f.to); err != nil {
				return err
			}
		}
		return nil
	})
	return d, err
}

// SetSandboxSettings replaces the settings of a scope. It trims each item,
// leaves out empty items and repeats, and checks each one with the rules of
// the sandbox package: a path that opens home or a host that is not a DNS
// name wraps [ErrInvalid], and nothing is stored. A plot that does not exist
// wraps [ErrNotFound]. It returns the settings as stored.
func (s *Store) SetSandboxSettings(d SandboxSettings) (SandboxSettings, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return SandboxSettings{}, fmt.Errorf("the sandbox needs the home folder: %w", err)
	}
	for _, f := range []struct {
		kind  string
		items *[]string
		check func(string) (string, error)
	}{
		{"read path", &d.Read, func(p string) (string, error) { return sandbox.CheckPath(home, p, s.home) }},
		{"write path", &d.Write, func(p string) (string, error) { return sandbox.CheckPath(home, p, s.home) }},
		{"host", &d.Hosts, sandbox.CheckHost},
	} {
		clean := []string{}
		for _, it := range cleanNames(*f.items) {
			it, err := f.check(it)
			if err != nil {
				return SandboxSettings{}, fmt.Errorf("%s: %v: %w", f.kind, err, ErrInvalid)
			}
			if !slices.Contains(clean, it) {
				clean = append(clean, it)
			}
		}
		*f.items = clean
	}
	var cols [3]string
	for i, items := range [][]string{d.Read, d.Write, d.Hosts} {
		b, err := json.Marshal(items)
		if err != nil {
			return SandboxSettings{}, err
		}
		cols[i] = string(b)
	}
	tx, err := s.beginWrite()
	if err != nil {
		return SandboxSettings{}, err
	}
	defer tx.rollback()
	if d.PlotID != "" {
		ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, d.PlotID)
		if err != nil {
			return SandboxSettings{}, err
		}
		if !ok {
			return SandboxSettings{}, fmt.Errorf("plot %q: %w", d.PlotID, ErrNotFound)
		}
	}
	if err := tx.exec(`INSERT INTO sandbox_settings(scope, read_paths, write_paths, hosts, updated_at) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(scope) DO UPDATE SET read_paths = excluded.read_paths, write_paths = excluded.write_paths, hosts = excluded.hosts,
  updated_at = excluded.updated_at`,
		d.PlotID, cols[0], cols[1], cols[2], time.Now().UnixMilli()); err != nil {
		return SandboxSettings{}, err
	}
	return d, tx.commit()
}
