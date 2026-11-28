# Contributing to ZenCODE

Thanks for your interest in ZenCODE. This document describes how to build the
project, what the review expectations are, and which invariants a change must
preserve.

## Requirements

- Swift 6.4 or newer toolchain.
- **macOS**: macOS 26 (Tahoe) or newer on Apple Silicon, with a compatible Xcode
  or Apple command line tools installation that provides Swift 6.4 or newer.
  The compiler may require a newer host OS than the package deployment minimum;
  confirm the selected toolchain with `swift --version`.
- **Linux / WSL**: a Swift 6.4 or newer toolchain on `PATH`, or install one with
  [Swiftly](https://www.swift.org/install/linux/).

## Getting started

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
swift build -c release --product zen
```

## Validation

This is the single definition of the validation gate; the README and
[`Docs/release.md`](Docs/release.md) reference it instead of repeating it.
Run the same gate CI runs before opening a pull request:

```bash
swift build --target ZenCODECore          # fast shared-runtime compile
swift test                                # full non-live suite and release/CI gate
swift build -c release --product zen      # release product
swift test --package-path Sources/ZenCRON # ZenCRON package; only when ZenCRON changes
swift test --package-path Sources/ZenApp  # macOS app; when ZenApp or the ZenCODECore API it uses changes
Scripts/test-all.sh                       # every package, features included, in parallel
bash -n Scripts/*.sh                      # shell syntax
git diff --check                          # whitespace hygiene
```

For focused work, `swift test --filter <SuiteOrTestName>` is usually enough
during development, but the full suite must pass before review.

When bundled features, manifest wiring, or installer catalogs change, run
`BundledFeatureCatalogParityTests` and check the affected feature's
`--list-tools` output.

ZenCRON (`Sources/ZenCRON`) is a standalone package outside the root graph, so
`swift test` at the root does not run its tests. The CI job `zencron-package`
runs them, and builds ZenCRON, on macOS and Linux.

ZenApp (`Sources/ZenApp`) is likewise a standalone package outside the root
graph; it builds the root package through a path dependency. `swift test` at the
root does not run its tests. The CI job `zenapp-package` builds and tests it on
macOS only, because the app requires macOS 26 and SwiftUI.

`Scripts/test-all.sh` runs `swift test` for the root package, ZenCRON, ZenApp
(macOS only), and every feature package in the catalog (on Linux, only the
features installed there). Test cases run in parallel inside each package, and
up to `--jobs` packages (default 2) run at a time. `--only` selects packages,
`--scratch-root` gives each package its own build directory, and `--serial`
adds `--no-parallel` for diagnosis.

Live provider checks are opt-in through `ZENCODE_RUN_LIVE_*` environment
variables. Leave them unset for ordinary verification; CI never runs them.

## Architecture rules

[`Docs/architecture.md`](Docs/architecture.md) is the compatibility and
dependency-direction contract, and it is authoritative. In short:

- `Sources/ZenCODERuntime` (product `ZenCODERuntime`) owns the shared agent
  runtime: chat sessions, remote providers, tools, Telegram, voice, context,
  memory, sessions, and file-change tracking. It never depends on
  `Sources/ZenCODECore`.
- `Sources/ZenCODECore` (product `ZenCODECore`) owns the TUI, the interactive
  setup, ACP, and the CLI composition (`Runtime/Launcher`). It re-exports
  `ZenCODERuntime`, so `import ZenCODECore` keeps the whole public API. Runtime
  symbols that only it uses are `package`, never `public`, and each of its
  files that uses the runtime imports `ZenCODERuntime` explicitly.
- `Sources/ToolCore` holds dependency-light wire and descriptor types; keep
  Xcode-specific behavior out of it.
- `Sources/FeatureKit` owns executable-feature contracts; keep
  `Sources/FeatureMCPBridgeKit` generic and transport-focused.
- `Sources/LocalToolsSupport` provides reusable local file, search, text, and
  patch implementations.
- `Sources/zen` is the executable composition root.
- `SessionTaskOrchestrator` is the sole mutable task-graph owner.

Preserve public modules, executable names, wire formats, persisted formats, and
feature identities unless the change is an explicit, documented migration.

When a project `AGENTS.md` is present, update it and `Docs/architecture.md` in
the same change whenever an architectural boundary, cited path, build flag, or
validation gate moves.

## Tests

- Tests use [Swift Testing](https://github.com/swiftlang/swift-testing)
  (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), not XCTest.
- Use UUID-named temporary directories for filesystem tests.
- Mark suites that mutate process-wide environment or shared state with
  `@Suite(.serialized)`. Suites always run concurrently with one another:
  `.serialized` only orders the cases of one suite, so a test must not depend on
  running alone.
- A timed wait only bounds a failure: poll for the condition with a generous
  deadline (30 seconds) instead of sleeping for a fixed time, and wait for a
  transition to have happened rather than for one exact sequence of events.
- Every suite runs in parallel, on macOS and Linux, locally and in CI.
  `--no-parallel` is a diagnosis tool, never a gate: a test that does not
  finish next to the others is fixed, or removed if the behavior it covers is
  no longer worth the cost. Do not add `.serialized` to hide a failure.
- Do not add a test that builds a real Swift package from the test process:
  several of them run the compiler at once, and on a four-vCPU runner they
  starve every other suite. Do not exec a fixture the test has just written
  either: a sibling test forking at that moment can fail the exec with "Text
  file busy". Feature packages are built and tested by their own
  CI jobs (`standalone-features`), which is where their build coverage lives.
- Never turn local runtime state (`~/.zencode`, or `ZENCODE_SUPPORT_DIRECTORY`)
  into repository fixtures.

## Dependencies

`Package.resolved` is tracked and pins release and CI revisions. Do not update
it incidentally. When resolution intentionally changes, run
`swift package resolve`, review the exact pins, and include the lockfile in the
same commit.

## Pull requests

- Keep changes focused; unrelated refactors make review harder.
- Explain the intent, not just the diff, and note any compatibility impact.
- Add or update tests covering the behavior you change.
- Make sure CI is green on both macOS and Linux.
- Add a `CHANGELOG.md` entry under `## [Unreleased]` for user-visible changes.

## Releases

Releases follow [Docs/release.md](Docs/release.md): update
`ZenPackageMetadata.version`, resolve and commit the lockfile, run the release
gate, then push the matching annotated `vX.Y.Z` tag. The release workflow
verifies the tag contract and platform gates before publishing the archives and
SHA-256 checksums to the matching GitHub Release.

## Security

Do not open a public issue for a vulnerability. Follow
[SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
