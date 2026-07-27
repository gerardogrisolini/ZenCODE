# Changelog

All notable changes to ZenCODE are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release tags follow the strict `vX.Y.Z` contract described in
[Docs/release.md](Docs/release.md) and must match `ZenPackageMetadata.version`.

## [Unreleased]

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

[Unreleased]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/gerardogrisolini/ZenCODE/releases/tag/v1.0.0
