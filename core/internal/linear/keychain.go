package linear

import (
	"context"
	"errors"
	"os"

	"github.com/GregorMcC/loam/core/internal/secret"
)

// KeyName is the name of the API key in the Keychain.
const KeyName = "linear-api-key"

// ErrNoKey means no API key is stored.
var ErrNoKey = errors.New("no Linear API key. Add one in Settings > Connections, or with loam linear key set")

// APIURL is the API that Loam calls: LOAM_LINEAR_URL, for tests, or [DefaultURL].
func APIURL() string {
	if u := os.Getenv("LOAM_LINEAR_URL"); u != "" {
		return u
	}
	return DefaultURL
}

// FromKeychain returns a client with the stored API key. It fails with
// [ErrNoKey] when none is stored.
func FromKeychain() (*Client, error) {
	key, err := secret.Get(KeyName)
	if err != nil {
		return nil, err
	}
	if key == "" {
		return nil, ErrNoKey
	}
	return NewClient(APIURL(), key), nil
}

// Status says whether Loam has a working API key.
type Status struct {
	// Connected is true when a key is stored.
	Connected bool `json:"connected"`
	// Viewer is the person of the key, or nil when there is no key or Linear
	// did not answer.
	Viewer *Viewer `json:"viewer"`
	// Error says why Linear did not answer, or is "".
	Error string `json:"error"`
}

// ReadStatus checks the stored key with Linear.
func ReadStatus(ctx context.Context) (Status, error) {
	c, err := FromKeychain()
	if errors.Is(err, ErrNoKey) {
		return Status{}, nil
	}
	if err != nil {
		return Status{}, err
	}
	v, err := c.Viewer(ctx)
	if err != nil {
		return Status{Connected: true, Error: err.Error()}, nil
	}
	return Status{Connected: true, Viewer: &v}, nil
}

// SetKey checks the key with Linear, then stores it.
func SetKey(ctx context.Context, key string) (Status, error) {
	v, err := NewClient(APIURL(), key).Viewer(ctx)
	if err != nil {
		return Status{}, err
	}
	if err := secret.Set(KeyName, key); err != nil {
		return Status{}, err
	}
	return Status{Connected: true, Viewer: &v}, nil
}

// RemoveKey removes the stored key.
func RemoveKey() error {
	return secret.Delete(KeyName)
}
