package testutil

import (
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sync"
	"testing"
)

// bins holds the helper binaries of this test process. Each binary is built
// once into one shared folder, which [Main] makes before the tests and
// removes after them.
var bins struct {
	mu    sync.Mutex
	dir   string
	err   error // why Main could not make dir
	main  bool  // Main runs the tests
	byPkg map[string]*bin
}

// bin is one helper binary: built once, by the first test that needs it.
type bin struct {
	once sync.Once
	path string
	err  error
}

// Main runs the tests of a package, then removes the helper binaries that
// [BuildLoam], [FakeClaude], and [FakeGH] built. Each package that uses those
// helpers calls it from its TestMain:
//
//	func TestMain(m *testing.M) { testutil.Main(m) }
//
// Main makes the shared folder before any test runs, so a test that moves
// TMPDIR does not move it.
func Main(m *testing.M) {
	dir, err := os.MkdirTemp("", "loam-testbin-")
	bins.mu.Lock()
	bins.dir, bins.err, bins.main = dir, err, true
	bins.mu.Unlock()
	code := m.Run()
	if dir != "" {
		if err := os.RemoveAll(dir); err != nil {
			fmt.Fprintf(os.Stderr, "testutil: remove the helper binaries: %v\n", err)
		}
	}
	os.Exit(code)
}

// built returns the binary of pkg. The first call builds it into the shared
// folder, and later calls get the same binary. When the build fails, each
// test that asks for pkg fails with the build output.
func built(t *testing.T, pkg string) string {
	t.Helper()
	bins.mu.Lock()
	if !bins.main {
		bins.mu.Unlock()
		t.Fatalf("testutil: build %s: call testutil.Main from the TestMain of this package", pkg)
	}
	if bins.err != nil {
		err := bins.err
		bins.mu.Unlock()
		t.Fatalf("testutil: make the folder of the helper binaries: %v", err)
	}
	if bins.byPkg == nil {
		bins.byPkg = map[string]*bin{}
	}
	b := bins.byPkg[pkg]
	if b == nil {
		b = &bin{}
		bins.byPkg[pkg] = b
	}
	dir := bins.dir
	bins.mu.Unlock()
	b.once.Do(func() {
		out := filepath.Join(dir, path.Base(pkg))
		cmd := exec.Command("go", "build", "-o", out, pkg)
		cmd.Env = append(os.Environ(), goCaches...)
		if o, err := cmd.CombinedOutput(); err != nil {
			b.err = fmt.Errorf("go build %s: %v\n%s", pkg, err, o)
			return
		}
		b.path = out
	})
	if b.err != nil {
		t.Fatal(b.err)
	}
	return b.path
}

// link puts a symlink named name to target into dir.
func link(t *testing.T, target, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.Symlink(target, p); err != nil {
		t.Fatal(err)
	}
	return p
}
