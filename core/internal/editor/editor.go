// Package editor opens text in the editor of the person who runs loam.
package editor

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
)

// Command returns the editor command: $VISUAL, then $EDITOR, then vi.
func Command() string {
	for _, k := range []string{"VISUAL", "EDITOR"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return "vi"
}

// Error is the error of an editor run that failed. The text that the person
// typed is still in File, so they do not lose it.
type Error struct {
	File string
	Err  error
}

func (e *Error) Error() string {
	return fmt.Sprintf("the editor failed: %v (your text is in %s)", e.Err, e.File)
}

func (e *Error) Unwrap() error { return e.Err }

// KeptFile returns the path of the kept file in an editor error, or "".
func KeptFile(err error) string {
	var ee *Error
	if errors.As(err, &ee) {
		return ee.File
	}
	return ""
}

// Edit writes text to a temp file, runs the editor on it with the terminal
// attached, and returns the file text after the editor exits. The command
// goes through sh, so a value such as "code --wait" works. If the editor
// fails, Edit keeps the file and returns an [*Error] with its path.
func Edit(text string) (string, error) {
	f, err := os.CreateTemp("", "loam-*.md")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	cmd := exec.Command("sh", "-c", Command()+` "$1"`, "sh", path)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return "", &Error{File: path, Err: err}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", &Error{File: path, Err: err}
	}
	os.Remove(path)
	return string(b), nil
}
