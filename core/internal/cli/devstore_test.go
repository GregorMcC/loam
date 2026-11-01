package cli_test

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// loamInHome runs a loam binary with HOME moved to a temp folder and no
// LOAM_HOME, so its default home is below that folder and not the real ~/.loam.
func loamInHome(bin, home string, args ...string) (string, error) {
	cmd := exec.Command(bin, args...)
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "LOAM_") && !strings.HasPrefix(kv, "HOME=") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	cmd.Env = append(cmd.Env, "HOME="+home)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// The version that the build sets reaches the store: a build with the version
// of a release migrates the default home, and a plain build refuses. Each one
// is the real binary, so the test also holds the -X path of scripts/install.sh.
func TestBuildVersionDecidesTheMigrationOfTheDefaultHome(t *testing.T) {
	release := filepath.Join(t.TempDir(), "loam")
	build := exec.Command("go", "build", "-o", release,
		"-ldflags", "-X github.com/GregorMcC/loam/core/internal/cli.Version=v0.0.1",
		"github.com/GregorMcC/loam/core/cmd/loam")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	dev := testutil.BuildLoam(t)

	home := t.TempDir()
	if out, err := loamInHome(dev, home, "list", "--json"); err != nil {
		t.Fatalf("a dev build makes a new store: %v\n%s", err, out)
	}
	file := filepath.Join(home, ".loam", "loam.db")
	db, err := sql.Open("sqlite", file)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	old := store.SchemaVersion - 1
	if _, err := db.Exec(`UPDATE schema_version SET version = ?`, old); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(home, ".loam", fmt.Sprintf("loam.db.v%d.bak", old))

	out, err := loamInHome(dev, home, "list", "--json")
	if err == nil || !strings.Contains(out, "a dev build does not migrate") {
		t.Fatalf("the dev build: %v\n%s", err, out)
	}
	var v int
	if err := db.QueryRow(`SELECT version FROM schema_version`).Scan(&v); err != nil || v != old {
		t.Fatalf("version %d, err %v", v, err)
	}
	if _, err := os.Stat(backup); !os.IsNotExist(err) {
		t.Fatalf("the dev build left a copy: %v", err)
	}

	// The store only claims the older schema, so the migration itself can fail
	// on what is there already. The copy shows that the release passed the guard.
	out, _ = loamInHome(release, home, "list", "--json")
	if strings.Contains(out, "a dev build does not migrate") {
		t.Fatalf("the release build refused:\n%s", out)
	}
	if _, err := os.Stat(backup); err != nil {
		t.Fatalf("the release build left no copy: %v\n%s", err, out)
	}
}
