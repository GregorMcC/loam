package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// ProgramVersion is what loam version prints. The cli package sets it when the
// program starts. It is empty in a test binary, which is a dev build.
var ProgramVersion = ""

// releaseVersion is the form of a release tag, the one that scripts/release.sh
// accepts. git describe gives a build between tags a longer form, and Go build
// info gives a pseudo version. Neither is a release.
var releaseVersion = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

// ErrDevMigrate means a dev build refused to migrate the store in the default
// home. Migrations go forward only, so the installed release could not write
// to the store after it.
var ErrDevMigrate = errors.New("a dev build does not migrate the Loam store in the default home")

// allowDevMigrate is the environment variable that lets a dev build migrate
// the store in the default home.
const allowDevMigrate = "LOAM_ALLOW_DEV_MIGRATE"

// keepCopies is how many copies of the store Loam keeps beside it.
const keepCopies = 3

// staleCopyAge is the age at which an unfinished copy belongs to no running
// migration. Only a program that stopped during a copy leaves one.
const staleCopyAge = time.Hour

const copyTempMarker = ".tmp"

// copyName matches a finished copy of the store and holds its schema version.
var copyName = regexp.MustCompile(`^loam\.db\.v([0-9]+)\.bak$`)

// prepareMigration runs before Loam migrates a store at schema v, and outside
// the write transaction, because VACUUM INTO cannot run in one.
func (s *Store) prepareMigration(v int) error {
	if err := s.checkDevMigrate(v); err != nil {
		return err
	}
	file, err := s.copyStore(v)
	if err != nil {
		return fmt.Errorf("did not migrate the Loam store from schema %d to schema %d: write the copy %s: %w", v, SchemaVersion, file, err)
	}
	s.pruneCopies()
	return nil
}

func (s *Store) checkDevMigrate(v int) error {
	if releaseVersion.MatchString(ProgramVersion) || os.Getenv(allowDevMigrate) == "1" || !isDefaultHome(s.home) {
		return nil
	}
	return fmt.Errorf("%w: the store has schema %d and this program has schema %d. "+
		"After a migration, the installed Loam could not write to the store. "+
		"Set LOAM_HOME to another folder, or set %s=1 to migrate this store",
		ErrDevMigrate, v, SchemaVersion, allowDevMigrate)
}

// isDefaultHome reports whether home is the folder ~/.loam. It compares the
// folders, not the variable. A run session has LOAM_HOME set to the home of
// its store, so a variable that names ~/.loam does not move the home away.
func isDefaultHome(home string) bool {
	def, err := defaultHome()
	if err != nil {
		return false
	}
	got, err := os.Stat(home)
	if err != nil {
		return false
	}
	want, err := os.Stat(def)
	if err != nil {
		return false
	}
	return os.SameFile(got, want)
}

// copyStore writes the store at schema v to loam.db.v<v>.bak and returns that
// path. VACUUM INTO reads through SQLite, so the copy holds what the WAL
// holds. The copy appears only when it is complete, and it replaces an earlier
// copy of the same schema.
func (s *Store) copyStore(v int) (string, error) {
	file := filepath.Join(s.home, fmt.Sprintf("loam.db.v%d.bak", v))
	// CreateTemp makes the file private to the user, and SQLite keeps the mode.
	tmp, err := os.CreateTemp(s.home, filepath.Base(file)+copyTempMarker+"*")
	if err != nil {
		return file, err
	}
	name := tmp.Name()
	defer os.Remove(name) // after the rename, the file is gone already
	if err := tmp.Close(); err != nil {
		return file, err
	}
	if _, err := s.db.ExecContext(context.Background(), `VACUUM INTO ?`, name); err != nil {
		return file, err
	}
	return file, os.Rename(name, file)
}

// pruneCopies removes all but the newest copies, and unfinished copies that a
// stopped program left. A copy that Loam cannot remove does not stop the
// migration: the copy of this migration is in place.
func (s *Store) pruneCopies() {
	entries, err := os.ReadDir(s.home)
	if err != nil {
		return
	}
	type found struct {
		name    string
		version int
		at      time.Time
	}
	var copies []found
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			continue
		}
		if base, _, unfinished := strings.Cut(e.Name(), copyTempMarker); unfinished && copyName.MatchString(base) {
			if time.Since(info.ModTime()) > staleCopyAge {
				_ = os.Remove(filepath.Join(s.home, e.Name()))
			}
			continue
		}
		m := copyName.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		if v, err := strconv.Atoi(m[1]); err == nil {
			copies = append(copies, found{e.Name(), v, info.ModTime()})
		}
	}
	// Newest is by time, not by schema. A store that you restored from an old
	// copy makes a copy of a low schema, and that copy is the one to keep.
	slices.SortFunc(copies, func(a, b found) int {
		if c := b.at.Compare(a.at); c != 0 {
			return c
		}
		return b.version - a.version
	})
	for _, c := range copies[min(keepCopies, len(copies)):] {
		_ = os.Remove(filepath.Join(s.home, c.name))
	}
}
