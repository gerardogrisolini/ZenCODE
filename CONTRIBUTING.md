# Contributing to ZenCODE

Thanks for your interest in ZenCODE. This document describes how to build the
project, what the review expectations are, and which invariants a change must
preserve.

## Requirements

- Swift 6.3 toolchain.
- **macOS**: macOS 26 (Tahoe) on Apple Silicon, with the toolchain from Xcode or
  the Apple command line tools.
- **Linux / WSL**: a Swift 6.3 toolchain on `PATH`, or install one with
  [Swiftly](https://www.swift.org/install/linux/).

## Getting started

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
swift build -c release --product zen
```

## Validation

Run the same gate CI runs before opening a pull request:

```bash
swift build --target ZenCODECore     # fast shared-runtime compile
swift test                           # full non-live suite
swift build -c release --product zen # release product
bash -n Scripts/*.sh                 # shell syntax
git diff --check                     # whitespace hygiene
```

For focused work, `swift test --filter <SuiteOrTestName>` is usually enough
during development, but the full suite must pass before review.

When bundled features, manifest wiring, or installer catalogs change, run
`BundledFeatureCatalogParityTests` and check the affected feature's
`--list-tools` output.

Live provider checks are opt-in through `ZENCODE_RUN_LIVE_*` environment
variables. Leave them unset for ordinary verification; CI never runs them.

## Architecture rules

[`Docs/architecture.md`](Docs/architecture.md) is the compatibility and
dependency-direction contract, and it is authoritative. In short:

- `Sources/ZenCODECore` owns the shared agent runtime, remote providers, tools,
  ACP, TUI, context, memory, and file-change tracking.
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

Update `AGENTS.md` and `Docs/architecture.md` in the same change whenever an
architectural boundary, cited path, build flag, or validation gate moves.

## Tests

- Tests use [Swift Testing](https://github.com/swiftlang/swift-testing)
  (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), not XCTest.
- Use UUID-named temporary directories for filesystem tests.
- Mark suites that mutate process-wide environment or shared state with
  `@Suite(.serialized)`.
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
