//go:build e2e

package e2e

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TestMain removes the helper binaries of testutil after the tests.
func TestMain(m *testing.M) { testutil.Main(m) }
