package store

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// CheckRepoFolder says whether path is a folder that exists. The CLI and MCP
// call it before they add a repo. The store does not, so its tests can use
// made-up paths.
func CheckRepoFolder(path string) error {
	fi, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("the repo folder does not exist: %s: %w", path, ErrInvalid)
	case err != nil:
		return err
	case !fi.IsDir():
		return fmt.Errorf("the repo path is a file, not a folder: %s: %w", path, ErrInvalid)
	}
	return nil
}
