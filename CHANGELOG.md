# Changelog

All notable changes to ZenCODE are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release tags follow the strict `vX.Y.Z` contract described in
[Docs/release.md](Docs/release.md) and must match `ZenPackageMetadata.version`.

## [Unreleased]

## [1.0.6] - 2026-07-29

### Added

- Startup recovery for incomplete task graphs. Interactive sessions now scan
  the current project for unfinished work and present it in the same orange,
  scrollable picker used by setup. Operators can resume a graph, start fresh
  without changing saved work, or mark obsolete graphs with `[x]` and delete
  them selectively.
- Exact-graph recovery semantics: a startup choice is resolved by
  `sessionID + graphID`, and the selected graph is made active/current and
  persisted before the model backend starts. Other graphs in the same
  checkpoint are preserved, while superseded active graphs are archived.
- Declarative tool-presentation metadata shared by direct tools, MCP tools, and
  Swift Features, including structured titles, locations, arguments, statuses,
  and change summaries.
- Expanded Browser feature observability, including bounded console and network
  diagnostics with filtering and redaction.

### Changed

- Tool output rendering now uses the shared presentation contract across the
  compact and expanded TUI views, ACP updates, bundled features, and delegated
  tools, with clearer orange-family hierarchy and parameter formatting.
- ChatGPT subscription sessions now prefer Responses WebSockets for the root
  session, retry replay-safe transient failures within a bounded budget, and
  fall back to HTTP/SSE for the remainder of the logical session when the
  WebSocket path is unavailable. Delegated sessions start directly on
  HTTP/SSE to avoid accumulating long-lived connections.
- Telegram turn reporting and permission handling now preserve tool-call order,
  accumulate assistant content cleanly, and provide richer inline progress
  without duplicating the final response.

### Fixed

- Task recovery no longer restores whichever graph happened to be current when
  an old checkpoint was written. The exact graph selected by the operator is
  now authoritative, including when one previous session contains multiple
  incomplete graphs. Persisted active attempts are marked `interrupted` and
  their tasks become `blocked` instead of being assumed to still be running.
- ChatGPT WebSocket lifecycle, continuation parsing, connection fallback, and
  close handling across transport resets and replay-safe retries.
- Anthropic subscription thinking-block accumulation and thinking payload
  handling across streamed responses.
- Expanded tool rendering, active-tool selection, tool-name normalization, and
  related Linux build compatibility.

## [1.0.5] - 2026-07-28

### Fixed

- ChatGPT prompt-cache persistence crash: persisted cache keys now use a
  compact SHA-256 hash of a canonical session-identity encoding instead of
  embedding the full system prompt. The previous reversible representation
  could grow to tens of kilobytes per session and, with hundreds of sessions,
  exceed macOS's 4 MiB `UserDefaults` limit. Added bounded storage with LRU
  eviction, value validation, legacy-format migration, and a dedicated
  mutation lock.
- `MCPFeatureConfiguration` protocol dispatch crash: `makeExecutor`,
  `toolNamePrefix`, and `descriptionPrefix` are now protocol requirements with
  dynamically dispatched defaults, replacing the statically dispatched
  `fatalError` default that trapped even when a conformance supplied its own
  implementation.

### Changed

- Telegram progress reporting: the turn reporter now accumulates assistant
  content and emits tool-call messages inline, replacing the previous stream
  of separate system messages (turn started, voice received, transcription
  ready, file-change summary). The final response is delivered once on
  completion, reducing notification noise.

## [1.0.4] - 2026-07-27

### Fixed

- ChatGPT prompt-cache routing: separated the canonical `prompt_cache_key`,
  now persisted by session identity, from the rotating WebSocket session ID
  that changes after compaction, failure recovery, or stream-interruption
  replays. The cache key no longer rotates on transport resets, so prompt
  caching survives continuation replays and connection failures.
- Prompt-skill tools (`skills.list`, `skills.read`) in delegated sub-agents:
  the parent session's prompt-skill tool provider is now propagated to each
  sub-agent, keeping the intrinsic skill selection always-on at every
  delegation depth.

### Changed

- Broad internal refactoring across the MCP transport codec and clients, the
  browser CDP feature layer, the ACP bridge and update pipeline, the remote
  generation and subscription clients, the SwiftNIO HTTP/SSE/WebSocket
  transport, and the terminal input and rendering layer.

## [1.0.3] - 2026-07-27

### Added

- Continuous integration workflow running the full build, test, and release
  gate on macOS 26 and Ubuntu 24.04 with Swift 6.3.
- Release verification workflow enforcing the strict `vX.Y.Z` tag contract
  against `ZenPackageMetadata.version`.
- Contribution, security, and changelog documents plus issue and pull request
  templates.

### Changed

- Expanded project documentation.

### Fixed

- Linux CI deadlock in `FeatureProcessRunner`: Foundation's global process
  reaper could suppress a child's terminationHandler after SIGKILL, hanging the
  cooperative thread pool and cascading test timeouts; added a bounded reaping
  fallback and an explicit exit monitor.
- Cross-platform Xcode MCP candidate detection on Linux, replacing the no-op
  shim that misclassified ACP-provided servers.
- `exec.job` tool handling.

## [1.0.2] - 2026-07-26

### Changed

- New rendering for the sub-agents section.
- Improved rendering of agent model bindings.

### Fixed

- `swift-tools-feature` test handling and related layout issues.

## [1.0.1] - 2026-07-25

### Added

- Session language setup and an editing-files renderer.
- New prompt-skills management.

### Changed

- Complete `TerminalChat` isolation and a lifetime token for the NIO transport.

### Fixed

- Anthropic thinking-effort handling.
- `upgradeRejected` handling in the ChatGPT WebSocket transport.
- ChatGPT model selection.
- Installer and Linux build issues.
- Tool authorization handling.

## [1.0.0] - 2026-07-24

First stable release.

### Added

- Native-Swift coding agent for the terminal and ACP, distributed as a single
  compiled binary with no Node runtime.
- Provider-agnostic generation: any OpenAI-compatible endpoint, plus browser
  sign-in with an existing ChatGPT or Claude subscription.
- Cross-platform SwiftNIO HTTP/SSE/WebSocket transport shared by macOS, Linux,
  and Windows via WSL.
- Agentic workflows with a dependency-aware task graph (`/plan`, `/workflow`,
  `/review`) and capability-based delegation to sub-agents.
- `/bindings` command for agent model bindings.
- Granular `/tools` selection with file-change tracking and `/undo`.
- Dynamic Swift Features as durable tools, including bundled search, web,
  browser, Git, Swift, and Xcode feature executables.
- Selectable prompt skills, installable from GitHub or a local folder.

### Changed

- Removed local inference in favor of remote providers.
- Removed the dedicated Xcode agent profile.

[Unreleased]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/gerardogrisolini/ZenCODE/releases/tag/v1.0.0
