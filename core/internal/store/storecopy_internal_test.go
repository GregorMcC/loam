package store

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// olderStore makes a store in home at schema v, with one plot, as a Loam of
// that schema made it. It returns the open store.
func olderStore(t *testing.T, home string, v int) *Store {
	t.Helper()
	all := migrations
	migrations, SchemaVersion = all[:v], v
	s, err := Open(home)
	migrations, SchemaVersion = all, len(all)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if _, err := s.db.Exec(`INSERT INTO plots(id, name, created_at) VALUES ('oldplotaab', 'Old', 1)`); err != nil {
		t.Fatal(err)
	}
	return s
}

// closedOlderStore is [olderStore] for a test that does not need the store open.
func closedOlderStore(t *testing.T, home string, v int) {
	t.Helper()
	olderStore(t, home, v).Close()
}

// setProgramVersion sets [ProgramVersion] for the test.
func setProgramVersion(t *testing.T, v string) {
	t.Helper()
	old := ProgramVersion
	ProgramVersion = v
	t.Cleanup(func() { ProgramVersion = old })
}

// useDefaultHome moves HOME to a temp folder and clears LOAM_HOME and the
// override, and returns the default home below it. So no test reaches the real
// ~/.loam.
func useDefaultHome(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("LOAM_HOME", "")
	t.Setenv(allowDevMigrate, "")
	home := filepath.Join(dir, ".loam")
	if got, err := Home(); err != nil || got != home {
		t.Fatalf("the default home is %q, %v, want %q", got, err, home)
	}
	return home
}

// rawStore opens a database file with no migration.
func rawStore(t *testing.T, file string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", file)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// storeState reads the schema version, the table definitions, and the plots.
func storeState(t *testing.T, file string) string {
	t.Helper()
	db := rawStore(t, file)
	defer db.Close()
	var v int
	if err := db.QueryRow(`SELECT version FROM schema_version`).Scan(&v); err != nil {
		t.Fatal(err)
	}
	state := fmt.Sprintf("schema %d", v)
	rows, err := db.Query(`SELECT COALESCE(sql, '') FROM sqlite_master UNION ALL SELECT id || name FROM plots ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		state += "\n" + line
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return state
}

func copyFile(home string, v int) string {
	return filepath.Join(home, fmt.Sprintf("loam.db.v%d.bak", v))
}

// copiesIn lists the names in home that hold ".bak".
func copiesIn(t *testing.T, home string) []string {
	t.Helper()
	entries, err := os.ReadDir(home)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".bak") {
			names = append(names, e.Name())
		}
	}
	return names
}

func versionOf(t *testing.T, file string) int {
	t.Helper()
	db := rawStore(t, file)
	defer db.Close()
	var v int
	if err := db.QueryRow(`SELECT version FROM schema_version`).Scan(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

// A migration leaves a copy at the old schema with the old data, and the data
// that is still in the WAL is in the copy.
func TestMigrationLeavesACopyOfTheOldStore(t *testing.T) {
	home := testutil.Home(t)
	old := SchemaVersion - 1
	s := olderStore(t, home, old)
	// The open store has not moved this row out of the WAL.
	if _, err := s.db.Exec(`INSERT INTO plots(id, name, created_at) VALUES ('walplotaab', 'In the WAL', 1)`); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(filepath.Join(home, "loam.db-wal")); err != nil || fi.Size() == 0 {
		t.Fatalf("no WAL to copy: %v, %v", fi, err)
	}

	migrated, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer migrated.Close()
	if v, err := migrated.readVersion(migrated.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}

	file := copyFile(home, old)
	if v := versionOf(t, file); v != old {
		t.Fatalf("the copy has schema %d, want %d", v, old)
	}
	db := rawStore(t, file)
	var names []string
	rows, err := db.Query(`SELECT name FROM plots ORDER BY name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		names = append(names, n)
	}
	if !slices.Equal(names, []string{"In the WAL", "Old"}) {
		t.Fatalf("the copy holds %q", names)
	}
	fi, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("the copy has mode %v, want 0600", fi.Mode().Perm())
	}
	if got := copiesIn(t, home); !slices.Equal(got, []string{filepath.Base(file)}) {
		t.Fatalf("files %q", got)
	}
}

func TestNoCopyWithoutAMigrationOfData(t *testing.T) {
	home := testutil.Home(t)
	s, err := Open(home) // a store with no schema yet
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if s, err = Open(home); err != nil { // a store at this schema
		t.Fatal(err)
	}
	s.Close()
	if got := copiesIn(t, home); len(got) != 0 {
		t.Fatalf("files %q", got)
	}
}

func TestFailedCopyStopsTheMigration(t *testing.T) {
	home := testutil.Home(t)
	old := SchemaVersion - 1
	closedOlderStore(t, home, old)
	// A full folder at the path of the copy makes the last step of the copy fail.
	file := copyFile(home, old)
	if err := os.MkdirAll(filepath.Join(file, "in-the-way"), 0o700); err != nil {
		t.Fatal(err)
	}
	before := storeState(t, filepath.Join(home, "loam.db"))

	s, err := Open(home)
	if err == nil {
		s.Close()
		t.Fatal("Open migrated with no copy")
	}
	for _, want := range []string{fmt.Sprintf("from schema %d to schema %d", old, SchemaVersion), file, "did not migrate"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the error %q does not say %q", err, want)
		}
	}
	if after := storeState(t, filepath.Join(home, "loam.db")); after != before {
		t.Fatalf("the store changed:\n%s", after)
	}
	if got := copiesIn(t, home); !slices.Equal(got, []string{filepath.Base(file)}) {
		t.Fatalf("an unfinished copy stayed: %q", got)
	}
}

// Migrating 5 times leaves the copies of the last 3 migrations.
func TestOnlyTheThreeNewestCopiesStay(t *testing.T) {
	home := testutil.Home(t)
	first := SchemaVersion - 6
	closedOlderStore(t, home, first)
	all := migrations
	defer func() { migrations, SchemaVersion = all, len(all) }()
	for v := first + 1; v <= first+5; v++ {
		migrations, SchemaVersion = all[:v], v
		s, err := Open(home)
		if err != nil {
			t.Fatal(err)
		}
		s.Close()
	}
	want := []string{
		filepath.Base(copyFile(home, first+2)),
		filepath.Base(copyFile(home, first+3)),
		filepath.Base(copyFile(home, first+4)),
	}
	slices.Sort(want) // the names sort as text, as copiesIn lists them
	if got := copiesIn(t, home); !slices.Equal(got, want) {
		t.Fatalf("copies %q, want %q", got, want)
	}
}

// After you restore an old copy, the next migration's copy has the lowest
// schema, and it is the newest. An unfinished copy goes only when it is old,
// because a new one can belong to another running program.
func TestPruneGoesByTimeAndLeavesOtherFiles(t *testing.T) {
	home := testutil.Home(t)
	old := SchemaVersion - 1
	closedOlderStore(t, home, old)
	long := time.Now().Add(-2 * time.Hour)
	write := func(name string, at time.Time) {
		t.Helper()
		file := filepath.Join(home, name)
		if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(file, at, at); err != nil {
			t.Fatal(err)
		}
	}
	higher := func(n int) string { return filepath.Base(copyFile(home, SchemaVersion+n)) }
	write(higher(1), long.Add(time.Minute))
	write(higher(2), long)
	write(higher(3), long.Add(2*time.Minute))
	staleTemp := higher(4) + copyTempMarker + "123"
	write(staleTemp, long)
	liveTemp := higher(5) + copyTempMarker + "456"
	write(liveTemp, time.Now())
	write("loam.db.vX.bak", long)
	write("mine.bak", long)

	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	want := []string{filepath.Base(copyFile(home, old)), higher(1), higher(3), liveTemp, "loam.db.vX.bak", "mine.bak"}
	slices.Sort(want)
	got := copiesIn(t, home)
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Fatalf("files %q, want %q", got, want)
	}
}

func TestACopyReplacesTheEarlierCopyOfItsSchema(t *testing.T) {
	home := testutil.Home(t)
	old := SchemaVersion - 1
	closedOlderStore(t, home, old)
	if err := os.WriteFile(copyFile(home, old), []byte("an earlier copy"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if v := versionOf(t, copyFile(home, old)); v != old {
		t.Fatalf("the copy has schema %d", v)
	}
}

func TestDevBuildRefusesAnOlderStoreInTheDefaultHome(t *testing.T) {
	for _, version := range []string{"", "dev", "v0.4.6-8-g46e28bbf", "v0.4.6-dirty", "46e28bbf", "v0.4.7-0.20261101000000-46e28bbf+dirty"} {
		t.Run(version, func(t *testing.T) {
			home := useDefaultHome(t)
			setProgramVersion(t, version)
			old := SchemaVersion - 1
			closedOlderStore(t, home, old)
			before := storeState(t, filepath.Join(home, "loam.db"))

			s, err := Open(home)
			if err == nil {
				s.Close()
			}
			if !errors.Is(err, ErrDevMigrate) {
				t.Fatalf("Open: %v", err)
			}
			for _, want := range []string{fmt.Sprintf("schema %d", old), fmt.Sprintf("schema %d", SchemaVersion), "LOAM_HOME", allowDevMigrate + "=1"} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("the error %q does not say %q", err, want)
				}
			}
			if after := storeState(t, filepath.Join(home, "loam.db")); after != before {
				t.Fatalf("the store changed:\n%s", after)
			}
			if got := copiesIn(t, home); len(got) != 0 {
				t.Fatalf("files %q", got)
			}
		})
	}
}

// A run session has LOAM_HOME set to its store, so a LOAM_HOME that names the
// default home, or a link to it, does not count as another home.
func TestDevBuildRefusesWhenLoamHomeNamesTheDefaultHome(t *testing.T) {
	home := useDefaultHome(t)
	setProgramVersion(t, "")
	closedOlderStore(t, home, SchemaVersion-1)
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(home, link); err != nil {
		t.Fatal(err)
	}
	for _, env := range []string{home, link} {
		t.Setenv("LOAM_HOME", env)
		got, err := Home()
		if err != nil {
			t.Fatal(err)
		}
		s, err := Open(got)
		if err == nil {
			s.Close()
		}
		if !errors.Is(err, ErrDevMigrate) {
			t.Fatalf("LOAM_HOME=%s: %v", env, err)
		}
	}
}

func TestDevBuildMigratesAStoreInAnotherHome(t *testing.T) {
	useDefaultHome(t)
	setProgramVersion(t, "")
	other := filepath.Join(t.TempDir(), "other")
	t.Setenv("LOAM_HOME", other)
	closedOlderStore(t, other, SchemaVersion-1)
	got, err := Home()
	if err != nil || got != other {
		t.Fatalf("home %q, %v", got, err)
	}
	s, err := Open(got)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v, err := s.readVersion(s.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	if _, err := os.Stat(copyFile(other, SchemaVersion-1)); err != nil {
		t.Fatal(err)
	}
}

func TestDevBuildMigratesTheDefaultHomeWithTheOverride(t *testing.T) {
	home := useDefaultHome(t)
	setProgramVersion(t, "")
	closedOlderStore(t, home, SchemaVersion-1)
	// Only the value 1 is the override.
	t.Setenv(allowDevMigrate, "0")
	if _, err := Open(home); !errors.Is(err, ErrDevMigrate) {
		t.Fatalf("Open with the value 0: %v", err)
	}
	t.Setenv(allowDevMigrate, "1")
	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v, err := s.readVersion(s.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	if _, err := os.Stat(copyFile(home, SchemaVersion-1)); err != nil {
		t.Fatal(err)
	}
}

func TestDevBuildMakesANewStoreInTheDefaultHome(t *testing.T) {
	home := useDefaultHome(t)
	setProgramVersion(t, "")
	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v, err := s.readVersion(s.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	if got := copiesIn(t, home); len(got) != 0 {
		t.Fatalf("files %q", got)
	}
}

func TestReleaseVersionMigratesTheDefaultHome(t *testing.T) {
	home := useDefaultHome(t)
	setProgramVersion(t, "v0.4.7")
	old := SchemaVersion - 1
	closedOlderStore(t, home, old)
	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v, err := s.readVersion(s.db); err != nil || v != SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	if _, err := os.Stat(copyFile(home, old)); err != nil {
		t.Fatal(err)
	}
}

// Both cases of a newer store are in its error, with both schemas.
func TestNewerStoreErrorNamesBothFixes(t *testing.T) {
	home := testutil.Home(t)
	s, err := Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.db.Exec(`UPDATE schema_version SET version = ?`, SchemaVersion+1); err != nil {
		t.Fatal(err)
	}
	_, err = s.CreatePlot(PlotInput{Name: "n"}, Actor{Kind: ActorCLI})
	if !errors.Is(err, ErrSchemaNewer) {
		t.Fatalf("CreatePlot: %v", err)
	}
	for _, want := range []string{
		fmt.Sprintf("schema %d", SchemaVersion+1), fmt.Sprintf("schema %d", SchemaVersion),
		"restart this session", "scripts/install-release.sh",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the error %q does not say %q", err, want)
		}
	}
}
