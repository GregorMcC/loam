# The Loam core works without the Loam app

The Loam core holds plots and starts seeded sessions. It works in any terminal through the `loam` CLI and the MCP server. The Loam app, built on libghostty, is one front end to the core. It is not the only way in.

We chose this because embedding libghostty is the largest technical risk in Loam. With this split, plots and seeded sessions are useful in Ghostty or Supacode before the Loam app exists, and if embedding is harder than expected. The cost is a clear boundary between the core and the app, and every core feature must work without the app's UI.

## Consequences

- The MCP server and the CLI must not need the Loam app to be running.
- The Loam app must read and change plots only through the core, so all three surfaces stay in step.
