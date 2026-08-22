# AGENTS.md

## Project

- ZenCODE is a Swift 6.3 package whose main executable is `zen`; it runs on macOS, Linux, and WSL with remote model providers.
- `Package.swift` is authoritative for the root products, target dependencies, platforms, and build settings. The packages under `Sources/Features` have their own manifests and are outside the root graph.
- `Docs/architecture.md` is the compatibility and dependency-direction contract. Preserve public modules, executable names, wire formats, persisted formats, feature identities, and task-graph ownership unless an explicit migration changes them.
- Composition starts at `Sources/zen/CLI/ZenCODEMain.swift`; shared session coordination is centered on `AgentCoreSessionRunner`, backend state is behind `AgentCoreBackend`, and direct-tool dispatch is behind `DirectToolExecutor`.

## Build and Validation

- Every root Swift target enables `MemberImportVisibility`; source files must import the modules that define the members they use.
- Fast shared-runtime compile: `swift build --target ZenCODECore`.
- Use `swift test --filter` with the affected Swift Testing suite or test name. The full non-live suite is `swift test`; the CI and release gates use `swift test --no-parallel` for process-global lifecycle coverage. Validate Linux behaviour in the container machine described under Linux Validation.
- For memory-engine changes, run `swift test --filter MemoryEngineTests`; memory-facade changes additionally exercise `swift test --filter MemoryServiceTests` and `swift test --filter MemoryEnhancementTests` in `ZenCODECoreTests`.
- Main release product: `swift build -c release --product zen`.
- Root commands intentionally do not build optional feature executables. For an optional-feature change, run `swift test --filter BundledFeatureCatalogParityTests`, validate the package from its own directory according to its `Package.swift`, and check its installed executable's `--list-tools` output.
- For sensitive-manifest changes, run `swift test --filter SensitiveManifestPermissionsTests`; add the affected provider or setup suites when their persistence flows change.
- `Package.resolved` is tracked and pins CI/release dependencies. Do not update it incidentally; for an intentional dependency change, run `swift package resolve`, review the exact pins, and include the lockfile.
- Finish source changes with `git diff --check`. Validate script edits with `bash -n Scripts/*.sh`; network, provider, and installer executions are dedicated checks rather than routine validation.
- Release tags follow `Docs/release.md`: strict `vX.Y.Z`, matching `ZenPackageMetadata.version`, with the same immutable tag or full commit SHA passed through `--ref`.

## Linux Validation

- A prebuilt container machine provides the local Linux toolchain: `zencode-rpios` (Raspberry Pi OS / Debian 13 trixie, arm64, Swift 6.3). Its image is defined by `Scripts/rpios-trixie/Containerfile` and driven by `Scripts/rpios-test.sh`.
- Reproduce Linux-only CI failures here instead of inferring them from workflow status. macOS alone cannot confirm a Linux gate failure, and a green macOS run is not evidence that the Linux gate passes.
- Entry point: `Scripts/rpios-test.sh [build|test|shell|all]`. For targeted runs, invoke the machine directly: `container machine run -n zencode-rpios -w "$PWD" -- swift test --build-path /tmp/zencode-build [--filter <suite-or-test>]`.
- Always pass `--build-path /tmp/zencode-build`. The repository `.build` directory is shared with macOS and holds incompatible artifacts.
- Quoting is not preserved through `container machine run -- bash -c`; put multi-step or looping shell in a script file and run that file instead.
- One-time setup (`container build` then `container machine create`) is documented in the header of `Scripts/rpios-test.sh`.
- Concurrency and lifecycle races may not reproduce on an idle machine. When a test fails only in CI, rerun it under CPU contention (background busy loops oversubscribing the machine's cores) before concluding it is unrelated to the change.
- Stop both the machine and the builder when finished: `container machine stop zencode-rpios` and `container builder stop`. The BuildKit builder is a separate container that keeps running after the machine stops.

## Test and State Conventions

- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), not XCTest.
- Use UUID-named temporary directories for filesystem tests. Mark suites that mutate process-wide environment or shared state with `@Suite(.serialized)`.
- Runtime state defaults to `~/.zencode` and honors `ZENCODE_SUPPORT_DIRECTORY`. Isolate stateful tests from the developer's real support directory and do not turn runtime state into repository fixtures.
- `ZENCODE_RUN_LIVE_*` variables opt into live checks; leave them unset during ordinary validation.
- Durable memory storage, retrieval, embedding, recall, and memory-test rules: see [Memory Contract](#memory-contract).
