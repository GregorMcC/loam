# The contract fixtures

This folder holds the output of the real `loam` binary for every command that has `--json`. The Go core and the app share it. `docs/contract.md` describes the contract in words.

## Layout

| Path | Content |
| :- | :- |
| `fixtures/manifest.json` | One entry for each fixture: `name`, `args`, `exit_code`, `schema` |
| `fixtures/<name>.json` | The normalized stdout of one run |
| `schema/<command>.json` | The JSON Schema (draft 2020-12) of one command |
| `schema/defs.json` | Definitions that the schemas share: plot, link, repo, change, and more |
| `schema/error.json` | The JSON error. It holds the `details` of `stale` and `undo_clash`. |

## How the fixtures are made

The test is `core/internal/contract/`. It does these steps:

1. It builds `loam` and sets `LOAM_HOME`, `HOME`, and `CLAUDE_CONFIG_DIR` to temp folders. It puts a fake `claude` first on `PATH`. It never reads `~/.loam`.
2. It runs one scenario of commands. Each command has `--json`. The scenario covers all commands in `docs/contract.md` and each exit code that the core returns today (1, 2, 10, 11, 14, 15).
3. It normalizes each output. Random IDs become fixed IDs, such as `plotaaaaab`, `linkaaaaab`, and `repoaaaaab`. Every time becomes `2026-01-01T00:00:00Z`. Temp paths become `/tmp/loam-contract/...`. Change IDs are not random, so they stay.
4. It checks the output and the fixture against the schema in the manifest.
5. It compares the shape of the output with the shape of the fixture. The shape is the set of keys and the JSON type of each value. Values can differ.

A normal run writes nothing. It fails when:

- an output or a fixture does not match its schema (a field is renamed, removed, added, or has another type);
- the shape of an output differs from its fixture;
- the manifest differs from the commands that the test runs;
- a command or exit code in `docs/contract.md` has no fixture;
- a schema or fixture file has no entry in the manifest.

## Change the contract

1. Change the code and `docs/contract.md`.
2. Change the schema in `schema/`.
3. Run the update, then read the diff of `fixtures/`:

```
cd core
go test ./internal/contract -run Contract -update
```

The environment variable `LOAM_CONTRACT_UPDATE=1` does the same. Use it with `go test ./...`, because the `-update` flag exists only in this package.

The schemas have `additionalProperties: false`. A new field fails the test until the schema and the fixtures have it. The app must still ignore fields that it does not know, as `docs/contract.md` says.

## How the app's Swift tests read the fixtures

The fixtures are plain JSON. A Swift test needs no Go.

1. Read `fixtures/manifest.json` and decode it as `[Entry]`, with `name`, `args`, `exit_code`, and `schema`.
2. For each entry, read `fixtures/<name>.json`.
3. If `exit_code` is 0, decode the file into the Codable type of the command. Use `schema` to find the type: `plot` types for `show`, `new`, `set`, and `edit`, and so on.
4. If `exit_code` is not 0, decode the file as the JSON error. Check that `error.exit_code` equals the manifest `exit_code`.
5. Add a Swift test that fails when a fixture is in the folder and no test decodes it.

Rules for the Codable types:

- Ignore unknown keys. Swift `Decodable` does this by default.
- `old`, `new`, and `undo_of` can be `null`. Use optionals. The key is always present.
- `value` in a stale item is missing when the value is an empty string.
- `session_id` and `loam_started` in an actor are missing when they do not apply.
- IDs in fixtures are fixed stand-ins. Do not test their value.
- The fixtures that start with `pane_` are not output of a `loam` command. Each is one line that `loam hook` writes to the pane socket. Decode it with the `pane-event` schema. The manifest `args` is `["hook"]`.
- `loam export` always prints JSON, so it has a fixture with and without `--changes`.
