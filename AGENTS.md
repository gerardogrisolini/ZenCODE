# AGENTS.md

## Project

- ZenCODE is a Swift 6.3 package whose main executable is `zen`; it runs on macOS, Linux, and WSL with remote model providers.
- `Package.swift` is authoritative for the root products, target dependencies, platforms, and build settings. The packages under `Sources/Features` have their own manifests and are outside the root graph.
- `Docs/architecture.md` is the compatibility and dependency-direction contract. Preserve public modules, executable names, wire formats, persisted formats, feature identities, and task-graph ownership unless an explicit migration changes them.
- Update `CHANGELOG.md` whenever a change is user-visible or otherwise warrants a release note.
- Composition starts at `Sources/zen/CLI/ZenCODEMain.swift`; shared session coordination is centered on `AgentCoreSessionRunner`, backend state is behind `AgentCoreBackend`, and direct-tool dispatch is behind `DirectToolExecutor`.

## Architecture Map

- `zen` is the only executable composition root and the only layer that selects and injects a remote model backend. `ZenCODECore` owns the shared runtime; terminal UI, Telegram, and ACP adapt that runtime without moving transport-specific types into neutral Agent or Remote domains.
- The reusable target flow is `ToolCore` → `FeatureKit` → `LocalToolsSupport`, with `FeatureMCPBridgeKit` depending only on `FeatureKit` and `ToolCore`. `ZenCODECore` consumes these support targets and `ZenPackageMetadata`; keep dependency-light contracts in the lowest viable layer and never introduce a dependency on `zen`.
- `Sources/Features/<Feature>` contains standalone Swift packages, not root targets. Each optional feature owns its product, implementation, policy, tests, and thin executable; generic feature-process and MCP machinery belongs in `FeatureKit` or `FeatureMCPBridgeKit`, never feature-specific behavior.
- `AgentCoreSessionRunner` is the session-level coordinator and injects one `SessionTaskOrchestrator` into every backend. The orchestrator is the sole mutable owner of task DAGs and checkpoints; backend recreation must not replace or discard that state.
- `DirectToolExecutor` is the authorization and dispatch boundary for direct tools. Delegated-agent tool grants come from configured profiles, not model-authored arguments or task metadata.
- Provider generation is remote-only and provider-agnostic runtime state stays local. Shared HTTP/SSE/WebSocket behavior belongs under `Remote/Generation`; authentication remains separate from generation transport.
- Persisted state lives under the support directory (default `~/.zencode`, overridable with `ZENCODE_SUPPORT_DIRECTORY`) and includes settings, sessions, task checkpoints, permissions, feature manifests, and per-workspace memory graphs. Presentation trees, live shared chat, and unfinished Planner clarification state are intentionally transient and must not enter snapshots or checkpoints.
- Treat `Docs/architecture.md` as authoritative for compatibility surfaces, ownership details, persistence formats, and migration rules. Structural changes must preserve observable behavior, use direct imports/dependencies, update registries/scripts/parity checks together, and receive focused characterization tests before moving persistence- or wire-sensitive paths.

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
- Durable memory storage, retrieval, embedding, recall, and persistence rules are defined under `Memory Ownership and Persistence` in `Docs/architecture.md`.
