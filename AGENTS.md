# AGENTS.md

ZenCODE is a Swift 6.4 package whose main executable is `zen` (macOS, Linux, WSL). Before changing an area, read its authoritative source: `CONTRIBUTING.md` (validation gate, tests, dependencies, releases), `Docs/architecture.md` (compatibility surfaces, dependency direction, ownership, persistence, ZenCRON), `Docs/memory.md` (memory), `Docs/release.md` (releases), and the header of `Scripts/rpios-test.sh` (Linux validation).

- Preserve public modules, executable names, wire and persisted formats, feature identities, and task-graph ownership unless an explicit migration changes them. Structural changes keep observable behavior, update registries, scripts, and parity checks together, and add characterization tests before moving persistence- or wire-sensitive code.
- Every root target enables `MemberImportVisibility`: import the module that defines each member you use.
- Tests use Swift Testing, not XCTest, with UUID-named temporary directories, `@Suite(.serialized)` when they mutate process-wide state, and never the real `~/.zencode` (isolate it with `ZENCODE_SUPPORT_DIRECTORY`).
- Add a `CHANGELOG.md` entry under `## [Unreleased]` for user-visible changes. Do not update `Package.resolved` incidentally.
- Validate with `swift build --target ZenCODECore`, `swift test --filter <Suite>`, `git diff --check`, and `bash -n Scripts/*.sh` after script edits; network, provider, and installer runs are dedicated checks, not routine validation. Root commands build neither `Sources/Features/*` nor `Sources/ZenCRON`, which have their own manifests.
- Focused suites: memory engine `MemoryEngineTests`, memory facade also `MemoryServiceTests` and `MemoryEnhancementTests`, sensitive manifests `SensitiveManifestPermissionsTests`, bundled features `BundledFeatureCatalogParityTests`.
- A green macOS run is not evidence that Linux passes: reproduce Linux-only failures on the `zencode-rpios` machine.
