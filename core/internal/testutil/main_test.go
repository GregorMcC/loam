package testutil_test

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TestMain removes the helper binaries of testutil after the tests.
func TestMain(m *testing.M) { testutil.Main(m) }
