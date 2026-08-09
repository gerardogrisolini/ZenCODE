# Changelog

All notable changes to ZenCODE are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release tags follow the strict `vX.Y.Z` contract described in
[Docs/release.md](Docs/release.md) and must match `ZenPackageMetadata.version`.

## [Unreleased]

### Changed

- The terminal `@` autocomplete now builds display labels and routing IDs from
  one live participant snapshot. Departed agents are removed from handle
  resolution immediately, while their aliases remain reserved against reuse;
  returning instances with the same stable ID recover their original route.

- Replies from a delegated agent to a direct human-operator message now use the
  dedicated `agent.message` destination `operator` instead of being routed to
  the coordinator. Operator replies remain visible through the transient room
  transcript and never enter the coordinator mailbox. If a provider completes
  that direct conversational turn without calling `agent.message`, its final
  output is delivered to `operator` as a non-duplicating runtime fallback.

- Shared chat delivery is now serialised in each recipient's work loop instead
  of tied to a tool call. The inline-delivery mechanism that appended live
  messages to the result of the next tool boundary has been removed: every
  message — to an idle, running or standby agent — is drained from the bounded
  mailbox and queued as a prompt, so the reply is the next turn of that agent,
  independent of any future tool call. This fixes the case where a standby agent
  never replied because it had no tool to execute. A message is never lost or
  delivered twice, and the coordinator room drains its mailbox even while busy
  (pending batch shown to observers, synthetic turn held back until the room goes
  idle and re-armed at turn end).

- The blue shared-chat message card now reliably reaches every active observer
  within the transcript bound. The coordinator replays the bounded room
  transcript to each newly attached observer, shared-chat messages are never
  dropped from the terminal event queue (backpressure instead of eviction), and
  the TUI deduplicates by message id.

- `@` autocomplete now lists active agents by readable handles derived from
  their display names (`@dev`, `@code-reviewer`) via an actor-isolated mention
  catalogue, instead of opaque `@agent-Base64` blobs. Routing always resolves
  back to the stable participant id; aliases are never recycled within a session,
  duplicate names get numeric suffixes, and the legacy `@agent-Base64` spelling
  remains accepted for backward compatibility.

## [1.1.4] - 2026-08-07

### Added

- Live messages (`AgentSharedChat`): while sub-agents are active, the human
  operator, the coordinator LLM, and the agent instances share a bounded,
  in-memory chat room. From the terminal, `@coordinator` messages the live
  coordinator, `@all` broadcasts to the coordinator and every active agent, and
  the `@agent-…` handle addresses one instance directly. The `agent.message` tool
  exposes the same destinations (`direct`, `coordinator`, `peers`, `all`); direct
  messages wake idle recipients immediately. Every reply travels back through the
  same chat via `agent.message`: both the coordinator and delegated agents are
  instructed that ordinary model output is not part of the chat, so any reply to
  a chat message must be sent through `agent.message` regardless of the sender.
  The chat is transient and never written to a session snapshot or task
  checkpoint.

### Changed

- Runtime prompt composition now separates the cacheable static system prefix
  from the dynamic user context: working directory and response language stay in
  the static prefix, while workflow/task graph, agent roster, and memory travel
  in the dynamic initial message preserved across snapshot restore and
  conversation compaction.

## [1.1.3] - 2026-08-05

### Changed

- `agent.create` now advertises only the canonical batch payload
  `{"agents":[...]}`, where every item carries an explicit `profile` and a
  `binding:<id>` model reference. Delegation no longer falls back to a profile's
  default binding: the model must pick an authorized one from the delegatable
  roster. Legacy root fields and aliases stay input-compatible but are no longer
  model-visible, and conflicting aliases are rejected.
- Sub-agent routing resolves profiles and bindings against a consistent
  `settings.json` snapshot, validating model, provider, capability, and
  authentication before a task is claimed. The resolved provider, model, key, and
  generation parameters are handed to the child backend instead of being looked
  up a second time, so the effective provider cannot change between validation
  and backend creation.
- The TUI command that authors project guidance is now `/agents-md`. It asks the
  model to inspect the current working directory and create or update its
  `AGENTS.md` without assuming a project type. The former `/make-agents` name
  keeps working as a hidden alias.
- Custom ACP extensions are namespaced: `model/preload` and `session/set_model`
  are now `_zencode/model/preload` and `_zencode/session/set_model`.
- ZenCODE-specific data moved out of standard ACP fields and into the `_meta`
  extension object. The model catalog returned by `initialize` and `session/new`
  is now `_meta.models`, and the `rawInput` carried by `tool_call` updates and
  permission requests is now `_meta.rawInput`.
- Subscription usage is delivered as an immediate custom
  `_zencode/usage/subscription` JSON-RPC notification instead of a
  `subscription_usage_update` session update that did not satisfy the ACP
  `usage_update` schema. Context-window usage keeps using the valid
  `usage_update` with `used`/`size`.

### Added

- `/agents-md` verifies its own post-condition against the turn's tracked file
  changes. When the turn ends without creating `AGENTS.md`, or leaves an existing
  file untouched, ZenCODE reports it instead of returning silent success.

### Removed

- The modal `Ctrl+R` reverse history search was removed from the prompt editor,
  together with its panel hints and help text. Ordinary history recall with the
  arrow keys is unaffected.

### Fixed

- Session shutdown waits for in-flight prompt tasks before flushing, closing a
  race at session close.
- Restoring a single task graph preserves the other graphs of a multi-graph
  session, and installing the task orchestrator is idempotent under its exclusive
  ownership guard.
- Optional-feature installations are serialized per feature ID, so concurrent
  requests for the same feature no longer interleave.
- Agent settings are loaded without a stale cache and mutated under
  cross-process exclusive coordination, so delegation cannot run against an
  outdated `settings.json` snapshot. The persisted JSON format is unchanged.

### Security

- Error messages rendered by the ChatGPT OAuth callback server are HTML-escaped,
  and the OAuth `state` parameter is now required when a callback URL is pasted
  manually.
- Sensitive environment values (token, secret, auth, key, password) are redacted
  in MCP bridge logs.
- Timeout input is validated at the optional-feature installation entry point,
  and a force-unwrapped URL construction in the MCP browser OAuth configuration
  was replaced with a guarded failure.

## [1.1.2] - 2026-08-05

### Changed

- Expanded tool blocks now syntax-highlight the `parameters` JSON with the same
  palette used for fenced code blocks in chat: keys, strings, numbers and
  literals keep their classic colors while punctuation and indentation stay on
  the neutral parameter gray. Raw multi-line string bodies rendered inside a
  `"""` block remain flat, so prose is never tokenized as data.
- Prompt editing now follows the Emacs/readline conventions so that motion works
  on keyboards without `Home`/`End` keys: `Ctrl+A`/`Ctrl+E` move to line
  start/end, `Ctrl+B`/`Ctrl+F` move by character, `Ctrl+P`/`Ctrl+N` move by
  line or history entry, and `Alt+<`/`Alt+>` jump to the start/end of the whole
  draft. Escape sequences prefixed by a second `ESC` (macOS terminals that send
  `Option` as `Meta`) are decoded as Alt-modified keys, so `Option+←/→` performs
  word motion there.
- The `local.exec` access-mode toggle moved from `Ctrl+A` to `Ctrl+G`, freeing
  the standard line-start binding. Panel hints, `/help`, and `Docs/zen.md` list
  the current shortcuts.
- Release builds of `zen` now strip local symbols before the binary is verified,
  archived, or installed. CI, the release workflow, and both install scripts run
  `strip -u -r` on macOS and `strip --strip-all` on Linux, and optional Swift
  features are stripped with `strip -S` after a successful release build.

## [1.1.1] - 2026-08-03

### Added

- Persistent process support for optional features (`FeaturePersistentProcess`
  and `FeaturePersistentService`): compatible features such as Xcode tools can
  now reuse one long-lived session-scoped process instead of spawning a new one
  per invocation.

### Changed

- Prompt input field rewritten with a new `TerminalPromptEditor`, inline
  autocompletion, refined key handling, panel layout, and history navigation.

### Fixed

- Xcode tools now reuse one session-scoped feature process and MCP bridge for
  discovery and invocation, so Xcode consent is requested once per ZenCODE
  session instead of once per tool call.
- `zen --doctor` diagnostics corrected; unused agent-runtime and ACP
  configuration fields removed.

## [1.1.0] - 2026-08-02

### Added

- `/plan save` persists the active plan, or the latest non-empty assistant
  response, in the project task-graph plan library; `/plan load` restores the
  latest save as an unapproved plan in a session without an active plan and
  never resumes old execution state.
- Agent profiles now have a backwards-compatible `readOnly` setting that
  centrally removes mutable catalog-owned core tools. Existing manifests decode
  a missing value as `false`; the default Planner and Reviewer enable it.
- Task-graph checkpoints can carry optional saved-plan metadata while remaining
  compatible with existing schema-1 checkpoints.

### Changed

- Delegated agents now derive their tool grant exclusively from a selected,
  configured profile, and the model-visible workflow policy prefers suitable
  sub-agents for non-trivial, independently scoped work. **Migration:**
  `agent.create` now requires `profile` (or `agent`) and rejects request-level
  tool overrides such as `toolNames`; configure the required tools on the
  profile instead.
- Conversation compaction now uses provider-aware prompt budgets, preserves a
  larger useful suffix and bounded summaries, accounts for transport overhead,
  and applies conservative retry targets after context-window failures.
- Xcode feature descriptors now direct models to prefer applicable Xcode tools
  over shell, filesystem, search, SwiftPM, or `xcodebuild` alternatives.
- Terminal presentation now uses centralized semantic styling for thinking,
  tools, sub-agent activity, status, Markdown, and permission dialogs, with
  tool output visually attenuated without dimming model responses.

### Fixed

- Concurrent ACP prompts now share one in-flight runtime-backend preparation;
  actor reentrancy during asynchronous backend hydration can no longer invoke
  the backend factory multiple times for the same runner.
- Read-only agents assigned to a task retain `tasks.update` for attempt progress
  and lifecycle reporting, while `tasks.create`, `tasks.retry`, `tasks.cancel`,
  and other mutating core tools remain restricted.
- `/telegram on` can attach an already-running local turn to Telegram and keeps
  progress reporting synchronized when Telegram is enabled or disabled during
  generation.
- Voice transcription handling, terminal first-row and streamed-thinking
  rendering, sub-agent activity presentation, and related color consistency.
- Context compaction edge cases across shared runtime, ChatGPT, and Anthropic,
  including tiny transcripts, impossible budgets, provider payload inflation,
  cache invalidation, and retry convergence.

## [1.0.11] - 2026-08-01

### Added

- Native Linux arm64 CI and release artifacts alongside the existing Linux
  x86_64 builds, providing downloadable binaries for ARM servers and devices
  such as Raspberry Pi.

### Changed

- Interactive setup is now part of `ZenCODECore`: first-run setup opens
  automatically when required, `/setup` rebuilds the runtime and restores the
  active conversation, and setup tests now live with the Core test target.
- Expanded tool parameter JSON and metadata values now reuse the peach-orange of
  compact tool values instead of medium gray, keeping both presentation modes
  visually consistent while preserving the orange-title-over-content hierarchy.

### Removed

- The separate public `ZenCODESetup` product and target. Setup APIs such as
  `ZenCODESetupRunner` are now exported by `ZenCODECore`.

### Fixed

- A detailed in-progress tool block that exactly filled the scrolling region
  scrolled its title past the top margin before completion could replace it,
  leaving a stale hourglass copy in the transcript beside the completed result.
  The rewriteable row capacity now reserves the cursor row needed after the
  block's terminating newline.

## [1.0.10] - 2026-07-31

v1.0.9 was tagged but never published: its Linux release gate failed on the
flaky test fixed below, so no release assets were produced for that tag.

### Added

- Downloadable macOS arm64 and Linux x86_64 binaries from successful CI runs,
  retained as workflow artifacts for 30 days. Verified tag builds also publish
  versioned archives and SHA-256 checksums as persistent GitHub Release assets.
  This is the first release whose assets are actually published, see the fix
  below.

### Fixed

- Release workflow now publishes the verified binaries it builds. The release
  gate ran the test suite in parallel, which could park Foundation's
  process-global lifecycle state and stall the step until the job timeout, so
  the archive, upload, and publish steps were skipped and every GitHub Release
  from v1.0.0 to v1.0.8 was created without assets. The gate now matches CI with
  `swift test --no-parallel`, and its timeout allows for the clean, uncached
  build it performs.
- Removed an unsupported `timeoutSeconds` argument from the `feature.build`
  invocation in `SwiftFeatureManagementTests`.
- Flaky ACP concurrency test `concurrentACPPromptsReserveTheSessionExactlyOnce`,
  which dispatched both prompts and opened the completion gate without waiting
  for the first prompt to reach the backend. Because `Task` does not start its
  body synchronously, a slow runner could let the first prompt finish and
  release its reservation before the second one began, so no rejection was
  recorded. The test now pins the first prompt with the same `startGate` used by
  the other lifecycle tests in the suite, making the reservation contention
  deterministic.

## [1.0.8] - 2026-07-30

### Changed

- `xcode-tools` is now a fully self-contained macOS-only optional package. The
  former root `XcodeToolsFeature` library product was removed: its MCP bridge
  discovery and policy, request compatibility normalization, workspace matching,
  execution, presentation, and tests now live entirely in the package-local
  implementation. The root graph exports no Xcode feature product, `ZenCODECore`
  imports no Xcode implementation module, and Linux builds no longer compile
  Xcode runtime metadata or compatibility shims (removed
  `LinuxXcodeToolCompatibility`).
- Telegram runtime files reorganized out of `ZenCODETUI` into
  `Sources/ZenCODECore/ZenCODE/Telegram`, with the `TerminalChat+Telegram`
  adapter moved under `Chat/Telegram`, keeping terminal presentation separate
  from the Telegram runtime.
- Simplified the direct MCP tool runtime (`DirectMCPToolRuntime`), the direct
  tool executor, the memory service, and tool-selection presentation across the
  root package.

### Fixed

- Optional-feature upgrade and installation from setup: bounded installation
  diagnostics and logging, executable resolution validation, and feature
  management rendering across `SwiftFeatureOptionalInstallation`,
  `SwiftFeatureManagementTools`, `SwiftFeatureRuntimeValidation`, and the setup
  runner.
- Linux test compatibility for the bundled-feature catalog parity suite.

## [1.0.7] - 2026-07-30

### Added

- New optional macOS feature package `desktop-tools` (`desktop.run`): typed
  desktop control covering permission/system inspection, app and window
  enumeration, PNG screenshots attached to the model's multimodal context,
  pointer/keyboard/clipboard input, and app/window management. It is installed
  on demand like every other optional package, never executes caller-supplied
  shell or AppleScript code, and is not offered on Linux.

### Fixed

- Startup task recovery now skips checkpoint scanning and its interactive
  selection when `zen` runs in `--acp` mode, preserving JSON-RPC-only I/O.

### Changed

- Optional Swift features are now standalone SwiftPM packages under
  `Sources/Features` rather than executable products in the root package or
  files installed beside `zen`. The installer removes the legacy
  `zen-features/` directory, preserves a source checkout, and offers on-demand
  installation through `zen --install-features`; selected packages are built as
  Builder-compatible local features in `~/.zencode/features/<id>/`.

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

[Unreleased]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.4...HEAD
[1.1.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.11...v1.1.0
[1.0.11]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.10...v1.0.11
[1.0.10]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.8...v1.0.10
[1.0.8]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/gerardogrisolini/ZenCODE/releases/tag/v1.0.0
