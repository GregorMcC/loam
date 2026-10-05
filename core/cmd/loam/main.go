// Command loam is the Loam core: the CLI, the MCP server, and the session starter.
package main

import (
	"os"

	"github.com/GregorMcC/loam/core/internal/cli"
)

func main() { os.Exit(cli.Execute()) }
