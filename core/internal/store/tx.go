package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
)

// writeTx is one BEGIN IMMEDIATE transaction on its own connection. A second
// writer waits on the busy timeout until this one ends.
type writeTx struct {
	conn *sql.Conn
	done bool
	// committed runs after a successful COMMIT.
	committed func()
}

func (s *Store) beginRaw() (*writeTx, error) {
	conn, err := s.db.Conn(context.Background())
	if err != nil {
		return nil, fmt.Errorf("open connection: %w", err)
	}
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		conn.Close()
		return nil, fmt.Errorf("begin write: %w", err)
	}
	return &writeTx{conn: conn, committed: s.markChanged}, nil
}

// beginWrite starts a write transaction. It fails with ErrSchemaNewer when
// another binary has moved the schema past this one, even after Open.
func (s *Store) beginWrite() (*writeTx, error) {
	w, err := s.beginRaw()
	if err != nil {
		return nil, err
	}
	v, err := s.readVersion(w.conn)
	if err != nil {
		w.rollback()
		return nil, fmt.Errorf("read schema version: %w", err)
	}
	if v > SchemaVersion {
		w.rollback()
		return nil, ErrSchemaNewer
	}
	return w, nil
}

func (w *writeTx) commit() error {
	w.done = true
	defer w.conn.Close()
	if _, err := w.conn.ExecContext(context.Background(), "COMMIT"); err != nil {
		w.conn.ExecContext(context.Background(), "ROLLBACK")
		return fmt.Errorf("commit: %w", err)
	}
	if w.committed != nil {
		w.committed()
	}
	return nil
}

func (w *writeTx) rollback() {
	if w.done {
		return
	}
	w.done = true
	w.conn.ExecContext(context.Background(), "ROLLBACK")
	w.conn.Close()
}

func (w *writeTx) exec(q string, args ...any) error {
	_, err := w.conn.ExecContext(context.Background(), q, args...)
	return err
}

// queryer is what both a read transaction and a write transaction offer.
type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// scanRows runs a query and calls scan for each row. It closes the rows and
// returns the first error, an error that ends the iteration included.
func scanRows(q queryer, scan func(*sql.Rows) error, query string, args ...any) error {
	rows, err := q.QueryContext(context.Background(), query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := scan(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}

// queryIDs returns the first column of each row of a query.
func queryIDs(q queryer, query string, args ...any) ([]string, error) {
	var ids []string
	err := scanRows(q, func(r *sql.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		ids = append(ids, id)
		return nil
	}, query, args...)
	return ids, err
}

// readTx runs fn in a read transaction. SQLite WAL gives it one snapshot, so
// the reads in fn agree with each other.
func (s *Store) readTx(fn func(q queryer) error) error {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	return fn(tx)
}

const idAlphabet = "abcdefghijklmnopqrstuvwxyz234567"

// IDLength is the length of a plot, link, or repo ID.
const IDLength = 10

// newID returns a 10-character lowercase base32 ID from crypto/rand. It
// retries while taken reports a clash.
func newID(taken func(id string) (bool, error)) (string, error) {
	for range 20 {
		var b [IDLength]byte
		if _, err := rand.Read(b[:]); err != nil {
			return "", fmt.Errorf("make ID: %w", err)
		}
		for i := range b {
			b[i] = idAlphabet[int(b[i])%len(idAlphabet)] // 256 is a multiple of 32: no bias
		}
		id := string(b[:])
		clash, err := taken(id)
		if err != nil {
			return "", err
		}
		if !clash {
			return id, nil
		}
	}
	return "", errors.New("make ID: too many clashes")
}
