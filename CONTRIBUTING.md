# Contributing to Loam

Loam is a personal project, so I answer when I have time. This file lists the steps that every change follows. The pull request template repeats them.

## Talk first

Open an issue before you change anything that a person sees:

- a command or a flag
- a key
- a seed line
- an error text
- a flow in the app

The issue lets us agree on the change before you write it. A bug fix, a test, or a typo fix needs no issue.

## Steps

1. Start from the latest `main`. Make one branch for each change.
2. Write the change and its tests.
3. Build and test. See [Build and test](#build-and-test).
4. Change the docs that go with the change. See [Docs](#docs).
5. Read your full diff before you push. See [Private details](#private-details).
6. Open one pull request (PR) to `main`. Fill in the PR template. I squash-merge each PR.

## Build and test

CI runs these checks on each PR (see `.github/workflows/ci.yml`):

- `core`: gofmt, `go vet`, [golangci-lint](https://golangci-lint.run), `go test` and [govulncheck](https://go.dev/doc/security/vuln/) in `core/`.
- `app`: `swift test` without GhosttyKit, which runs the LoamKit tests.
- `app-full`: builds the app and its tests with GhosttyKit, and runs no tests. CI does not run the driver tests. Run them yourself for a change to the app.
- `lint`: shellcheck on `scripts/` and actionlint on the workflows.

On a PR, the `changes` job reads the changed files, and CI skips each job that the change cannot affect. For example, a change to `site/` only runs `lint`.

Run the same commands yourself before you push. CI does not replace them.

In `core/`:

```sh
gofmt -l .
go vet ./...
golangci-lint run
go test ./...
```

In `app/`:

```sh
swift test
```

`swift test` runs the driver tests only when GhosttyKit is built. Without GhosttyKit, it runs the LoamKit tests only.

For a change to the app, build GhosttyKit first. Run `scripts/build-ghosttykit.sh` before your first test run, and again when `ghostty.pin` changes. Then run `swift test --manifest-cache none` in `app/`. The option makes SwiftPM see the new GhosttyKit link. The [README](README.md#build-from-source) lists the tools that you need.

Tests use a temporary `LOAM_HOME`, a fake `claude`, and a fake `gh`. Do not point a test at your real store, your real `claude`, or GitHub. The Go helpers are in `core/internal/testutil`.

## Docs

- Change `docs/contract.md` with any change to the CLI JSON. Also change the schema and the fixtures. [contract/README.md](contract/README.md) gives the steps.
- Change `docs/design/` with any change to a design rule.

## The pull request

The PR body has these parts:

- What changes.
- Screenshots, for a change that a person sees in the app.
- How to try it.
- The tests that you ran.

## Private details

Loam is a public repo. Do not put details from your own machine, or about real people, in code, fixtures, commit messages, PR text, or screenshots:

- a person's name, other than the Git author of a commit
- a home folder path
- an email address, other than the Git author of a commit
- the host name of a private machine or a company server

Public names such as `github.com` and the name of this repo are fine.

Use made-up data. The driver scenarios in `app/Sources/LoamDriver` show how. Look at each screenshot before you add it.

## Words that a person reads

This covers the app text, error messages, help text, and docs. Write short sentences in the active voice. Use simple words. Do not use em dashes. Use the terms in [CONTEXT.md](CONTEXT.md).
