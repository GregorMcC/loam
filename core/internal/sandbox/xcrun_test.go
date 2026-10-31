package sandbox

import (
	"os"
	"path/filepath"
	"testing"
)

// A private xcrun cache starts as a copy of the cache of the user, so a shim
// does not run xcodebuild to fill it.
func TestSeedXcrunCacheCopiesTheCacheOfTheUser(t *testing.T) {
	src := filepath.Join(t.TempDir(), "xcrun_db")
	if err := os.WriteFile(src, []byte("XR1L"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := userXcrunCache
	t.Cleanup(func() { userXcrunCache = old })
	userXcrunCache = func() string { return src }
	dir := t.TempDir()
	cache := SeedXcrunCache(dir)
	if cache != filepath.Join(dir, PrivateXcrunCache) {
		t.Errorf("cache = %q, want %s in %s", cache, PrivateXcrunCache, dir)
	}
	if b, err := os.ReadFile(cache); err != nil || string(b) != "XR1L" {
		t.Errorf("cache = %q, %v, want a copy", b, err)
	}
	// With no cache of the user, the folder starts with none.
	userXcrunCache = func() string { return filepath.Join(t.TempDir(), "none") }
	cache = SeedXcrunCache(t.TempDir())
	if _, err := os.Stat(cache); !os.IsNotExist(err) {
		t.Errorf("cache with no cache of the user: %v", err)
	}
}

// A sandbox can write the folder of the cache, so the seed does not write
// through a link that is already there.
func TestSeedXcrunCacheDoesNotFollowALink(t *testing.T) {
	src := filepath.Join(t.TempDir(), "xcrun_db")
	if err := os.WriteFile(src, []byte("XR1L"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := userXcrunCache
	t.Cleanup(func() { userXcrunCache = old })
	userXcrunCache = func() string { return src }
	target := filepath.Join(t.TempDir(), "rc")
	if err := os.WriteFile(target, []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Symlink(target, filepath.Join(dir, PrivateXcrunCache)); err != nil {
		t.Fatal(err)
	}
	SeedXcrunCache(dir)
	if b, err := os.ReadFile(target); err != nil || string(b) != "mine" {
		t.Errorf("target = %q, %v, want it unchanged", b, err)
	}
}
