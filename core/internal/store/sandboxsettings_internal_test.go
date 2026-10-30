package store

import (
	"errors"
	"reflect"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-189: a stored path that the checks refuse today does not block a change
// of another list.
func TestUpdateSandboxSettingsChecksOnlyTheListsThatItNames(t *testing.T) {
	s, err := Open(testutil.Home(t))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.SetSandboxSettings(SandboxSettings{Hosts: []string{"a.example.com"}}); err != nil {
		t.Fatal(err)
	}
	// An older version wrote a path that the checks refuse now.
	if _, err := s.db.Exec(`UPDATE sandbox_settings SET read_paths = '["~/.ssh"]' WHERE scope = ''`); err != nil {
		t.Fatal(err)
	}
	got, err := s.UpdateSandboxSettings("", SandboxChange{Hosts: &[]string{}})
	if err != nil {
		t.Fatalf("revoke a host: %v", err)
	}
	if len(got.Hosts) != 0 || !reflect.DeepEqual(got.Read, []string{"~/.ssh"}) {
		t.Fatalf("got %+v", got)
	}
	if _, err := s.UpdateSandboxSettings("", SandboxChange{Read: &[]string{"~/.ssh"}}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a named bad list: %v", err)
	}
}
