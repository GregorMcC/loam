// Package secret keeps secrets, such as the Linear API key, in the login
// Keychain of macOS. Only the core reads them. LOAM_SECRETS_FILE names a JSON
// file that stands in for the Keychain in tests.
package secret

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

// service is the Keychain service of each Loam secret. The name of a secret
// is its account.
const service = "Loam"

// notFound is the exit code of security when no item matches.
const notFound = 44

// ErrBadValue means the value has characters that a key never has.
var ErrBadValue = errors.New("the key can hold only letters, digits, \"_\", and \"-\"")

// valueRE is the shape of an API key. It keeps the value safe to pass to
// security -i, which splits its input at spaces and quotes.
var valueRE = regexp.MustCompile(`^[A-Za-z0-9_-]{1,512}$`)

// Get returns the secret, or "" when none is stored.
func Get(name string) (string, error) {
	if file := os.Getenv("LOAM_SECRETS_FILE"); file != "" {
		m, err := readFile(file)
		return m[name], err
	}
	out, err := exec.Command("/usr/bin/security", "find-generic-password", "-s", service, "-a", name, "-w").Output()
	if code(err) == notFound {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read the Keychain: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Set stores the secret, in place of the one before.
func Set(name, value string) error {
	if !valueRE.MatchString(value) {
		return ErrBadValue
	}
	if file := os.Getenv("LOAM_SECRETS_FILE"); file != "" {
		m, err := readFile(file)
		if err != nil {
			return err
		}
		m[name] = value
		return writeFile(file, m)
	}
	// security -i reads the command on stdin, so the key is never in the
	// arguments of a process, where ps can show it.
	cmd := exec.Command("/usr/bin/security", "-i")
	cmd.Stdin = strings.NewReader(fmt.Sprintf("add-generic-password -U -s %s -a %s -w %s\n", service, name, value))
	if out, err := cmd.CombinedOutput(); err != nil || strings.Contains(string(out), "error") {
		return fmt.Errorf("write the Keychain: %v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Delete removes the secret. A secret that is not stored is no error.
func Delete(name string) error {
	if file := os.Getenv("LOAM_SECRETS_FILE"); file != "" {
		m, err := readFile(file)
		if err != nil {
			return err
		}
		delete(m, name)
		return writeFile(file, m)
	}
	err := exec.Command("/usr/bin/security", "delete-generic-password", "-s", service, "-a", name).Run()
	if err != nil && code(err) != notFound {
		return fmt.Errorf("remove from the Keychain: %w", err)
	}
	return nil
}

// code returns the exit code of a failed command, or 0.
func code(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return 0
}

func readFile(file string) (map[string]string, error) {
	m := map[string]string{}
	b, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	return m, json.Unmarshal(b, &m)
}

func writeFile(file string, m map[string]string) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return os.WriteFile(file, b, 0o600)
}
