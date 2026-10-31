package sandbox

import (
	"os"
	"path/filepath"
)

// PrivateXcrunCache is the name of the private xcrun cache in a folder of the
// gate or of a run. Not xcrunCache: the profile of the gate denies that name
// in each temp folder.
const PrivateXcrunCache = "xcrun-cache"

// userXcrunCache is the cache of the xcrun shims of the user, for tests.
var userXcrunCache = XcrunCache

// SeedXcrunCache writes a copy of the xcrun cache of the user to
// PrivateXcrunCache in dir, and returns the path of that file. With the
// copy, the xcrun shims in a sandbox, such as /usr/bin/git, find their tools
// as they do outside it. A shim that misses the cache runs xcodebuild to fill
// it, which takes seconds and, in a sandbox, prints errors. dir must be a new
// folder of the caller. A sandbox can write dir, so SeedXcrunCache does not
// open a file that is already there, such as a link that a sandbox put
// there. With no cache of the user, or when the copy fails, the file is not
// there, and the first shim fills it.
//
// The caller gives the returned path in xcrun_db only to the processes of the
// sandbox. A process outside the sandbox that read this file would run each
// tool that a process of the sandbox wrote in it.
func SeedXcrunCache(dir string) string {
	cache := filepath.Join(dir, PrivateXcrunCache)
	src := userXcrunCache()
	if src == "" {
		return cache
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return cache
	}
	f, err := os.OpenFile(cache, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return cache
	}
	_, werr := f.Write(b)
	if cerr := f.Close(); werr != nil || cerr != nil {
		_ = os.Remove(cache)
	}
	return cache
}
