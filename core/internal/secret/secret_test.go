package secret_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/secret"
)

func TestSecretsFileStandsInForTheKeychain(t *testing.T) {
	file := filepath.Join(t.TempDir(), "secrets.json")
	t.Setenv("LOAM_SECRETS_FILE", file)
	if got, err := secret.Get("linear"); err != nil || got != "" {
		t.Fatalf("empty store: %q %v", got, err)
	}
	if err := secret.Set("linear", "lin_api_abc123"); err != nil {
		t.Fatal(err)
	}
	if got, err := secret.Get("linear"); err != nil || got != "lin_api_abc123" {
		t.Fatalf("%q %v", got, err)
	}
	if fi, _ := os.Stat(file); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	if err := secret.Delete("linear"); err != nil {
		t.Fatal(err)
	}
	if got, _ := secret.Get("linear"); got != "" {
		t.Fatalf("after delete: %q", got)
	}
	// A second delete is no error.
	if err := secret.Delete("linear"); err != nil {
		t.Fatal(err)
	}
}

func TestSecretRefusesAValueWithOddCharacters(t *testing.T) {
	t.Setenv("LOAM_SECRETS_FILE", filepath.Join(t.TempDir(), "secrets.json"))
	for _, v := range []string{"", "two words", "quote\"d", "line\nbreak"} {
		if err := secret.Set("linear", v); !errors.Is(err, secret.ErrBadValue) {
			t.Errorf("%q: %v", v, err)
		}
	}
}
