package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// UndoClashError is the error of an undo that meets later changes to the same
// items. Nothing is written. Call [Store.Undo] again with overwrite to write
// anyway.
type UndoClashError struct {
	ChangeID int64  `json:"change_id"`
	PlotID   string `json:"plot_id"`
	// Later holds the later changes that touched the same items, oldest first.
	Later []ChangeRecord `json:"later_changes"`
	// Writes is what the undo would write. Old is the current value and New is
	// the value the undo sets. A nil value means the item does not exist.
	Writes []Entry `json:"undo_would_write"`
}

func (e *UndoClashError) Error() string {
	ids := make([]string, len(e.Later))
	for i, c := range e.Later {
		ids[i] = fmt.Sprint(c.ID)
	}
	return fmt.Sprintf("undo of change %d clashes with later change %s to the same items", e.ChangeID, strings.Join(ids, ", "))
}

// loadChanges reads changes with their entries. rest is the SQL after WHERE
// on the changes table: a condition, and an order and a limit if needed.
func loadChanges(q queryer, rest string, args ...any) ([]ChangeRecord, error) {
	out := []ChangeRecord{}
	if err := scanRows(q, func(rows *sql.Rows) error {
		var c ChangeRecord
		var at int64
		var kind string
		if err := rows.Scan(&c.ID, &c.PlotID, &at, &kind, &c.Actor.SessionID, &c.Actor.LoamStarted, &c.UndoOf); err != nil {
			return err
		}
		c.At, c.Actor.Kind, c.Entries = tm(at), ActorKind(kind), []Entry{}
		out = append(out, c)
		return nil
	}, `SELECT id, plot_id, at, actor_kind, session_id, loam_started, undo_of FROM changes WHERE `+rest, args...); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}
	// One query reads the entries of every change, so a long log costs two
	// queries and not one per change.
	at := make(map[int64]int, len(out))
	for i, c := range out {
		at[c.ID] = i
	}
	if err := scanRows(q, func(rows *sql.Rows) error {
		var id int64
		var e Entry
		if err := rows.Scan(&id, &e.Item, &e.Field, &e.Old, &e.New); err != nil {
			return err
		}
		if i, ok := at[id]; ok {
			out[i].Entries = append(out[i].Entries, e)
		}
		return nil
	}, `SELECT change_id, item, field, old_value, new_value FROM change_entries
WHERE change_id IN (SELECT id FROM changes WHERE `+rest+`) ORDER BY change_id, id`, args...); err != nil {
		return nil, err
	}
	return out, nil
}

// fieldValue returns the current value of one field, or nil if the item or
// field does not exist.
func fieldValue(p Plot, item, field string) *string {
	switch item {
	case ItemName:
		return S(p.Name)
	case ItemWhat:
		return S(p.What)
	case ItemWhy:
		return S(p.Why)
	case ItemWhere:
		return S(p.Where)
	}
	for _, l := range p.Links {
		if LinkItem(l.ID) != item {
			continue
		}
		switch field {
		case "label":
			return S(l.Label)
		case "target":
			return S(l.Target)
		case "note":
			return S(l.Note)
		case "position":
			return S(fmt.Sprint(l.Position))
		}
	}
	for _, r := range p.Repos {
		if RepoItem(r.ID) != item {
			continue
		}
		switch field {
		case "path":
			return S(r.Path)
		case "note":
			return S(r.Note)
		case "main":
			return boolStr(r.Main)
		}
	}
	return nil
}

func isBriefItem(item string) bool {
	return item == ItemName || item == ItemWhat || item == ItemWhy || item == ItemWhere
}

func same(a, b *string) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }

// Undo writes the old values of a change back, as a new change by actor. The
// change log keeps every entry.
//
// If a later change touched the same items, Undo writes nothing and returns
// an [*UndoClashError] with those changes, unless overwrite is true. An undo
// of a link or repo add removes the item. An undo of a remove puts the item
// back with its ID and position. Plot creation cannot be undone: Undo returns
// [ErrInvalid]. An unknown change returns [ErrNotFound]. An undo that changes
// nothing writes nothing and returns ChangeID 0.
func (s *Store) Undo(changeID int64, actor Actor, overwrite bool) (*Result, error) {
	w, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer w.rollback()

	cs, err := loadChanges(w.conn, `id = ?`, changeID)
	if err != nil {
		return nil, err
	}
	if len(cs) == 0 {
		return nil, fmt.Errorf("change %d: %w", changeID, ErrNotFound)
	}
	ch := cs[0]
	var items []string
	seen := map[string]bool{}
	for _, e := range ch.Entries {
		if isBriefItem(e.Item) && (e.Old == nil || e.New == nil) {
			return nil, fmt.Errorf("change %d made the plot, and a plot cannot be undone: %w", changeID, ErrInvalid)
		}
		if !seen[e.Item] {
			seen[e.Item] = true
			items = append(items, e.Item)
		}
	}
	cur, err := loadPlot(w.conn, ch.PlotID)
	if err != nil {
		return nil, err
	}
	if !overwrite {
		if err := s.checkClash(w, ch, cur, items); err != nil {
			return nil, err
		}
	}
	a := &applier{w: w, plotID: ch.PlotID, undoOf: ch.ID}
	for _, item := range items {
		var es []Entry
		for _, e := range ch.Entries {
			if e.Item == item {
				es = append(es, e)
			}
		}
		if err := a.undoItem(cur, item, es); err != nil {
			return nil, err
		}
	}
	return s.finish(a, actor)
}

func (s *Store) checkClash(w *writeTx, ch ChangeRecord, cur Plot, items []string) error {
	later, err := loadChanges(w.conn, `plot_id = ? AND id > ? ORDER BY id`, ch.PlotID, ch.ID)
	if err != nil {
		return err
	}
	in := map[string]bool{}
	for _, it := range items {
		in[it] = true
	}
	var hits []ChangeRecord
	for _, c := range later {
		for _, e := range c.Entries {
			if in[e.Item] {
				hits = append(hits, c)
				break
			}
		}
	}
	if len(hits) == 0 {
		return nil
	}
	ce := &UndoClashError{ChangeID: ch.ID, PlotID: ch.PlotID, Later: hits, Writes: []Entry{}}
	for _, e := range ch.Entries {
		now := fieldValue(cur, e.Item, e.Field)
		if !same(now, e.Old) {
			ce.Writes = append(ce.Writes, Entry{Item: e.Item, Field: e.Field, Old: now, New: e.Old})
		}
	}
	return ce
}

// undoItem puts one item back to the state before the change.
func (a *applier) undoItem(cur Plot, item string, es []Entry) error {
	if isBriefItem(item) {
		return a.set(Edit{Op: OpSet, Item: item, Value: *es[0].Old})
	}
	added := true   // the change made the item
	removed := true // the change removed the item
	old := map[string]*string{}
	for _, e := range es {
		if e.Old != nil {
			added = false
		}
		if e.New != nil {
			removed = false
		}
		old[e.Field] = e.Old
	}
	isLink := strings.HasPrefix(item, "link:")
	key := "path" // every repo has a path, and every link has a label
	if isLink {
		key = "label"
	}
	exists := fieldValue(cur, item, key) != nil
	switch {
	case added && !exists:
		return nil
	case !exists && !removed:
		// The change only edited fields and a later change removed the item.
		// There is nothing to put back.
		return nil
	case added && isLink:
		return a.removeLink(Edit{Item: item})
	case added:
		return a.undoRepoRemoval(item)
	case isLink && exists:
		return a.undoLinkFields(item, old)
	case isLink:
		return a.restoreLink(item, old)
	case exists:
		return a.undoRepoFields(item, old)
	}
	return a.restoreRepo(item, old)
}

func val(m map[string]*string, k string) string {
	if v := m[k]; v != nil {
		return *v
	}
	return ""
}

func (a *applier) undoLinkFields(item string, old map[string]*string) error {
	l, err := a.getLink(item)
	if err != nil {
		return err
	}
	e := Edit{Op: OpUpdateLink, Item: item}
	for f, dst := range map[string]**string{"label": &e.Label, "target": &e.Target, "note": &e.Note} {
		if v := old[f]; v != nil {
			*dst = v
		}
	}
	if err := a.updateLink(e); err != nil {
		return err
	}
	if v := old["position"]; v != nil && *v != fmt.Sprint(l.Position) {
		if err := a.w.exec(`UPDATE links SET position = ? WHERE id = ?`, *v, l.ID); err != nil {
			return err
		}
		a.rec.set(item, "position", S(fmt.Sprint(l.Position)), v)
	}
	return nil
}

func (a *applier) restoreLink(item string, old map[string]*string) error {
	id, err := idOf(item, "link:")
	if err != nil {
		return err
	}
	if err := a.w.exec(`INSERT INTO links(id, plot_id, position, label, target, note) VALUES (?, ?, ?, ?, ?, ?)`,
		id, a.plotID, val(old, "position"), val(old, "label"), val(old, "target"), val(old, "note")); err != nil {
		return err
	}
	for _, f := range []string{"label", "target", "note", "position"} {
		a.rec.set(item, f, nil, S(val(old, f)))
	}
	return nil
}

func (a *applier) setMain(id string) error {
	others, err := queryIDs(a.w.conn, `SELECT id FROM repos WHERE plot_id = ? AND is_main = 1 AND id <> ?`, a.plotID, id)
	if err != nil {
		return err
	}
	for _, o := range others {
		if err := a.w.exec(`UPDATE repos SET is_main = 0 WHERE id = ?`, o); err != nil {
			return err
		}
		a.rec.set(RepoItem(o), "main", S("1"), S("0"))
	}
	return a.w.exec(`UPDATE repos SET is_main = 1 WHERE id = ?`, id)
}

func (a *applier) undoRepoFields(item string, old map[string]*string) error {
	r, err := a.getRepo(item)
	if err != nil {
		return err
	}
	if v := old["note"]; v != nil && *v != r.Note {
		if err := a.w.exec(`UPDATE repos SET note = ? WHERE id = ?`, *v, r.ID); err != nil {
			return err
		}
		a.rec.set(item, "note", S(r.Note), v)
	}
	if v := old["path"]; v != nil && *v != r.Path {
		if err := a.w.exec(`UPDATE repos SET path = ? WHERE id = ?`, *v, r.ID); err != nil {
			return err
		}
		a.rec.set(item, "path", S(r.Path), v)
	}
	if v := old["main"]; v != nil && *v != *boolStr(r.Main) {
		if *v == "1" {
			if err := a.setMain(r.ID); err != nil {
				return err
			}
		} else if err := a.w.exec(`UPDATE repos SET is_main = 0 WHERE id = ?`, r.ID); err != nil {
			return err
		}
		a.rec.set(item, "main", boolStr(r.Main), v)
	}
	return nil
}

func (a *applier) restoreRepo(item string, old map[string]*string) error {
	id, err := idOf(item, "repo:")
	if err != nil {
		return err
	}
	path := val(old, "path")
	dup, err := exists(a.w.conn, `SELECT 1 FROM repos WHERE plot_id = ? AND path = ?`, a.plotID, path)
	if err != nil {
		return err
	}
	if dup {
		return fmt.Errorf("the plot already holds repo %s: %w", path, ErrDuplicate)
	}
	if err := a.w.exec(`INSERT INTO repos(id, plot_id, path, note, is_main) VALUES (?, ?, ?, ?, 0)`, id, a.plotID, path, val(old, "note")); err != nil {
		return err
	}
	if val(old, "main") == "1" {
		if err := a.setMain(id); err != nil {
			return err
		}
	}
	a.rec.set(item, "path", nil, S(path))
	a.rec.set(item, "note", nil, S(val(old, "note")))
	a.rec.set(item, "main", nil, boolStr(val(old, "main") == "1"))
	return nil
}

// undoRepoRemoval removes a repo that the undone change added. If it was the
// main repo, the oldest remaining repo becomes main.
func (a *applier) undoRepoRemoval(item string) error {
	r, err := a.getRepo(item)
	if err != nil {
		return err
	}
	if err := a.removeRepo(Edit{Item: item}); err != nil {
		return err
	}
	if !r.Main {
		return nil
	}
	var next string
	err = a.w.conn.QueryRowContext(context.Background(), `SELECT id FROM repos WHERE plot_id = ? ORDER BY rowid LIMIT 1`, a.plotID).Scan(&next)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := a.w.exec(`UPDATE repos SET is_main = 1 WHERE id = ?`, next); err != nil {
		return err
	}
	a.rec.set(RepoItem(next), "main", S("0"), S("1"))
	return nil
}
