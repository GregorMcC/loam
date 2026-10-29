package run

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A config with servers is a file that only you can read, and remove deletes
// it. A file that a killed Loam left goes at the next call, and a new one
// stays.
func TestMCPArgsWritesAFileAndSweepsOldOnes(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	b, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"loam": map[string]any{"type": "stdio", "command": "loam"}}})
	if err := os.WriteFile(filepath.Join(cfg, ".claude.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	stale, fresh := filepath.Join(tmp, "loam-mcp-stale.json"), filepath.Join(tmp, "loam-mcp-fresh.json")
	for _, p := range []string{stale, fresh} {
		if err := os.WriteFile(p, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	long := time.Now().Add(-3 * shapeTimeout)
	if err := os.Chtimes(stale, long, long); err != nil {
		t.Fatal(err)
	}

	args, remove, err := mcpArgs([]string{"loam"})
	if err != nil {
		t.Fatal(err)
	}
	path := args[len(args)-1]
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 || filepath.Dir(path) != tmp {
		t.Fatalf("config file %s: %v %v", path, info, err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("the stale file stays: %v", err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("the fresh file is gone: %v", err)
	}
	remove()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("remove left %s: %v", path, err)
	}

	// The config with no servers holds nothing secret: it is an argument, and
	// there is no file. The sweep still runs, so a file that a killed Loam
	// left goes after you clear the list.
	if err := os.Chtimes(fresh, long, long); err != nil {
		t.Fatal(err)
	}
	args, remove, err = mcpArgs(nil)
	if err != nil || args[len(args)-1] != `{"mcpServers":{}}` {
		t.Fatalf("args %q: %v", args, err)
	}
	remove()
	if left, _ := filepath.Glob(filepath.Join(tmp, mcpConfigPattern)); len(left) != 0 {
		t.Errorf("files %q", left)
	}
}
