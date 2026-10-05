package store

import (
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

// ChangedFile is the marker in the home folder that each committed write
// rewrites. The app watches it with the database files. macOS reports a
// modified file when the writer closes it, and loam mcp keeps the database
// open for the whole session, so a write to the database alone can raise no
// event until the server exits.
const ChangedFile = "loam.changed"

var changedCount atomic.Uint64

// markChanged rewrites the marker with a value that no other write has. A
// failure is ignored: the write is already committed, and the next write or
// close still reaches the app.
func (s *Store) markChanged() {
	stamp := fmt.Sprintf("%d %d %d\n", time.Now().UnixNano(), os.Getpid(), changedCount.Add(1))
	_ = os.WriteFile(filepath.Join(s.home, ChangedFile), []byte(stamp), 0o600)
}
