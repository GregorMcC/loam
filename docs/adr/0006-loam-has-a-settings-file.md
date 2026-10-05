# Loam has a settings file

Loam v1 had no config file of its own, and ⌘, opened your Ghostty config. Some values were hard-coded for one machine, such as `~/Development` for repo suggestions and `~/.local/bin/loam`. Loam now has a settings file, `<LOAM_HOME>/settings.json`, and a native settings window on ⌘,. Open Ghostty Config keeps its menu item with no key.

The file is in `LOAM_HOME`, not in `~/Library/Application Support/Loam`, so the core can read it later and the tests stay isolated. The app reads and writes the file directly, not through the CLI (ADR 0004), because one setting is the path of `loam` itself. The terminal look and keys stay in the Ghostty config.

## Consequences

- `docs/contract.md` holds the schema. A key that the app does not know survives a write from the window.
- The core reads none of the settings yet. A later setting for the core, such as the `claude` path or the worktree folder, goes in the same file.
- ⌘, now differs from Ghostty, where it opens the config.
