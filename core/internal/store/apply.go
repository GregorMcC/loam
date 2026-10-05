package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/GregorMcC/loam/core/internal/linkkind"
)

// recorder collects the entries of one change. A second edit of the same
// field keeps the first old value. An entry whose old and new value are equal
// is dropped, so an edit that changes nothing leaves no entry.
type recorder struct {
	order []Entry
	index map[[2]string]int
}

func (r *recorder) set(item, field string, old, new *string) {
	k := [2]string{item, field}
	if i, ok := r.index[k]; ok {
		r.order[i].New = new
		return
	}
	if r.index == nil {
		r.index = map[[2]string]int{}
	}
	r.index[k] = len(r.order)
	r.order = append(r.order, Entry{Item: item, Field: field, Old: old, New: new})
}

func (r *recorder) entries() []Entry {
	var out []Entry
	for _, e := range r.order {
		if (e.Old == nil) == (e.New == nil) && (e.Old == nil || *e.Old == *e.New) {
			continue
		}
		out = append(out, e)
	}
	return out
}

type applier struct {
	w      *writeTx
	plotID string
	rec    recorder
	added  []string
	undoOf int64 // set by Undo: the change this one reverts
}

func validateName(name string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("the plot name is empty: %w", ErrInvalid)
	}
	return nil
}

// Apply makes one change to a plot, in one transaction. It checks the
// expectations first. If any item changed since the caller read it, Apply
// returns a [*StaleError] with the current values and writes nothing. If the
// edits change nothing, Apply writes nothing and returns a Result with
// ChangeID 0. If the schema is newer than this binary, Apply returns
// [ErrSchemaNewer].
//
// Main repo rules: the first repo added becomes the main repo. If a change
// removes the main repo and one repo remains, that repo becomes the main
// repo. If more than one remains, Apply fails with [ErrNeedMainRepo] unless
// the same change has an [OpSetMainRepo] edit.
func (s *Store) Apply(c Change) (*Result, error) {
	w, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer w.rollback()

	cur, err := loadPlot(w.conn, c.PlotID)
	if err != nil {
		return nil, err
	}
	if err := checkExpect(w.conn, cur, c.Expect); err != nil {
		return nil, err
	}
	a := &applier{w: w, plotID: c.PlotID}
	for _, e := range c.Edits {
		if err := a.apply(e); err != nil {
			return nil, err
		}
	}
	return s.finish(a, c.Actor)
}

func checkExpect(q queryer, cur Plot, expect map[string]int64) error {
	var stale []StaleItem
	for item, want := range expect {
		got, ok := cur.Versions[item]
		if ok && got == want {
			continue
		}
		si := StaleItem{Item: item, Expected: want, Current: got, Exists: ok}
		if !ok {
			// The item is gone, or never existed. Report the last change that touched it.
			_ = q.QueryRowContext(context.Background(),
				`SELECT COALESCE(MAX(change_id), 0) FROM change_entries WHERE plot_id = ? AND item = ?`, cur.ID, item).Scan(&si.Current)
		}
		switch {
		case item == ItemName:
			si.Value = cur.Name
		case item == ItemWhat:
			si.Value = cur.What
		case item == ItemWhy:
			si.Value = cur.Why
		case item == ItemWhere:
			si.Value = cur.Where
		case strings.HasPrefix(item, "link:"):
			for i := range cur.Links {
				if LinkItem(cur.Links[i].ID) == item {
					si.Link = &cur.Links[i]
				}
			}
		case strings.HasPrefix(item, "repo:"):
			for i := range cur.Repos {
				if RepoItem(cur.Repos[i].ID) == item {
					si.Repo = &cur.Repos[i]
				}
			}
		}
		stale = append(stale, si)
	}
	if len(stale) == 0 {
		return nil
	}
	// Map order is random. Sort so the error reads the same each time.
	slices.SortFunc(stale, func(a, b StaleItem) int { return strings.Compare(a.Item, b.Item) })
	return &StaleError{PlotID: cur.ID, Items: stale}
}

func idOf(item, prefix string) (string, error) {
	id, ok := strings.CutPrefix(item, prefix)
	if !ok || id == "" {
		return "", fmt.Errorf("item %q is not a %s item: %w", item, strings.TrimSuffix(prefix, ":"), ErrInvalid)
	}
	return id, nil
}

func boolStr(b bool) *string {
	if b {
		return S("1")
	}
	return S("0")
}

func (a *applier) apply(e Edit) error {
	switch e.Op {
	case OpSet:
		return a.set(e)
	case OpAddLink:
		return a.addLink(e)
	case OpUpdateLink:
		return a.updateLink(e)
	case OpRemoveLink:
		return a.removeLink(e)
	case OpAddRepo:
		return a.addRepo(e)
	case OpUpdateRepo:
		return a.updateRepo(e)
	case OpRemoveRepo:
		return a.removeRepo(e)
	case OpSetMainRepo:
		return a.setMainRepo(e)
	}
	return fmt.Errorf("unknown edit %q: %w", e.Op, ErrInvalid)
}

func (a *applier) set(e Edit) error {
	col := map[string]string{ItemName: "name", ItemWhat: "what", ItemWhy: "why", ItemWhere: "where_it_stands"}[e.Item]
	if col == "" {
		return fmt.Errorf("cannot set item %q: %w", e.Item, ErrInvalid)
	}
	if e.Item == ItemName {
		if err := validateName(e.Value); err != nil {
			return err
		}
	}
	var old string
	if err := a.w.conn.QueryRowContext(context.Background(), `SELECT `+col+` FROM plots WHERE id = ?`, a.plotID).Scan(&old); err != nil {
		return err
	}
	if err := a.w.exec(`UPDATE plots SET `+col+` = ? WHERE id = ?`, e.Value, a.plotID); err != nil {
		return err
	}
	a.rec.set(e.Item, "value", S(old), S(e.Value))
	return nil
}

func (a *applier) getLink(item string) (Link, error) {
	id, err := idOf(item, "link:")
	if err != nil {
		return Link{}, err
	}
	l := Link{ID: id}
	err = a.w.conn.QueryRowContext(context.Background(), `SELECT position, label, target, note FROM links WHERE id = ? AND plot_id = ?`, id, a.plotID).
		Scan(&l.Position, &l.Label, &l.Target, &l.Note)
	if errors.Is(err, sql.ErrNoRows) {
		return Link{}, fmt.Errorf("link %q: %w", id, ErrNotFound)
	}
	return l, err
}

func (a *applier) addLink(e Edit) error {
	if e.Target == nil || strings.TrimSpace(*e.Target) == "" {
		return fmt.Errorf("a link needs a target: %w", ErrInvalid)
	}
	// A link with no label takes one from its target, such as the file name or the issue ID.
	if e.Label == nil || strings.TrimSpace(*e.Label) == "" {
		e.Label = S(linkkind.Label(*e.Target))
	}
	note := ""
	if e.Note != nil {
		note = *e.Note
	}
	id, err := newID(func(id string) (bool, error) { return exists(a.w.conn, `SELECT 1 FROM links WHERE id = ?`, id) })
	if err != nil {
		return err
	}
	var pos int
	if err := a.w.conn.QueryRowContext(context.Background(), `SELECT COALESCE(MAX(position), 0) + 1 FROM links WHERE plot_id = ?`, a.plotID).Scan(&pos); err != nil {
		return err
	}
	if err := a.w.exec(`INSERT INTO links(id, plot_id, position, label, target, note) VALUES (?, ?, ?, ?, ?, ?)`, id, a.plotID, pos, *e.Label, *e.Target, note); err != nil {
		return err
	}
	item := LinkItem(id)
	a.rec.set(item, "label", nil, e.Label)
	a.rec.set(item, "target", nil, e.Target)
	a.rec.set(item, "note", nil, S(note))
	a.rec.set(item, "position", nil, S(fmt.Sprint(pos)))
	a.added = append(a.added, item)
	return nil
}

func (a *applier) updateLink(e Edit) error {
	l, err := a.getLink(e.Item)
	if err != nil {
		return err
	}
	for _, f := range []struct {
		name    string
		old     string
		new     *string
		require bool
	}{{"label", l.Label, e.Label, true}, {"target", l.Target, e.Target, true}, {"note", l.Note, e.Note, false}} {
		if f.new == nil {
			continue
		}
		if f.require && strings.TrimSpace(*f.new) == "" {
			return fmt.Errorf("the link %s is empty: %w", f.name, ErrInvalid)
		}
		if err := a.w.exec(`UPDATE links SET `+f.name+` = ? WHERE id = ?`, *f.new, l.ID); err != nil {
			return err
		}
		a.rec.set(e.Item, f.name, S(f.old), f.new)
	}
	return nil
}

func (a *applier) removeLink(e Edit) error {
	l, err := a.getLink(e.Item)
	if err != nil {
		return err
	}
	if err := a.w.exec(`DELETE FROM links WHERE id = ?`, l.ID); err != nil {
		return err
	}
	a.rec.set(e.Item, "label", S(l.Label), nil)
	a.rec.set(e.Item, "target", S(l.Target), nil)
	a.rec.set(e.Item, "note", S(l.Note), nil)
	a.rec.set(e.Item, "position", S(fmt.Sprint(l.Position)), nil)
	return nil
}

func (a *applier) getRepo(item string) (Repo, error) {
	id, err := idOf(item, "repo:")
	if err != nil {
		return Repo{}, err
	}
	r := Repo{ID: id}
	err = a.w.conn.QueryRowContext(context.Background(), `SELECT path, note, is_main FROM repos WHERE id = ? AND plot_id = ?`, id, a.plotID).
		Scan(&r.Path, &r.Note, &r.Main)
	if errors.Is(err, sql.ErrNoRows) {
		return Repo{}, fmt.Errorf("repo %q: %w", id, ErrNotFound)
	}
	return r, err
}

func (a *applier) addRepo(e Edit) error {
	if e.Path == nil || !filepath.IsAbs(*e.Path) {
		return fmt.Errorf("a repo path must be absolute: %w", ErrInvalid)
	}
	path := filepath.Clean(*e.Path)
	note := ""
	if e.Note != nil {
		note = *e.Note
	}
	dup, err := exists(a.w.conn, `SELECT 1 FROM repos WHERE plot_id = ? AND path = ?`, a.plotID, path)
	if err != nil {
		return err
	}
	if dup {
		return fmt.Errorf("the plot already holds repo %s: %w", path, ErrDuplicate)
	}
	id, err := newID(func(id string) (bool, error) { return exists(a.w.conn, `SELECT 1 FROM repos WHERE id = ?`, id) })
	if err != nil {
		return err
	}
	hasMain, err := exists(a.w.conn, `SELECT 1 FROM repos WHERE plot_id = ? AND is_main = 1`, a.plotID)
	if err != nil {
		return err
	}
	if err := a.w.exec(`INSERT INTO repos(id, plot_id, path, note, is_main) VALUES (?, ?, ?, ?, ?)`, id, a.plotID, path, note, !hasMain); err != nil {
		return err
	}
	item := RepoItem(id)
	a.rec.set(item, "path", nil, S(path))
	a.rec.set(item, "note", nil, S(note))
	a.rec.set(item, "main", nil, boolStr(!hasMain))
	a.added = append(a.added, item)
	return nil
}

func (a *applier) updateRepo(e Edit) error {
	r, err := a.getRepo(e.Item)
	if err != nil {
		return err
	}
	if e.Note == nil {
		return nil
	}
	if err := a.w.exec(`UPDATE repos SET note = ? WHERE id = ?`, *e.Note, r.ID); err != nil {
		return err
	}
	a.rec.set(e.Item, "note", S(r.Note), e.Note)
	return nil
}

func (a *applier) removeRepo(e Edit) error {
	r, err := a.getRepo(e.Item)
	if err != nil {
		return err
	}
	var n int
	if err := a.w.conn.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM worktrees WHERE plot_id = ? AND repo_path = ?`, a.plotID, r.Path).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("%s has %d worktree(s) in this plot. Remove them with loam worktree rm, then remove the repo: %w", r.Path, n, ErrHasWorktrees)
	}
	if err := a.w.exec(`DELETE FROM repos WHERE id = ?`, r.ID); err != nil {
		return err
	}
	a.rec.set(e.Item, "path", S(r.Path), nil)
	a.rec.set(e.Item, "note", S(r.Note), nil)
	a.rec.set(e.Item, "main", boolStr(r.Main), nil)
	return nil
}

func (a *applier) setMainRepo(e Edit) error {
	r, err := a.getRepo(e.Item)
	if err != nil {
		return err
	}
	if r.Main {
		return nil
	}
	var oldID string
	err = a.w.conn.QueryRowContext(context.Background(), `SELECT id FROM repos WHERE plot_id = ? AND is_main = 1`, a.plotID).Scan(&oldID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if oldID != "" {
		if err := a.w.exec(`UPDATE repos SET is_main = 0 WHERE id = ?`, oldID); err != nil {
			return err
		}
		a.rec.set(RepoItem(oldID), "main", S("1"), S("0"))
	}
	if err := a.w.exec(`UPDATE repos SET is_main = 1 WHERE id = ?`, r.ID); err != nil {
		return err
	}
	a.rec.set(e.Item, "main", S("0"), S("1"))
	return nil
}

// ensureMain applies the end-of-change rule: a plot with repos has exactly
// one main repo.
func (a *applier) ensureMain() error {
	ids, err := queryIDs(a.w.conn, `SELECT id FROM repos WHERE plot_id = ? AND is_main = 0`, a.plotID)
	if err != nil {
		return err
	}
	hasMain, err := exists(a.w.conn, `SELECT 1 FROM repos WHERE plot_id = ? AND is_main = 1`, a.plotID)
	if err != nil || hasMain || len(ids) == 0 {
		return err
	}
	if len(ids) > 1 {
		return ErrNeedMainRepo
	}
	if err := a.w.exec(`UPDATE repos SET is_main = 1 WHERE id = ?`, ids[0]); err != nil {
		return err
	}
	a.rec.set(RepoItem(ids[0]), "main", S("0"), S("1"))
	return nil
}
