package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"slices"
	"time"
)

func tm(ms int64) time.Time { return time.UnixMilli(ms) }

func loadPlot(q queryer, id string) (Plot, error) {
	p := Plot{ID: id, Links: []Link{}, Repos: []Repo{}, Versions: map[string]int64{}}
	var created int64
	err := q.QueryRowContext(context.Background(), `SELECT name, what, why, where_it_stands, created_at, archived FROM plots WHERE id = ?`, id).
		Scan(&p.Name, &p.What, &p.Why, &p.Where, &created, &p.Archived)
	if errors.Is(err, sql.ErrNoRows) {
		return Plot{}, fmt.Errorf("plot %q: %w", id, ErrNotFound)
	}
	if err != nil {
		return Plot{}, err
	}
	p.CreatedAt = tm(created)

	if err := scanRows(q, func(rows *sql.Rows) error {
		var l Link
		if err := rows.Scan(&l.ID, &l.Position, &l.Label, &l.Target, &l.Note); err != nil {
			return err
		}
		p.Links = append(p.Links, l)
		return nil
	}, `SELECT id, position, label, target, note FROM links WHERE plot_id = ? ORDER BY position, id`, id); err != nil {
		return Plot{}, err
	}

	if err := scanRows(q, func(rows *sql.Rows) error {
		var r Repo
		var copyJSON string
		if err := rows.Scan(&r.ID, &r.Path, &r.Note, &r.Main, &r.Setup, &copyJSON); err != nil {
			return err
		}
		r.Copy = decodeCopy(copyJSON)
		p.Repos = append(p.Repos, r)
		return nil
	}, `SELECT r.id, r.path, r.note, r.is_main, COALESCE(s.setup, ''), COALESCE(s.copy, '[]')
FROM repos r LEFT JOIN repo_settings s ON s.path = r.path WHERE r.plot_id = ? ORDER BY r.is_main DESC, r.path`, id); err != nil {
		return Plot{}, err
	}

	all := map[string]int64{}
	if err := scanRows(q, func(rows *sql.Rows) error {
		var item string
		var v int64
		if err := rows.Scan(&item, &v); err != nil {
			return err
		}
		all[item] = v
		p.Revision = max(p.Revision, v)
		return nil
	}, `SELECT item, MAX(change_id) FROM change_entries WHERE plot_id = ? GROUP BY item`, id); err != nil {
		return Plot{}, err
	}
	for _, item := range []string{ItemName, ItemWhat, ItemWhy, ItemWhere} {
		p.Versions[item] = all[item]
	}
	for i := range p.Links {
		it := LinkItem(p.Links[i].ID)
		p.Links[i].Version = all[it]
		p.Versions[it] = all[it]
	}
	for i := range p.Repos {
		it := RepoItem(p.Repos[i].ID)
		p.Repos[i].Version = all[it]
		p.Versions[it] = all[it]
	}
	return p, nil
}

// GetPlot returns a plot with the version of each item. It returns an error
// that wraps [ErrNotFound] for an unknown ID.
func (s *Store) GetPlot(id string) (Plot, error) {
	var p Plot
	err := s.readTx(func(q queryer) (err error) {
		p, err = loadPlot(q, id)
		return err
	})
	return p, err
}

// ListPlots returns every plot in the stored order, archived plots too. Use
// [FilterPlots] to split them.
func (s *Store) ListPlots() ([]PlotSummary, error) {
	out := []PlotSummary{}
	err := s.readTx(func(q queryer) error {
		return scanRows(q, func(rows *sql.Rows) error {
			var ps PlotSummary
			var created int64
			if err := rows.Scan(&ps.ID, &ps.Name, &ps.What, &created, &ps.Archived); err != nil {
				return err
			}
			ps.CreatedAt = tm(created)
			out = append(out, ps)
			return nil
		}, `SELECT p.id, p.name, p.what, p.created_at, p.archived FROM plot_order o JOIN plots p ON p.id = o.plot_id ORDER BY o.position`)
	})
	return out, err
}

// CreatePlot makes a plot as one change. The new plot goes at the end of the
// plot order, and its folder under plots/ is created. Every brief item starts
// at the version of this change.
func (s *Store) CreatePlot(in PlotInput, actor Actor) (*Result, error) {
	if err := validateName(in.Name); err != nil {
		return nil, err
	}
	w, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer w.rollback()

	id, err := newID(func(id string) (bool, error) { return exists(w.conn, `SELECT 1 FROM plots WHERE id = ?`, id) })
	if err != nil {
		return nil, err
	}
	if err := w.exec(`INSERT INTO plots(id, name, what, why, where_it_stands, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		id, in.Name, in.What, in.Why, in.Where, time.Now().UnixMilli()); err != nil {
		return nil, err
	}
	if err := w.exec(`INSERT INTO plot_order(plot_id) VALUES (?)`, id); err != nil {
		return nil, err
	}
	a := &applier{w: w, plotID: id}
	for _, kv := range [][2]string{{ItemName, in.Name}, {ItemWhat, in.What}, {ItemWhy, in.Why}, {ItemWhere, in.Where}} {
		a.rec.set(kv[0], "value", nil, S(kv[1]))
	}
	for _, l := range in.Links {
		if err := a.apply(Edit{Op: OpAddLink, Label: S(l.Label), Target: S(l.Target), Note: S(l.Note)}); err != nil {
			return nil, err
		}
	}
	for _, r := range in.Repos {
		if err := a.apply(Edit{Op: OpAddRepo, Path: S(r.Path), Note: S(r.Note)}); err != nil {
			return nil, err
		}
	}
	return s.finish(a, actor)
}

func exists(q queryer, query string, args ...any) (bool, error) {
	var one int
	err := q.QueryRowContext(context.Background(), query, args...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// finish writes the change row and its entries, loads the plot, and commits.
func (s *Store) finish(a *applier, actor Actor) (*Result, error) {
	if err := a.ensureMain(); err != nil {
		return nil, err
	}
	entries := a.rec.entries()
	res := &Result{Added: a.added}
	if len(entries) > 0 {
		r, err := a.w.conn.ExecContext(context.Background(),
			`INSERT INTO changes(plot_id, at, actor_kind, session_id, loam_started, undo_of) VALUES (?, ?, ?, ?, ?, ?)`,
			a.plotID, time.Now().UnixMilli(), string(actor.Kind), actor.SessionID, actor.LoamStarted, undoOfArg(a.undoOf))
		if err != nil {
			return nil, err
		}
		if res.ChangeID, err = r.LastInsertId(); err != nil {
			return nil, err
		}
		for _, e := range entries {
			if err := a.w.exec(`INSERT INTO change_entries(change_id, plot_id, item, field, old_value, new_value) VALUES (?, ?, ?, ?, ?, ?)`,
				res.ChangeID, a.plotID, e.Item, e.Field, e.Old, e.New); err != nil {
				return nil, err
			}
		}
	}
	p, err := loadPlot(a.w.conn, a.plotID)
	if err != nil {
		return nil, err
	}
	res.Plot = p
	if n := BriefWords(p.What, p.Why, p.Where); n > BriefWordLimit {
		res.Warnings = append(res.Warnings, fmt.Sprintf("The brief has %d words. The soft limit is %d words. Shorten it.", n, BriefWordLimit))
	}
	if err := a.w.commit(); err != nil {
		return nil, err
	}
	// The plot folder is made after the commit. A failure here is not a store error.
	_ = os.MkdirAll(s.PlotDir(a.plotID), 0o755)
	return res, nil
}

// MovePlot puts a plot at a 1-based position in the plot order. The plots
// after it move down by one. A move writes no change log entry, because the
// order belongs to you and not to a plot. A position outside 1 to the plot
// count wraps [ErrInvalid]. An unknown plot wraps [ErrNotFound].
func (s *Store) MovePlot(id string, position int) error {
	w, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer w.rollback()

	ids, err := queryIDs(w.conn, `SELECT plot_id FROM plot_order ORDER BY position`)
	if err != nil {
		return err
	}
	from := slices.Index(ids, id)
	if from < 0 {
		return fmt.Errorf("plot %q: %w", id, ErrNotFound)
	}
	if position < 1 || position > len(ids) {
		return fmt.Errorf("position %d: choose a number from 1 to %d: %w", position, len(ids), ErrInvalid)
	}
	if from == position-1 {
		return nil
	}
	ids = slices.Insert(slices.Delete(ids, from, from+1), position-1, id)
	if err := w.exec(`DELETE FROM plot_order`); err != nil {
		return err
	}
	for _, pid := range ids {
		if err := w.exec(`INSERT INTO plot_order(plot_id) VALUES (?)`, pid); err != nil {
			return err
		}
	}
	return w.commit()
}

// undoOfArg turns an undone change ID into a SQL value: NULL for 0.
func undoOfArg(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}
