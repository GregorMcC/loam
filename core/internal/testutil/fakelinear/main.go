// Command fakelinear serves a fake Linear API on a free local port, for the
// driver scenarios of the app. It prints the URL of the API on the first line
// of stdout, then serves until it is stopped. It accepts the key
// lin_api_good. See [testutil.FakeLinearServer] for its issues.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func main() {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "fakelinear:", err)
		os.Exit(2)
	}
	fmt.Printf("http://%s/graphql\n", l.Addr())
	if err := http.Serve(l, &testutil.FakeLinearServer{}); err != nil {
		fmt.Fprintln(os.Stderr, "fakelinear:", err)
		os.Exit(2)
	}
}
