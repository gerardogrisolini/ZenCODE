# Changelog

All notable changes to ZenCODE are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release tags follow the strict `vX.Y.Z` contract described in
[Docs/release.md](Docs/release.md) and must match `ZenPackageMetadata.version`.

## [Unreleased]

## [2.0.0] - 2026-08-26

> **Breaking release:** compared with v1.3.0, v2.0.0 removes public
> `ToolOutputDetailLevel` and the TUI output-detail toggle (`Ctrl+T`), the
> `--verbose`/`verboseLogging` and legacy logging interfaces, and the former
> contextual result payloads of `local.editFile` and `local.multiEdit`. Update
> integrations to use `ZENCODE_LOG` and the platform system log.

### Added

- Tool executions now emit secret-redacted structured records through Swift's
  system `Logger` instead of application-owned files. Records include tool and
  session data, agent identity, model, status, optional duration, and detailed
  typed error causes; delegated-agent executions carry the child's identity.
  `/tools logs` opens the platform system log viewer (Console.app on macOS).
- `/skills uninstall` now opens an interactive multi-selection menu for removing
  app-installed prompt skills. Uninstall destinations are validated against the
  app catalog roots, including symlink and containment checks, before deletion.

### Changed

- Completed sub-agent responses now render directly beneath their agent metadata,
  with every Markdown output line indented as nested agent content instead of
  resembling a coordinator response.
- `/plan` now requires the read-only Planner to produce a concise, self-contained
  functional analysis. Every numbered implementation point is a complete
  specification implementable from the plan and workspace after declared
  prerequisites, with observable behavior/flow, verified files or symbols,
  applicable constraints and edge cases, and concrete validation. It omits context
  summaries, generic background, non-pertinent sections, and detail that does not
  change implementation, using the fewest points and words that preserve
  implementation certainty. The Planner resolves necessary choices from evidence
  or asks a focused blocking question.
- Delegated sub-agent tool calls now reuse the coordinator's canonical terminal
  rows—including lifecycle status, duration, failures, and source-change diffs—
  while remaining indented inside the live Sub-Agents section. Each agent keeps
  one current tool area, replaced in place with the rest of the overview.
- Sub-agent thinking now keeps a stable `🤔 thinking…` header in the terminal
  overview and renders the currently streamed paragraph beneath it, replacing
  only that value in place when the next paragraph begins. Paragraph detection is
  independent of stream chunk boundaries (including CRLF split across deltas),
  the phase is tracked as typed state instead of a marker prefix, and the reasoning
  text is neutralized against terminal control sequences before it is rendered.
- **Breaking:** `local.editFile` and `local.multiEdit` now return fixed compact
  confirmations with only the path and replacement/edit count, not post-edit
  context or diff-like output.
- Project-memory guidance and descriptors now treat memory as a concise,
  evidence-backed journal: verified handoffs, durable decisions, blockers, and
  releases/publications are retained while transient activity, speculation, and
  raw output are excluded. Read-only memory tool surfaces now receive guidance
  that does not suggest unavailable mutations.
- **Breaking:** Removed public `ToolOutputDetailLevel` and the terminal
  output-detail toggle, including its `Ctrl+T` shortcut. Tool output now has one
  standard compact presentation.
- Terminal command completion now recognizes parser aliases and static arguments
  for `/tasks`, `/agents`, `/tools`, `/feature`, `/changes`, and `/skills`,
  including `/skills add`, `/skills uninstall`, `/tasks ls`, and `/tasks get`.
- Removed redundant compatibility and helper code across the MCP bridge, bundled
  features, Xcode tools, and shared tool models without changing public behavior.
- Decomposed the session runner, terminal render coordinator, feature process
  lifecycle, and local MCP transport into focused domain units — shared
  lifecycle/teardown primitives, typed stream-pump handlers, and per-domain
  companion files. No existing public API, wire, or persistence behavior
  changed; one new public helper, `FeatureProcessTreeSupervisor.terminateImmediately`,
  was lifted out of a private teardown path.

### Removed

- **Breaking:** Removed `--verbose`, `ZENCODE_AGENT_VERBOSE`, and the
  `verboseLogging` runtime setting, along with verbose stderr/progress, ACP
  file-log, and provider-diagnostic output. The flag is rejected.
- **Breaking:** Removed `ZENCODE_LOG_LEVEL`, `ZENCODE_LOG_FILE`, and legacy
  `ZenLoggerConfiguration.Destination.file`/`.standardError`; logging uses
  `ZENCODE_LOG` and the platform system log.

### Fixed

- Nested Sub-Agent Markdown code blocks no longer add a spurious blank row, and
  nested tables and code blocks now reserve their indentation when fitting to
  the terminal width.
- Fixed live Sub-Agents rendering losing its terminal anchor when the first
  shared-chat message makes the compact Chat header appear.
- `/tools logs` is now available while a prompt is running; other `/tools`
  invocations remain unavailable.
- Standard terminal tool output preserves its ANSI colors, compact status
  layout, source changes, and redraw lifecycle without alternate detail modes.
- The ChatGPT subscription WebSocket test server now closes its channel only
  after its response has flushed, eliminating a response-delivery race.
- End-of-turn terminal file-change summaries now remain the final section after
  pending task-graph and plan output on both successful and failed prompts.

## [1.3.0] - 2026-08-23

### Added

- Builder now exposes `feature.promote`: generated non-adopted Swift features can be
  copied transactionally into a branch of a ZenCODE Git checkout. Promotion
  performs validate/build/`--list-tools` preflight, excludes Builder manifests,
  build state, Git metadata, and symlinks, writes `feature-distribution.json`,
  updates declarative/Swift catalogs, and never commits or pushes.
- Setup gained a **Data management** subsection grouping backup export,
  backup import, and the existing remote-configuration reset (removed from
  the main menu). Export writes the whole support directory — hidden files
  and nested directories included — to a single compressed tar.gz archive;
  Import validates it completely (per-file SHA-256, traversal and symlink
  rejection, entry limits) before atomically replacing the support
  directory, with automatic rollback on failure. Backups are unencrypted
  and contain provider credentials.
  Export fails explicitly when the support directory contains a symbolic
  link, runs under the shared coordination lock for a coherent snapshot,
  and replaces an existing archive rollbackably. The import swap preserves
  the coordination lock's inode so cross-process exclusion survives the
  rename, and manifest totals use overflow-checked arithmetic.

### Changed

- Renamed the delegated task-graph command from `/workflow` to `/goal`; the old
  command is no longer accepted.
- Project `AGENTS.md` guidance is now fully manual and read-only from ZenCODE's
  perspective. When the file exists in the working directory, ZenCODE reads it
  and inserts it into the agent context, but it no longer creates, regenerates,
  materializes, or rewrites the file. `AGENTS.md` is no longer ignored by the
  repository so projects may version it intentionally.
- The setup menu moved **Features** and **Memory embeddings** from the Optional
  group to the Recommended group, so the recommended configuration steps are
  shown together before the optional integration toggles.
- File editing tools now use compact canonical `old`/`new` arguments, preserve
  consistent line endings, reject ambiguous or empty matches, and return
  bounded post-edit context with affected line ranges. Their schemas and output
  payloads are substantially smaller while retaining atomic multi-edit
  semantics.

### Fixed

- The terminal’s live **Sub-Agents** overview now replaces its existing owned
  rows when a new delegation wave arrives, avoiding duplicated stale sections.
- Messages written by the terminal operator remain visible in the shared-chat
  reader but no longer increment, shift, or consume the unread-message marker.

### Removed

- Removed the `/agents-md` command and its legacy `/make-agents` alias, including
  the dedicated model turn, restricted tool allowlist, and write
  post-condition tracking. **Migration:** create or edit the project
  `AGENTS.md` manually; ZenCODE will apply it automatically when it is present
  in the working directory. The separate global `~/.zencode/AGENTS.md` behavior
  is unchanged.
- Removed the public `ProjectContextFileService` APIs that created, regenerated,
  or materialized context files; the service now exposes read-only project
  context loading.

## [1.2.6] - 2026-08-20

### Changed

- ACP and agent session lifecycle state is now isolated by session and backend
  generation: stale work is fenced during rebuild, close, reset, and shutdown,
  while authorization handlers, prompt-skill providers, snapshots, and
  task-graph observers are cleaned up with their owning session. Prompt
  reservations remain held until the final ACP result is sent.
- ACP session refresh preserves session revisions, context-window limits, and
  generation-parameter overrides; task-bound sub-agents receive a restricted
  `tasks.update` schema, and OpenAI tool payload generation requires an explicit
  session scope.
- Terminal overview rendering now keeps actor-confined state in dedicated value
  types, clears stale delegated rows, respects display width and CommonMark
  ordered-list limits, and mirrors only task-graph overviews to Telegram;
  high-frequency sub-agent snapshots remain terminal-only.
- Direct Anthropic requests now share subscription thinking capability and
  payload rules, while model catalog URLs preserve configured base paths and
  query items.
- MCP local transports share bounded stream-pump and process-tree lifecycle
  handling, drain buffered output before teardown, and keep Figma endpoint
  ownership in its standalone feature.
- Session prompt composition now centralizes shared workflow, memory, agent, and
  project-context guidance, avoiding duplicate legacy Developer instructions and
  redundant active-plan policy. The generated global `AGENTS.md` template keeps
  only the additional Xcode-specific guidance.

### Fixed

- Provider thinking authorization again honors known manifest options while
  preserving `.enabled` for effort-level dialects and unknown capabilities.
- Task-graph checkpoint state is reset when sessions are discarded or recreated,
  so saving after deleting all plans no longer fails with a stale checkpoint.
- ChatGPT browser sign-in no longer hangs when the local callback port is
  unavailable: it falls back to manual authorization-code input.
- SSE streams now enforce post-head idle timeouts, bound line and event
  accumulation, handle bare CR delimiters across chunks, and report typed
  parsing failures instead of stalling or growing without limit.
- ACP diagnostics are filtered consistently and empty tool results omit empty
  content blocks; terminal thought and Markdown rendering handles structured
  content without hard wrapping.
- The shared-chat reader overlay no longer paints over the live Sub-Agents
  section: expanding the Chat box now relinquishes the section's owned
  terminal rows before the status bar redraws, and ACP lifecycle checks no
  longer await synchronous state.
- Application-provided system prompts now receive the same dynamic `AGENTS.md`,
  delegatable-agent roster, memory-tool policy, and task-workflow context as
  standard sessions, so exposed delegation and memory tools always have the
  profile bindings and usage rules they require.

### Security

- Destructive tool authorization now applies before feature-owned alias dispatch,
  renders consent arguments with lossless shell quoting, and keeps per-session
  permission decisions isolated and evicted on close and shutdown. Task
  cancellation without an explicit session is rejected, and ambiguous
  tool-selection prefixes no longer resolve silently.
- WebTools now rejects loopback, private, link-local, metadata, multicast,
  reserved, local, and ambiguous numeric destinations on requests, redirects,
  and main-frame navigation. Jira credential-bearing requests require HTTPS and
  exact same-origin redirects.
- Saved-session indexes are created and read with private file and directory
  permissions, harden legacy modes, and reject destination symlinks; MCP logs
  redact sensitive environment values and invalid OAuth metadata URLs fail
  closed.

## [1.2.5] - 2026-08-17

### Added

- Telegram sessions can now manage tasks and sub-agents, mirroring task-graph
  activity as overviews while keeping high-frequency sub-agent snapshots in the
  terminal only.
- Saved plans gained a full lifecycle: completed live plans are mirrored into
  the library, `/plan list` reviews them with short ids, and `/plan delete`
  removes exact or unique-prefix targets.
- Optional features are validated in CI through a generated per-feature
  matrix, and the installers share hardened support helpers with an explicit
  Swift 6.3+ toolchain check and pinned per-feature lockfiles.

### Changed

- Provider thinking configuration is resolved from explicit settings and
  model metadata instead of streaming heuristics, and `/setup` only offers
  thinking for models that support it.
- Anthropic message encoding, stream accumulation, and thinking-block handling
  moved into dedicated transport components as part of the provider rework.
- Memory engine persistence was reworked with graph versioning, transactional
  saves, entry deduplication, and read-only search, with project-context write
  contracts covered by dedicated tests.
- Behavior-preserving refactoring removed dead code and deduplicated helpers
  across Remote, Telegram, TUI, and the session orchestrator.

### Fixed

- Feature processes are signalled across their whole process tree, so
  terminating a feature job no longer leaves orphaned children.
- Sub-agent tool calls render correctly in compact terminal output.

## [1.2.4] - 2026-08-13

### Changed

- Remote model discovery now queries each configured OpenAI-compatible provider
  directly, while OpenRouter metadata is merged separately when available to
  preserve context-length and thinking-capability details.
- Shared JSON, hashing, direct-tool argument parsing, and network-error helpers
  replace duplicated compatibility layers, removing obsolete runtime code while
  preserving existing public behavior.

### Fixed

- Task-bound sub-agents now receive accurate `tasks.update` guidance and can
  report progress without attempting lifecycle mutations owned by the runtime.
- Non-streaming HTTP requests now retain their timeout through complete body
  consumption, follow bounded redirects safely, and strip sensitive headers on
  cross-origin redirects.
- Remote model selection keeps provider results authoritative while enriching
  matching entries with OpenRouter metadata without exposing provider API keys.

## [1.2.3] - 2026-08-11

### Changed

- `tasks.create` and `agent.create` system-prompt guidance and tool descriptors
  now use a single canonical payload shape, producing more consistent task-graph
  and delegation instructions across `/plan`, `/workflow`, and `/review`.
- Compact tool rendering in the terminal handles sub-agent tool calls more
  cleanly, with improved rendering for delegated agent activity.
- The shared-chat reader (`Ctrl+Y`) now opens at the first unread message instead
  of the latest, so new messages are immediately visible.

### Fixed

- A session turn lease (`AgentSessionTurnLease`) now serializes concurrent turn
  requests to the session runner, preventing overlapping turns from corrupting
  coordinator state.
- ChatGPT subscription WebSocket pool and task race conditions are resolved: the
  pool tears down HTTP connections deterministically, and WebSocket task
  cancellation can no longer leak or double-fire.
- The MCP tool runtime now fences install-generation boundaries, preventing
  interleaved feature installations from corrupting the runtime.
- Terminal redraw glitches during sub-agent delegation are fixed: the render
  coordinator no longer leaves stale frames when agent status changes.
- Shared-chat unread counts are now computed correctly when the reader is
  reopened after new messages arrive.
- A timing-dependent test (`readBridgeAbandonsOnTimeout`) is stabilized with a
  wider margin between the bounded timeout and the simulated slow read.
- A flaky HTTP transport test (`chatGPTHTTPFallbackDoesNotRetryCallbackFailure`)
  is stabilized: the local test server now sends an explicit HTTP `.end`
  terminator before closing the channel, preventing a transport-level close from
  racing ahead of the final body chunk.

## [1.2.2] - 2026-08-10

### Added

- A transient `Chat` reader is now available in the terminal for live shared-chat
  messages. `Ctrl+Y` opens or closes it (`Ctrl+O` also works where supported),
  with compact total/unread counts and expanded message navigation; entries stay
  out of the main transcript.

### Changed

- Shared-chat messages delivered while the coordinator or a delegated agent is
  already working are injected into the next tool result so the recipient can
  reply immediately and resume its current turn. Idle and standby recipients
  retain queued delivery, with a lossless fallback when no further tool call is
  made.
- Task-graph summaries now show total and color-coded status counts, use
  terminal-safe plain text outside ANSI output, and present more compact task
  details.

### Fixed

- Terminal shared-chat observations now reconnect after an unexpected
  non-cancelled stream end or backend replacement, while bounded retries avoid a
  hot loop when an empty stream repeatedly closes.
- Operator messages to `@coordinator` now wake shared-chat processing immediately
  instead of waiting for the safety poll.
- Terminal escape and OSC sequences, including multiline and unknown payloads,
  are drained safely instead of leaking bytes into prompt input.

## [1.2.1] - 2026-08-09

### Fixed

- Coordinator-originated `agent.message` traffic now wakes shared-chat
  transcript observers immediately. Direct coordinator→sub-agent messages no
  longer depend on the periodic safety poll before their blue terminal card (or
  ACP update) is emitted.
- The terminal `@` autocomplete no longer shows only `@coordinator` and `@all`
  when agents are live. The input panel now pulls the current shared-chat roster
  while a mention token is being edited, instead of depending solely on roster
  notifications, which the bounded terminal queue evicts first and which the
  coordinator published only on a roster-signature change. A dropped roster
  event is now also re-published on the next coordination poll, and `/agent` no
  longer clears the mention entries from the panel catalogue.
- Live shared-chat messages are now rendered by ACP clients. A sub-agent that
  reports through `agent.message` reaches the ACP host as a standard
  `agent_message_chunk` instead of being visible only in the terminal UI. The
  renderer is attached once per session incarnation, is kept in a bridge-scoped
  registry so no session-state rebuild (prompt refresh, `@agent` routing,
  `set_model`) can silently drop it, is attached after a `session/load` history
  replay so transcripts are never interleaved, skips operator traffic the client
  already displays, and is awaited to quiescence by `session/close` and
  `shutdown`.

## [1.2.0] - 2026-08-09

### Added

- Project memory now uses a durable, per-workspace graph outside the working
  tree. Existing `MEMORY.md` content is imported lazily and left untouched,
  while graph mutations are persisted atomically.

- Automatic memory recall is enabled by default: relevant project facts are
  injected transiently into main and delegated turns without entering
  conversation history, snapshots, or prompt cache keys. Retrieval uses local
  BM25 by default; optional endpoint-based embeddings add semantic ranking and
  are configured from `/setup`.

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

[Unreleased]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.6...v1.3.0
[1.2.6]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.5...v1.2.6
[1.2.5]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.4...v1.2.0
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
