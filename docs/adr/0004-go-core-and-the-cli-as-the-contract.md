# The core is Go, and the app calls it through the CLI

The Loam core is one Go binary, `loam`. It is the CLI, and `loam mcp` is the MCP server. The Loam app is Swift, because libghostty embeds through a Swift and AppKit host. The app reads and changes plots only by running `loam … --json` as a subprocess. The two share no code, and the CLI output is the only contract between them.

We chose Go because its MCP SDK is Tier 1 on the current spec and builds one static binary. The Swift SDK is Tier 3 and one spec revision behind. A Swift core would let the app link the core as a package with no subprocess, and that was the real alternative. We rejected it because the MCP server is the surface Claude uses most. We also rejected linking Go into the app as a c-archive: the Go runtime installs its own signal handlers in the process that sends SIGHUP to panes and waits for their children before it frees a surface.

## Consequences

- Every `loam` command has `--json` output and a stable exit code for each error the app handles, such as a stale write.
- The app holds hand-written Codable types. A contract test decodes real `loam` output.
- Each app action costs one process start, about 10 ms. A long-lived `loam serve` child over stdio is the upgrade path if that becomes too slow.
- The app never opens `~/.loam/loam.db`. It learns about changes through FSEvents on `~/.loam` and `loam log --since`.
- A pane starts a seeded session with `loam start`, the same command you run in any terminal.
- `loam` is installed on its own, and the app checks its version at launch.
