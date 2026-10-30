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
	var d SandboxSettings
	err := s.readTx(func(q queryer) error {
		var err error
		d, err = loadSandboxSettings(q, plotID)
		return err
	})
	return d, err
}

func loadSandboxSettings(q queryer, plotID string) (SandboxSettings, error) {
	d := SandboxSettings{PlotID: plotID, Read: []string{}, Write: []string{}, Hosts: []string{}}
	var read, write, hosts string
	err := q.QueryRowContext(context.Background(), `SELECT read_paths, write_paths, hosts FROM sandbox_settings WHERE scope = ?`, plotID).
		Scan(&read, &write, &hosts)
	if errors.Is(err, sql.ErrNoRows) {
		return d, nil
	}
	if err != nil {
		return d, err
	}
	for _, f := range []struct {
		text string
		to   *[]string
	}{{read, &d.Read}, {write, &d.Write}, {hosts, &d.Hosts}} {
		if err := json.Unmarshal([]byte(f.text), f.to); err != nil {
			return d, err
		}
	}
	return d, nil
}

// SandboxChange names the lists of a scope to replace. A nil list stays as it
// is, and an empty list empties it.
type SandboxChange struct {
	Read, Write, Hosts *[]string
}

// UpdateSandboxSettings replaces the lists that c names and keeps the others,
// in one write transaction. So two updates of different lists both stay, even
// when they run at the same time. It trims each item of a named list, leaves
// out empty items and repeats, and checks each one with the rules of the
// sandbox package: a path that opens home or a host that is not a DNS name
// wraps [ErrInvalid], and nothing is stored. It does not check the lists that
// c leaves out, so a stored path that is refused today does not block a change
// of the hosts. A plot that does not exist wraps [ErrNotFound]. It returns the
// settings as stored.
func (s *Store) UpdateSandboxSettings(plotID string, c SandboxChange) (SandboxSettings, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return SandboxSettings{}, fmt.Errorf("the sandbox needs the home folder: %w", err)
	}
	checkPath := func(p string) (string, error) { return sandbox.CheckPath(home, p, s.home) }
	// Each named list is checked into out, and applied to to in the write.
	type change struct {
		kind  string
		items *[]string
		check func(string) (string, error)
		out   []string
	}
	changes := []*change{
		{kind: "read path", items: c.Read, check: checkPath},
		{kind: "write path", items: c.Write, check: checkPath},
		{kind: "host", items: c.Hosts, check: sandbox.CheckHost},
	}
	for _, f := range changes {
		if f.items == nil {
			continue
		}
		out := []string{}
		for _, it := range cleanNames(*f.items) {
			it, err := f.check(it)
			if err != nil {
				return SandboxSettings{}, fmt.Errorf("%s: %v: %w", f.kind, err, ErrInvalid)
			}
			if !slices.Contains(out, it) {
				out = append(out, it)
			}
		}
		f.out = out
	}
	tx, err := s.beginWrite()
	if err != nil {
		return SandboxSettings{}, err
	}
	defer tx.rollback()
	if plotID != "" {
		ok, err := exists(tx.conn, `SELECT 1 FROM plots WHERE id = ?`, plotID)
		if err != nil {
			return SandboxSettings{}, err
		}
		if !ok {
			return SandboxSettings{}, fmt.Errorf("plot %q: %w", plotID, ErrNotFound)
		}
	}
	d, err := loadSandboxSettings(tx.conn, plotID)
	if err != nil {
		return SandboxSettings{}, err
	}
	for i, to := range []*[]string{&d.Read, &d.Write, &d.Hosts} {
		if changes[i].items != nil {
			*to = changes[i].out
		}
	}
	var cols [3]string
	for i, items := range [][]string{d.Read, d.Write, d.Hosts} {
		b, err := json.Marshal(items)
		if err != nil {
			return SandboxSettings{}, err
		}
		cols[i] = string(b)
	}
	if err := tx.exec(`INSERT INTO sandbox_settings(scope, read_paths, write_paths, hosts, updated_at) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(scope) DO UPDATE SET read_paths = excluded.read_paths, write_paths = excluded.write_paths, hosts = excluded.hosts,
  updated_at = excluded.updated_at`,
		plotID, cols[0], cols[1], cols[2], time.Now().UnixMilli()); err != nil {
		return SandboxSettings{}, err
	}
	return d, tx.commit()
}

// SetSandboxSettings replaces all three lists of a scope, as
// [Store.UpdateSandboxSettings] does with the three lists named.
func (s *Store) SetSandboxSettings(d SandboxSettings) (SandboxSettings, error) {
	return s.UpdateSandboxSettings(d.PlotID, SandboxChange{Read: &d.Read, Write: &d.Write, Hosts: &d.Hosts})
}
