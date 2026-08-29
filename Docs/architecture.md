# Architecture and Layout

This document records the repository layout contract used when reorganising
ZenCODE. It is intentionally conservative: moving an implementation file must
not silently change a public module, executable, protocol, persistent format,
or build variant.

## Compatibility Contract

The following surface is stable unless a separately announced compatibility
migration says otherwise:

- package identity `ZenCODE` and Swift tools version 6.3;
- library products and imports `ZenCODECore`, `FeatureKit`, `ToolCore`,
  `FeatureMCPBridgeKit`, and `LocalToolsSupport`;
- executable `zen` and its ACP entry point;
- optional feature IDs, executable product names, tool names, selection
  prefixes, source-relative paths,
  and the `--list-tools` / `--invoke` JSON envelopes;
- settings, profiles, permissions, session snapshots,
  feature manifests, per-workspace memory graphs, and cache key formats;
- public installer entry points under `Scripts/install*.sh`.

`Package.swift` remains the authoritative declaration of the SwiftPM graph,
platform conditions, products, and build flags. Every local Swift target enables
`MemberImportVisibility`: each source file must import the module that defines
members it uses, while `public import` is reserved for intentional API re-exports.
`ZenBundledFeatureCatalog` is the runtime catalog authority for optional feature
identity. Every catalog entry owns a standalone SwiftPM package at its
`sourceRelativePath` under `Sources/Features`; the root `Package.swift`
intentionally declares none of their executable products or targets. Parity
checks ensure that every package has its catalog product and the marker
`// zencode:package-path` immediately above `.package(path: "../../..")`.
That marked dependency is rewritten when the package is installed outside the
checkout. Linux eligibility remains an explicit `isInstalledOnLinux` catalog
property, so `xcode-tools` remains visible as bundled metadata but cannot be
installed or executed there. Generic MCP bridge scaffolding and execution are
currently macOS-only; Linux eligibility must remain false for every bundled MCP
feature until `FeatureMCPBridgeKit` has a real Linux transport and lifecycle test
suite rather than an unsupported-platform stub.

`xcode-tools` is a macOS-only optional package and owns its entire integration:
MCP bridge discovery and policy, request compatibility, workspace matching,
execution, presentation, and tests. The root graph exports no Xcode feature
product and `ZenCODECore` imports no Xcode implementation module. Linux builds
retain only the generic bundled-feature identity, description, selection aliases,
and timeout required for catalog parity; they compile no Xcode implementation or
compatibility shim.

Presentation content crosses frontend boundaries through the transient,
backend-neutral `PresentationDocument` tree under `ZenCODE/Presentation`.
Domain presentation nodes contain only visible text, semantic blocks and opaque
already-uploaded document references; they contain no Telegram types, local file
paths, reasoning records or tool payloads. Transport adapters depend inward on
that tree: the Telegram adapter renders the supported subset to Bot API 10.3
`InputRichMessage` wire values, while the presentation layer never imports or
names Telegram. Rich draft and final delivery share the Telegram outbound
governor. An explicit 400/404 compatibility rejection may degrade to the tree's
deterministic plain-text projection; ambiguous transport/server outcomes never
trigger a second final send. The tree is not persisted, so settings, session,
checkpoint and transcript formats remain unchanged.

Optional feature packages are not executables distributed beside `zen`. The
installer and `zen --install-features` copy a package to
`~/.zencode/features/<id>/`, generate the same manifest shape used by a local
Builder feature, build its release product there, and enable it only after the
build succeeds. The installer retains its source checkout at
`~/.zencode/source/` (or under `ZENCODE_SUPPORT_DIRECTORY`) when it was
bootstrapped from a temporary URL checkout, so later installs can resolve the
root package; an installer launched from a local checkout continues to use that
checkout. Existing user-created Builder packages keep the same discovery,
manifest, and selection contracts.

The task control plane follows the same compatibility rule: `SessionTaskOrchestrator` is the sole mutable owner, task checkpoint schema 1 is written atomically per project/session, and saved-session v4 embeds the checkpoint tree (`SessionCheckpointTree`) alongside the current graph. Schema-1 task graphs may carry additive optional `TaskGraphSavedPlan` metadata: `/plan save` writes a draft graph into a stable project plan-library logical session, preserving the goal and complete plan text beside the existing todo-derived tasks while checkpoints without that field remain decodable. Keeping that library separate from the live chat session lets a logical chat reset delete its own execution checkpoint without deleting explicitly saved plans. `/plan load` requires that no plan is active, reads the newest library metadata into a new unapproved plan, and does not take over previous execution state. Approval materializes every plan into the current session's graph; a text-only legacy plan receives one stable task rather than an inferred task breakdown. Sessions saved before v4 are not loadable. Backend replacement may rebuild transient model state but must not discard the graph; only a logical session reset deletes its checkpoint. Startup recovery identifies work by the pair `sessionID + graphID`, not by session alone: the selected graph must become active/current and that `currentGraphID` must be persisted before backend creation. A checkpoint's formerly current graph must never replace a different graph explicitly selected by the operator.

`CoordinatorCommandParser` under Agent Core owns shared recognition and transport
routing for `/plan`, `/goal`, and `/review`; `PlanningCommandKernel` owns the
shared planning and workflow semantics consumed by the TUI, Telegram adapter, and
ACP bridge: hidden coordination prompts, Planner identity and output-revision
fencing, structured `todo.write` projection, and coordinator history replacement.
Frontends retain only transport-specific presentation and lifecycle adaptation. An
unfinished Planner clarification is deliberately
runtime-only, non-`Codable` state: it survives ordinary turns and agent/profile
reconfiguration in the same live session, but new-session, load/resume, setup
restart, close, and shutdown boundaries discard it and close its Planner. It is
never inferred from replayed chat, saved sessions, plan-library metadata, or task
checkpoints. ACP additionally fences every completion by session id, epoch,
active prompt id, collection id, and the runner's session-generation token.
History replacement is serialized with runner creation/recreation; teardown
preemptively invalidates its generation. Cancelled or stale command turns roll
back their own history or task-graph mutation before a new incarnation may adopt
it.

The live messages (`AgentSharedChat`) is deliberately transient: the operator, coordinator, and active delegated agent instances share a bounded, in-memory room that is never written to a session snapshot or task checkpoint. The human operator is a trusted, unregistered sender that never occupies a room slot or mailbox, keeping it distinct from the coordinator LLM. The coordinator authorises at most one synthetic turn from the messages at a time, bound to the prompt it consumes, so a message can never open a second concurrent generation. Delivery is priority-based for every recipient with an active turn: its mailbox is reserved for that turn's direct-tool executor, which appends pending messages only to the model-facing result of the next tool call so the recipient replies immediately and then resumes its current work; visible tool output is unchanged. Idle and standby agents drain into their serial work loop normally. If an active turn ends before another tool boundary, the coordinator monitor or agent work-loop re-arm drains the mailbox and starts the ordinary synthetic/queued fallback turn. Every active observer receives each message from the bounded transcript replay (delivery is deduplicated by message id); the live room is surfaced by the terminal TUI and the linked Telegram chat; the terminal TUI routes these messages only to its transient `Chat` reader rather than the main transcript, and an observer that falls behind recovers from the transcript on the next poll rather than losing messages; shared-chat messages are never dropped from the terminal event queue. The reader is invisible when closed with no messages, compact with total and unread counts when closed with messages, compact for an empty open state, and expanded for an open state with messages. Readable `@mention` handles are derived from participant display names by an actor-isolated catalogue, routing always resolves back to the stable participant id, aliases are never recycled within a session, and the legacy `@agent-Base64` spelling remains accepted for backward compatibility. No shared-chat state is persisted or restored; `SessionTaskOrchestrator` remains the sole owner of any checkpointed graph state.

Telegram uses one process-wide `TerminalTelegramBotDispatcher` per bot as the
exclusive owner of long polling and offset persistence. It broadcasts raw
updates to active control services before those services apply their room ACL,
so no session can acknowledge and discard another session's traffic. Ingress is
resolved only by `TerminalTelegramSessionRouter`; the resulting lease includes
the ACL route generation and a separate effective forum topic. That lease is
carried through queue admission, generation cancellation, route-scoped
permission state, drafts/cards and final egress, with validation before every
route-scoped turn side effect. Chat-wide fallback ACLs therefore do not collapse forum
topics. Stop is an awaited barrier for poll subscription, presence, rate state,
consents and temporary files. Outbound consent captures SHA-256 at offer time
and the multipart encoder verifies the hash while reading the exact bytes that
will be sent.

## Provider Boundary

ZenCODE composes its agent backend exclusively from remote providers reached
over the network: OpenAI-compatible HTTP endpoints and the browser-authenticated
subscription bridges. This remote-provider boundary is an intentional,
announced compatibility migration, not an incidental gap: the runtime holds no
model weights and performs no inference in-process, so generation, token
budgeting, and any model/attention cache belong to the provider. `zen` remains
the only composition root that selects a backend, and it injects the chosen
remote provider through the same runtime contracts described below. The
client-side persistence surface stays local and provider-agnostic: session
snapshots, checkpoint trees, task graphs, permissions, feature manifests, and
the session cache-key formats survive a change of provider, while only transient
per-request model state is rebuilt.

The prompt-skill tools (`skills.list`, `skills.read`) are intrinsic, always-on
tools owned by `AgentCoreSessionRunner` as a per-session mutable
`PromptSkillSessionProvider`. Their descriptors and the single static skill
instruction in the system prompt are part of the stable remote session identity
from creation — even with no skills selected — so adding or removing a skill
updates only the provider snapshot (via `updatePromptSkillSelection`) and never
the system prompt, allowlist, cache key, history, or remote continuation. The
model discovers the current selection at runtime through `skills.list` and loads
guidance through `skills.read`. `skills.read` also accepts an optional relative
`resource` within the selected skill; the provider resolves it under that skill's
boundary, never exposes absolute paths, and does not require a filesystem tool.
Revocation is non-retroactive (it blocks future reads but cannot erase guidance
already in the conversation without sacrificing the continuation). A session
persisted with a legacy eager/lazy skill catalog is normalized to the static
instruction on restore, which is a one-time full replay; subsequent selection
changes are cache-stable.

Remote generation has one cross-platform transport stack. HTTP/1.1, incremental
SSE, and ChatGPT Responses WebSockets under `Remote/Generation`, the ChatGPT
client/task/pool, and Anthropic messages are expressed as `RemoteHTTP*` /
`RemoteWebSocket*` values and executed only by `RemoteTransportCore` on
SwiftNIO. Those paths must not select an implementation through platform
conditions, Foundation networking, Network, or libcurl. The `CLibCURLWebSocket`
target and its adapter are retired; no system curl linker dependency remains.

Feature invocations may add an optional `attachments` array to the successful
`--invoke` envelope. Each `FeatureInvocationAttachment` names an absolute local
image path plus its kind and content metadata; `FeatureRunner` emits the field
only for outputs conforming to `FeatureInvocationAttachmentProviding`, so the
legacy envelope remains byte-for-byte unchanged for ordinary feature tools.
`ZenCODECore` must read and validate each declared file before it becomes an
`AgentRuntimeAttachment`, retain it on the tool message in session snapshots,
and map it to the provider's native multimodal form. Chat Completions receives a
text tool result followed by a grouped user image message, Responses receives a
`function_call_output` followed by `input_image` content, and Anthropic embeds
the image content inside `tool_result`. A feature-generated image path must
never be sent to the remote provider as a substitute for the image bytes.

Feature manifests may opt into the additive `supportsPersistentSession` flag.
For those features, the session-owned `SwiftFeatureRuntime` starts one private
`--serve` JSON-lines process and reuses it for runtime discovery plus subsequent
invocations; reload, explicit shutdown, or runtime teardown closes the process.
The transport is opt-in and internal: the stable one-shot `--list-tools` and
`--invoke` commands and their JSON envelopes remain unchanged. `xcode-tools`
uses this mode so its package-local MCP executor and Xcode consent live for the
whole ZenCODE session instead of being recreated for every tool call.

`RemoteTransportCore()` borrows the process-wide NIO event-loop group. A client
that constructs its own transport closes it during `shutdown()`; an explicitly
injected transport remains owned by its embedding composition root. The ChatGPT
pool follows the same rule: `closeAll()` is reusable, while its terminal
`shutdown()` closes its default owned transport. Historical `urlSession`
initializer labels and properties remain typed compatibility values for source
consumers, but are never consulted for generation I/O. The compatibility facade
is deliberately isolated from the transport engine; it preserves API inspection
and injection without restoring a second networking path.

The root ChatGPT Subscription session prefers Responses WebSockets, but transport
availability is session-scoped rather than mandatory. Delegated ChatGPT
sub-agent backends start directly on HTTP/SSE: each delegated backend remains
reusable after completing work, so allowing every one to retain an independent
WebSocket would accumulate uncoordinated long-lived connections across parallel
batches. Structured transient Responses failures and transport failures retry on
a fresh WebSocket within the bounded replay-safe budget, matching Codex; an HTTP
426 upgrade rejection or exhaustion of that budget switches a root logical agent
session to HTTP/SSE for all later turns and tool rounds. The HTTP
scope key combines the logical session with its installation generation, remains
independent of the rotating WebSocket transport ID, and survives continuation
resets without leaking into a recreated session incarnation. Closing that
incarnation fences late activation and cancels any HTTP stream that is opening or
active. The transport client never replays events after replay-unsafe reasoning,
refusal, content, or tool output crosses its callback boundary. At the generation
boundary, an unexpected transient transport interruption receives one bounded
full-turn retry on a fresh transport connection even when provisional stream
callbacks have started: final assistant content and tool calls remain buffered
until a terminal event, so the failed accumulator can be discarded without
duplicating a committed assistant response or executing a tool twice. HTTP/SSE
completion requires a terminal Responses event; `[DONE]` or EOF alone cannot
commit partial output.
Structured `error` events use stable transient identifiers
(`server_error`, `server_is_overloaded`, `slow_down`,
`websocket_connection_limit_reached`, or `previous_response_not_found`) or a
wrapped 5xx status. A `response.failed` event is also retryable by event
provenance after known context, quota, policy, and malformed-request identifiers
have been excluded, matching Codex even when the backend omits a transient code.
When received again over HTTP/SSE, these failures retry within the bounded stream
budget only when no replay-unsafe output crossed the callback boundary. A valid
provider retry delay on a rate-limit failure takes precedence over the local
exponential backoff. Message text or callback errors alone can never activate
that retry. Authentication failures retain their token-refresh path on both
transports.

Each opened HTTP/SSE response and upgraded WebSocket separates its public handle
from the NIO driver actor that the scoped `executeThenClose` run-task retains.
`RemoteHTTPBody` / `RemoteHTTPStreamingResponse` / `RemoteSSEEventStream` (and
their iterators) and `RemoteWebSocketConnection` are the handles; they retain a
shared internal `RemoteTransportLifetimeToken`, while the run-task captures only
the driver actor and a weak reference to the token. Releasing the last handle
copy closes the channel lease, cancels the run-task, and abandons the driver's
continuation-based waiters, so the run-task completes and the driver is released
even when a consumer stops draining a stream. This is reached only through
actual handle release, never through a `channel.closeFuture` observation: the NIO
inbound iterator stays the sole authority for a clean end-of-stream versus a
Content-Length or framing truncation error, so such errors are never masked as a
clean `nil` (the earlier regression).


Authentication remains intentionally separate from generation transport.
ChatGPT uses the macOS local-browser callback (including its callback listener)
and the non-macOS device-code flow; its OAuth exchanges retain their
provider-specific behavior. Anthropic retains its hosted authorization-code
flow and OAuth exchange behavior. These Auth/Callback-only differences may use
platform APIs where required, but must not change provider IDs, wire event
handling, credential persistence, backend selection semantics, or the common
generation transport.

`SensitiveManifestCoordination` is the cross-process ownership boundary for
cooperative writes and destructive reset of application-support manifests.
Setup captures a read-only compare-and-swap baseline, validates the final
`settings.json`/`agents.json` pair, and commits it under one lock with a
restrictive recovery journal. Transactional publish/delete steps synchronize the
parent directory so journal, manifests, and cleanup retain their ordering across
system crashes. The journal is rollback-first: successful unlink is the commit
point, while any earlier interruption restores the original generation.
Delegation loads the pair under that same lock and completes such recovery
before routing. Individual
files continue to use `SensitiveFilePermissions` for symlink rejection, `0600`
temporary inodes, data synchronization, and atomic rename. Test and embedding scopes
that need a different support root use `AppStorageDirectory`'s lexical
`TaskLocal` override; the historical process-wide override remains compatible.

## Target Layout

The root product surface is intentionally simplified: interactive setup now
belongs to `ZenCODECore`, and the former `ZenCODESetup` product/target has been
removed as an explicit migration.

| Area | Intended responsibility and directory layout |
| --- | --- |
| `Sources/ToolCore` | Dependency-light wire, descriptor, environment, compatibility, declarative tool-presentation types, and the dependency-safe `ToolSecretRedactor` used by lower-level process/transport modules. It contains no registry or presentation policy keyed by tool name and does not contain Xcode- or Figma-specific request or workspace behavior. |
| `Sources/FeatureKit` | Feature contracts, schemas, process protocol, runner support, and shared process-tree supervision/TERM→KILL escalation; depends on `ToolCore`. `Process/` owns the lifecycle primitives both one-shot and persistent feature processes reuse: a race-safe typed one-shot signal (exit observation and termination requests), descriptor helpers (idempotent SIGPIPE ignore, non-blocking switches, quiet close), and a bounded SIGTERM→grace→SIGKILL escalator with cancellation-aware exit waits, so `FeatureProcessRunner` and `FeaturePersistentProcess` retain orchestration and JSON-lines protocol responsibilities without duplicating low-level state machines. Every `FeatureTool` owns and publishes its explicit `ToolPresentationDefinition`; `--list-tools` requires the same contract for generated and bundled features. Outputs may conform to `FeatureInvocationAttachmentProviding` to add validated local images to the model's multimodal tool context. |
| `Sources/FeatureMCPBridgeKit` | Generic MCP feature integration, configuration, transports, OAuth, execution, injectable local-transport policy hooks, and typed shared MCP pump/transport units. Local stdout, stderr, and diagnostics all drain through one bounded `MCPStreamPump` with a single cancellation/EOF/policy-stop/read-failure contract; per-stream differences are expressed as typed handlers, line framing is owned by a bounded accumulator, and the former single stream-handling file is decomposed into focused readers, stdio events, message routing, transport policy, process lifecycle, and logging units so no file combines pumping, diagnostic policy, JSON-RPC routing, and pending-response completion. It has no Xcode- or Figma-specific endpoint, reachability, or workspace behavior; optional feature packages own those policies. |
| `Sources/Features/FigmaTools` | Standalone Figma MCP feature package. It owns the Figma Desktop endpoint and reachability policy and passes only generic MCP configuration into `FeatureMCPBridgeKit`; the generic bridge kit must not contain Figma-specific factories or network probes. |
| `Sources/Features/XcodeTools` | Standalone macOS-only `xcode-tools-feature` package. Its package-local `XcodeToolsFeature` library owns MCP configuration and policy, compatibility normalization, workspace selection, discovery, execution, presentation, and error mapping; its thin executable delegates to that private implementation. The package depends only on the root's generic `FeatureKit`, `ToolCore`, and `FeatureMCPBridgeKit` products. |
| `Sources/Features/BrowserTools/Sources/BrowserToolsFeature` | `BrowserToolsFeature` library target owned by the standalone Browser package: the opt-in Chrome/CDP Browser runtime, direct URL policy plus a per-invocation Fetch/DNS request guard, persistent page handles, fixed viewport presets, scoped state reset, bounded semantic observations, snapshot-bound DOM/computed-CSS inspection, page and element wait/assertions, guarded interactions, redacted/filterable network diagnostics, decoded-pixel screenshot comparison with Browser-owned diff artifacts, and PNG/PDF artifacts. It denies downloads fail-closed, must not enable Browser in a default agent profile, and must not expose raw CDP/JavaScript evaluation or selectors to the model. The request guard is not a persistent network sandbox: pages may keep running between one-shot feature invocations, so durable isolation requires a separate browser guardian/proxy or host firewall boundary. |
| `Sources/Features/BrowserTools/Sources/browser-tools-feature` | Thin `browser-tools-feature` executable target that delegates to `BrowserToolsFeatureRunner`. |
| `Sources/Features/DesktopTools` | Standalone macOS-only `desktop-tools-feature` package exposing the single typed tool `desktop.run`: permission/system inspection, app and window enumeration, PNG screenshots attached to the model's multimodal context, pointer/keyboard/clipboard input, and app/window management through AppKit, Accessibility, and Quartz. It must never execute caller-supplied shell or AppleScript code, must not be enabled in a default agent profile, and requires Screen Recording plus Accessibility consent (`action=permissions` first). `isInstalledOnLinux` is `false` because the platform integration does not exist there. |
| `Sources/LocalToolsSupport` | Reusable local file, search, text, and patch tooling. |
| `Sources/ZenCODECore/ZenCODE/Memory/Engine` | Internal memory implementation area within the `ZenCODECore` target; it is not a separate Foundation-only module or public product. It is an MIT-licensed independent Swift implementation of the memory architecture of `1jehuang/jcode`, attributed in `THIRD_PARTY_NOTICES.md`. It owns the memory graph, typed edges, lexical retrieval through a pluggable `MemoryIndex` protocol (default `BM25MemoryIndex`), optional semantic retrieval through a pluggable `EmbeddingProvider` (reciprocal-rank fusion only when one is present), a breadth-first cascade with depth decay, the confidence lifecycle, persistence, and embedding provider protocols. The graph, BM25 path, default selectors, and persistence remain dependency-free; opt-in OpenAI-compatible transport adapters and ZenCODE diagnostic seams live in the same implementation-private target and are not installed when a store opens. Retrieval is also pluggable end to end through a `MemoryQueryAnalyzer` (default `DirectMemoryQueryAnalyzer`, which uses the prompt verbatim as the query), a `MemorySelector` (default `TopScoreMemorySelector`), a `MemoryExtractor` (default `NoopMemoryExtractor`, which extracts nothing) and a `MemoryContextFormatter` (default `BulletMemoryContextFormatter`); every default is dependency-free and makes no network call. The engine additionally exposes `context(for:)` (a ready-to-inject memory block) and `learn(from:)` (automatic extraction), and ships LLM-backed analyzer/selector/extractor implementations over the `MemoryLanguageModel` / `OpenAICompatibleChatModel` contracts; all of these stay unwired engine internals — opening a product store never installs a network-backed extractor or makes a generation request. ZenCODECore wires only automatic recall through its `MemoryTurnCoordinator`: it calls the store's `context(for:scope:)` inline before every turn and is on by default over the dependency-free BM25 path (no second LLM call — the formatted block rides the turn's own outgoing request). Durable entries are read and written explicitly by the main model through the five `memory.*` tools (`memory.read` / `memory.search` / `memory.write` / `memory.update` / `memory.archive`), guided by `MemoryService.toolUsagePromptSection()`. The `MemoryVerifier` protocol is deprecated in favour of `MemorySelector`. This source area is implementation-private within `ZenCODECore`, not a separate SwiftPM target or public library product. |
| `Sources/ZenPackageMetadata` | Internal bundled-feature distribution metadata used for catalog parity; it is not a public product. |
| `Sources/Features/<Feature>` | A self-contained optional SwiftPM package with its own `Package.swift`, `Sources/<product-name>/`, and package-local `Tests/`. It is outside the root graph; keep the entry point thin and place implementation in feature-owned support or library targets. The marker `// zencode:package-path` must immediately precede the root `.package(path: "../../..")` dependency so installation can rewrite only that path. |
| `Sources/ZenCODECore/ZenCODE` | Runtime domains: `Agent`, `Remote`, `Tools`, `Features`, `Context`, `Memory`, `FileChanges`, `Runtime`, `Setup`, `Telegram`, and `Support`; `ZenCODETUI` and ACP remain source areas within this target. The `Memory` domain is an async facade over the internal `Memory/Engine` implementation: `MemoryGraphLocation`, `MemoryGraphStore`, `LegacyMemoryJournal`, `MemoryService`, `MemoryLegacyCompatibility` (the deprecated 1.1.x synchronous surface), and the automatic-recall pipeline (`MemoryTurnCoordinator`, `MemoryTurnContext`, `MemoryAutomationSettings`). `MemoryService+Documents.swift` is removed. ZenCODECore exposes its own public DTOs (`MemoryEntry`, `MemoryScope`, `MemoryCategory` under `ZenCODE/Models`) that preserve the 1.1.x contract (`id: UUID`, `Hashable`, journal-shaped scope); the internal engine implementation keeps its graph types hidden behind the facade. |
| `Sources/ZenCODECore/ZenCODE/Tools/Direct/SubAgents` | Delegated-agent lifecycle and dispatch. `agent.create` requires a configured profile and derives the child tool grant exclusively from that profile; model-authored creation arguments and task metadata cannot add, remove, or replace profile tools. Only runtime-intrinsic skill discovery and task-attempt reporting tools are added, then the profile's `readOnly` core-tool policy is reapplied so those additions cannot restore mutation access. |
| `Sources/ZenCODECore/ZenCODE/Setup` | Interactive first-run and in-process configuration for providers, models, agents, feature packages, Telegram, voice, response language, and optional memory embeddings. Setup remains invoked by the executable composition root even though its implementation and contracts belong to Core. |
| `Sources/ZenCODECore/ZenCODE/Runtime/Sessions` | Neutral session state and persistence, including the authoritative task DAG, attempt fencing, execution scopes, atomic task-graph checkpoints, startup enumeration/recovery, and the session checkpoint tree (`SessionCheckpointTree`). Workflow-sourced graphs require sub-agent execution attempts, while coordinator tool grants remain independent of that lifecycle constraint. Startup recovery is graph-specific: the orchestrator restores the owning session, interrupts persisted active attempts, activates exactly the operator-selected graph, archives superseded active graphs, and persists `currentGraphID` before backend creation. A negative validation persists `failed`; `tasks.retry` returns the task to `pending`, and retrying a failed attempt always claims a fresh workflow attempt through a new `agent.create(taskID:)` rather than resuming the prior agent. Separately, once a task-bound attempt completes, the agent may optionally remain in a runtime-only, non-persisted `.standby` state for conversational follow-up turns over direct messages that do not mutate the task graph; standby is bounded by a turn budget and an idle timeout, and is released when the graph becomes terminal, when a newer attempt supersedes it, or when the budget/timeout is exhausted. Standby turns are never task attempts, never reopen the completed attempt, and never change `task.activeAttemptID`. `AgentCoreSessionRunner` owns one orchestrator and injects it into every backend; its internal `AgentCoreBackendManager`, `AgentCoreSessionSnapshotStore`, and `AgentCoreAuthorizationRouter` isolate backend generations, session snapshot incarnations, and authorization lifecycle without changing the runner facade. The runner declaration itself keeps only actor state, initializers, local-exec access mode, session creation/options, and skill selection, with domain companions (`+PromptTurn`, `+SessionLifecycle`, `+SharedChat`, `+SnapshotAuthorization`, `+MCP`, `+Tasks`, `+SavedSessions`) implementing prompt-turn execution, session/backend lifecycle, shared-chat turns, snapshot/authorization routing, MCP wiring, task-graph projection, and saved-session persistence for the same actor. Direct task tools are stateless adapters and TUI/ACP code only projects or requests orchestrator-owned snapshot restoration. |
| `Sources/ZenCODECore/ZenCODE/Telegram` | Telegram remote-control runtime: Bot API transport, long-polling, pairing, channel state, voice-attachment download, tool-call permission brokering, safe tool-call presentation, and the ordered per-turn progress reporter. It depends only on `Foundation`/`FoundationNetworking`, `ToolCore`, and neutral runtime contracts (`Agent` settings, `Agent` tool-authorization requests, `ToolCallPresentation`, voice input); it must not depend on terminal presentation types. `TerminalChat+Telegram.swift` under `ZenCODETUI` is the only adapter that binds this runtime to input, rendering, and prompt-queue surfaces. |
| `Sources/ZenCODECore/ZenCODE/ACP` | ACP protocol adaptation only: JSON-RPC routing, parsing, lifecycle, and event encoding. Tool-call updates are wire-normalized here: the richer internal presentation kinds are mapped onto the closed ACP set (`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`), and `locations` are absolute paths resolved against the session workspace rather than the agent process directory. |
| `Sources/ZenCODECore/ZenCODETUI` | Terminal-only state, input, rendering, and presentation. `TerminalChatRenderCoordinator` is the sole actor owner of stateful chat writes and streaming formatter/cursor state; the coordinator declaration itself keeps only actor state, initializers, and cursor topology, while cohesive implementation units live in same-domain extension files (streaming and write coalescing, transcript messages, tool-block lifecycle and row ownership, overview arbitration and mirror FIFO, diagnostics/snapshot barriers, and low-level channel output). Its actor-confined overview arbitration, mirror FIFO, tool-block accounting, and per-channel/pending-write value state live in `TerminalChatRenderState` value types, while stateless text normalization lives in `TerminalChatTextFormatting`, `TerminalMarkdownStreamFormatter` owns incremental Markdown state, and `TerminalWidth` centralizes cached terminal-width probes. `TerminalStatusBar` separately owns status and input-panel rendering state. Shared runtime types must not be introduced here. Telegram runtime lives under `ZenCODE/Telegram`; `TerminalChat+Telegram.swift` is only the adapter that binds that runtime to terminal input, rendering, and prompt-queue surfaces. |
| `Sources/zen` | The executable composition root, command-line dispatch, automatic first-run setup, `/setup` handler injection, and optional-feature installer CLI. Core reports a setup request with an in-memory conversational snapshot and `ZenCODECommandLineRunner` rebuilds `AgentConfiguration` plus the TUI while reusing the session runner; the composition root invokes `ZenCODESetupRunner`, so the task graph remains owned by the same orchestrator. |
| `Tests` | Root-package unit targets: `ToolCoreTests`, `FeatureKitTests`, `FeatureMCPBridgeKitTests`, `LocalToolsSupportTests`, and `ZenCODECoreTests`. Memory-engine suites live under `Tests/ZenCODECoreTests/Memory/Engine`; setup suites live under `Tests/ZenCODECoreTests/Setup`. Feature packages, including XcodeTools, own and run their package-local tests separately. |

The former public `ZenCODESetup` module is intentionally folded into
`ZenCODECore`; repository consumers import `ZenCODECore` for setup APIs.

## Dependency Direction

Arrows point from a dependency to its consumer. The actual direction is from
reusable leaf/support modules toward the runtime and executable composition
root:

```text
ToolCore ──→ FeatureKit ──→ LocalToolsSupport
    └────────────────────→ FeatureMCPBridgeKit
FeatureKit ──────────────→ FeatureMCPBridgeKit

ZenPackageMetadata ─────→ ZenCODECore

ZenCODECore / ZenPackageMetadata ───────────────────────────────→ zen

ZenCODE root products ──→ Sources/Features/<Feature>/Package.swift
                              ├───────────────────────────────→ package-local implementation
                              └───────────────────────────────→ feature executable
```

`FeatureMCPBridgeKit` depends on `FeatureKit` and `ToolCore`;
`BrowserToolsFeature` depends on `FeatureKit` and is composed only by its thin
package-local `browser-tools-feature` executable; the package-local
`XcodeToolsFeature` implementation depends on the generic MCP support products
and is composed only by its package-local `xcode-tools-feature` executable;
`LocalToolsSupport` depends on `FeatureKit`; `ZenCODECore` contains the internal
`Memory/Engine` source area and consumes all generic support targets plus
`ZenPackageMetadata`, including the interactive setup implementation.
`ZenCODETUI` and ACP may consume neutral runtime
contracts, but Agent, Remote, and ACP code must not depend on terminal
presentation types. Remote providers receive backend factories through runtime
contracts rather than constructing Agent coordinators directly. `zen` is the
only composition root for backend selection.

## Memory Ownership and Persistence

Project memory is owned by the internal `ZenMemory` engine at
`Sources/ZenCODECore/ZenCODE/Memory/Engine`; ZenCODECore's public `Memory`
domain is a thin async facade over it (`MemoryService` →
`MemoryGraphStore` → `ZenMemory` actor). The authoritative store is the
per-workspace graph file at
`<supportDirectory>/memory/<sha256(workspacePath)>/memory.graph.json`, where
`<sha256(workspacePath)>` is the full SHA256 hex digest of the standardized
workspace path and `<supportDirectory>` honours `ZENCODE_SUPPORT_DIRECTORY`
(default `~/.zencode`). The graph is written atomically as sorted-key
pretty-printed JSON and is deliberately kept out of the workspace working tree
because it may embed float vectors. A process-wide `MemoryGraphStoreRegistry`
caches one open store per graph URL so parallel tool executions share a single
engine instance.

`MEMORY.md` is no longer written. An existing project `MEMORY.md` is a
read-only legacy source: it is parsed and imported into the graph on first
open when no graph file exists yet. The migration runs entirely in memory —
`open` never persists — so a cold read (`memory.search` / `memory.read`) on a
workspace whose graph file does not yet exist neither creates the file nor
fails when the support directory is not writable. The first transactional
mutation (or automatic recall maintenance) atomically persists the full
graph. Because entry identity is deterministic, repeated cold migrations
converge on the same nodes. Once a mutation has created the graph file,
subsequent opens load it directly and skip migration. `MEMORY.md` is left
byte-for-byte untouched on disk. A `MEMORY.md` that exists but cannot be
parsed safely refuses to migrate rather than silently dropping entries. Entry
identity survives migration: `[id: …]` markers keep their UUID, and legacy
entries without one receive the same deterministic UUIDv8 the previous
implementation derived, so ids remain stable across the format change.

Every mutation — `write`, `update`, `archive`, `delete` — runs through the
engine's transaction primitive
(`ZenMemory.transaction(_:)`), which commits after save: the body mutates a
private draft of the graph, the draft is persisted first, and it becomes the
live graph only when the save succeeded. A throwing body or a failed save
therefore changes nothing — the in-memory graph stays exactly as it was instead
of silently diverging from disk — and a body that left the graph unchanged never
touches disk. The transaction also serializes read-modify-write sequences that
would otherwise interleave across actor suspension points, and it re-checks
`Task.checkCancellation()` after the write lock is acquired and before the
body/save: a task cancelled while parked at the lock neither commits nor
strands the lock. The graph JSON carries `graph_version` (currently 2); a file
written by a newer engine is rejected on load and left byte-identical, while
older files decode through optional fields with contract defaults (`scope` →
`.project`, `active` → `true`, …). A file with no `graph_version` key at all is
the legacy v1 format (`MemoryGraph.legacyGraphVersion`): it is decoded with the
same contract defaults and normalized to the current version in memory. Loading
never rewrites the file — the on-disk graph stays byte-identical until an
explicit save (a mutation) writes the current version.

ZenCODECore exposes its own public DTOs (`MemoryEntry`, `MemoryScope`,
`MemoryCategory`) declared under `ZenCODE/Models`; the internal `ZenMemory`
engine implementation stays behind the facade (internal aliases bridge the two).
The facade API is async first: `MemoryService`'s
primary methods (`readEntries`, `searchEntries`, `entry`, `writeEntry`,
`updateEntry`, `archiveEntry`, `setArchived`, `deleteEntry`) are `async throws`
and keyed by `workspaceRootURL:`. The modern tool entry point is
`MemoryTool.executeAsync(_:context:memoryService:)`; it was renamed from
`execute` so the legacy synchronous `execute` — the exact 1.1.x spelling — is
the only `execute` overload and `try MemoryTool.execute(…)` compiles unchanged
from both sync and async call sites. The pre-graph 1.1.x synchronous surface
survives as deprecated wrappers (`MemoryLegacyCompatibility.swift`) that keep
the old `scope:` / `workingDirectory:` labels and block the calling thread
through a deadlock-safe bridge (from both sync and async call sites) with
read/mutation-split timeout semantics: a
legacy read uses a bounded wait (60 s) and may be abandoned on timeout — a
late read result is harmless because reads have no durable side-effect — while
a legacy mutation never reports "abandoned": if the bounded wait expires the
bridge keeps waiting for the definitive outcome without cancelling, so a commit
is never reported as abandoned. Moving to the async API means renaming the
labels to `workspaceRootURL:` and adding `try await`. The legacy nil-directory semantics
are preserved on the wrappers: reads return `[]` (the 1.1.x behaviour), while
mutations throw `scopeUnavailable`; the modern async API is uniformly throwing —
a nil `workspaceRootURL` fails with `scopeUnavailable` for reads and mutations
alike. `scope` is accepted on the wrappers for source compatibility and only
`.project` is backed by a per-workspace graph. Retrieval
is BM25-first: `ZenMemory.recall` always runs lexical retrieval through the
pluggable `MemoryIndex` protocol (default `BM25MemoryIndex`) and uses those hits
as seeds, then a breadth-first relation cascade with depth decay and
per-retrieval confidence boost/decay. `memory.search` is strictly read-only: the
store's `search` runs the engine's `searchReadOnly` path, which shares the same
analyze → retrieve → select pipeline as recall but performs no transactional
maintenance — it never mutates `retrievalCount`/`confidence`/links and cannot
fail on a save error — while automatic recall (`context(for:)`) keeps its
maintenance-bearing path unchanged. Automatic recall revalidates before it
commits: the maintenance transaction re-checks the retrieved candidates and
the selected set against the current graph draft, dropping any entry a
concurrent forget/archive/scope change made stale while the selector was
awaiting, and co-relevance linking only ever connects live endpoints (linking
a missing or inactive node is a no-op), so no dangling edges are persisted and
the returned result never contains eliminated entries. Without an embedder,
BM25 is the sole seed source; reciprocal-rank fusion is applied only when an
embedder is configured, merging the semantic and lexical rankings before the
cascade.

Embeddings are opt-in and off by default. With no provider configured, entries
carry no vector and retrieval is pure BM25 plus graph expansion. The persisted
settings manifest (`AgentMemoryEmbeddingSettingsManifest`, manifest version 12,
`settings.json` `memoryEmbedding`) stores a normalized absolute HTTP(S)
endpoint — plus, optionally, an OpenAI-compatible `model` identifier and a
non-secret `providerID` reference to a configured provider whose API key the
resolver reuses at runtime. Legacy v11 endpoint-only values decode unchanged
(`model`/`providerID` nil) and re-encode byte-identically. Setup configures it
interactively ("Memory embeddings": BM25 only / add / change / remove endpoint,
detail line "BM25 only" or the stored endpoint, with the model appended when
present). When at least one configured provider is OpenRouter, setup proposes an
OpenRouter choice immediately, precompiled to the canonical endpoint
`https://openrouter.ai/api/v1/embeddings` with model `qwen/qwen3-embedding-8b`
and the referenced provider's ID; without an OpenRouter provider no such
proposal appears. The manual add/change-endpoint path stays endpoint-only by
design: it never carries over the preset's model/provider reference, so an
edited endpoint cannot silently reuse the provider's key. Setup validates the
URL format entirely locally: it never
probes the endpoint, never enumerates models, and never asks for credentials.
The embedding request never duplicates the provider's API key: when
`providerID` is set the resolver reads
`remoteAPIKeysByProviderID[providerID.uuidString.lowercased()]` at runtime only
if the reference resolves to a configured OpenRouter provider **and** the
embedding endpoint is itself an OpenRouter endpoint; any mismatch (custom or
legacy endpoint-only setups, a stale `providerID`, an endpoint on a different
host) sends the request without Authorization, so a manipulated `settings.json`
can never forward an OpenRouter key to an arbitrary host. For compatibility,
the legacy environment variable
`ZENCODE_MEMORY_EMBEDDING_ENDPOINT` is still honoured as a fallback when the
manifest field is absent (i.e. a legacy v10 install that never went through
setup); an explicitly disabled manifest suppresses it. `MemoryEmbedding.provider(...)`
resolves task-local override first, then manifest endpoint or disabled, then
environment only when the manifest field is absent, then BM25. The endpoint
identifies the embedding model itself: `OpenAICompatibleEmbeddingProvider` derives a stable
endpoint-hash `modelID` when none is supplied and deliberately omits `model`
from the request body, so an endpoint-only server chooses; a stored `model` is
sent in the request body instead. The engine still
ships `DeterministicHashEmbeddingProvider` (a 128-dimension signed feature-hashing
bag-of-words encoder, not a semantic model), but it is no longer wired in by
default. Entries record their `embeddingModel`, so a provider change degrades to
lexical retrieval instead of returning wrong matches. Provider resolution sits
behind a task-local seam (`MemoryEmbedding.withProvider(_:operation:)`). Under
a test harness the real process environment is never consulted: resolution
returns no provider — and makes no network call — unless a test explicitly
binds one through the seam, so memory tests stay hermetic even when the
developer's shell exports `ZENCODE_MEMORY_EMBEDDING_ENDPOINT`.

Automatic recall is on by default and adds no second LLM call. Before every
turn — operator and delegated sub-agent alike — `MemoryTurnCoordinator`
resolves the workspace graph and runs the store's `context(for:scope:)`
inline: offline BM25 seeds, graph expansion, and selection through
`ScoreThresholdMemorySelector`. Without an endpoint, retrieval is local BM25
and costs no extra round trip; with an endpoint, a bounded HTTP call to the
embedding service adds semantic similarity and fusion. Neither adds a second
LLM call — what reaches the wire is the formatted block, which
does add input tokens to the outgoing request and is therefore bounded by a
character budget (`ZENCODE_MEMORY_RECALL_MAX_CHARACTERS`, default 4 000
characters, clamped to [200, 32 000]; ZenCODE counts roughly four characters
per token, so the default is about 1k tokens of recalled memory). The whole
pipeline, including on a cold workspace the one-time graph open and
`MEMORY.md` migration, races `ZENCODE_MEMORY_RECALL_TIMEOUT_MS` (default
150 ms, clamped to [10, 5000]); the first side to finish wins and the loser is
abandoned rather than awaited, so a turn waits at most the budget. Every
failure — timeout, throw, cancellation, empty result — resolves to no block,
which makes the outgoing request byte-identical to one sent with memory
switched off. A session is auto-disabled after three consecutive unusable
recall attempts; any success resets the counter, and closing or resetting a
session discards its state.

The engine's N→N+1 `submitContext(_:)` / `takePending()` pipeline is
deliberately not used. `ZenMemory.pending` is a single unkeyed array on the
engine actor, while `MemoryGraphStoreRegistry` caches exactly one store — and
so one engine — per workspace graph URL, shared by every concurrent session,
sub-agent, and tool call in that workspace. A wholesale drain would hand one
session the memories retrieved for another's prompt; inline per-prompt
retrieval keeps every recall bound to the prompt that asked for it.

The block travels out-of-band through
`MemoryTurnContext.currentTurnMemoryBlock`, a task-local bound around
`sendPrompt`. At request assembly,
`RemoteGenerationClient.applyingCurrentTurnMemory(to:)` merges it into the
outgoing copy of the last user message — the single shared injection point
for all three concrete generation clients, so the wire formats cannot drift.
Callers apply it on every tool round against the fresh value of
`session.messages`, so each round's outgoing copy carries the block exactly
once. `session.messages` is never mutated, so the block never enters
conversation history, saved-session snapshots, or the session cache key;
saved-session and prompt-cache compatibility are preserved. The alternatives
were rejected on purpose: `systemPrompt` participates in the session cache
key, and `dynamicContext` is compared by
`matchesSessionIdentityIgnoringThinking`, so either would rotate the cache key
or force a `createSession` on every turn.

The block is an explicitly labelled container (`<project-memory>` …
`</project-memory>`) so the model reads it as background context, not as text
the user just typed. Two properties are enforced when it is built: recalled
content is escaped so no `project-memory` tag inside an entry can close the
container (both the `<project-memory` and `</project-memory` spellings are
rewritten to `&lt;project-memory` / `&lt;/project-memory`, case-insensitively,
leaving code otherwise untouched), and the payload is
truncated to the recall character budget on line boundaries, appending a
truncation notice when the selection did not fit. The fixed header, the tags
and the notice are constant overhead on top of the budgeted payload.

The main model owns durable memory explicitly through the five `memory.*` tools
— `memory.read`, `memory.search`, `memory.write`, `memory.update`,
`memory.archive` — guided by `MemoryService.toolUsagePromptSection()` (search
before writing, update instead of duplicating, archive stale entries, prefer
fresh evidence over memory). `MemoryTurnCoordinator` drives recall only, and
`MemoryTurnCoordinator.discard(sessionID:)` drops only per-session recall health
state on close/reset/rebuild. The engine's `learn(from:)`, its default
`NoopMemoryExtractor` (which extracts nothing), and its LLM-backed extractor
stay unwired internals of `ZenMemory`, so no product code path ever performs an
extraction request.

ZenCODECore installs its own `ScoreThresholdMemorySelector` (a `MemorySelector`)
in place of the engine's default `TopScoreMemorySelector`. The default returns
every candidate up to `maxResults`, which would defeat the engine's
post-retrieval maintenance: every retrieved entry would be boosted and none
decayed (confidence flattens toward 1.0), and `selected.count >= 2` would nearly
always hold, so every recall would link its results pairwise at weight 0.7,
saturating the graph until cascade retrieval degenerates into noise. The
threshold selector keeps only candidates scoring at least half of the top hit,
restoring decay for weak candidates and limiting co-relevance linking to
genuinely strong matches. It makes no LLM call and no network request:
BM25/cascade scores have no absolute scale (they depend on corpus statistics),
so the cutoff is relative to each recall's best hit rather than a fixed
threshold. The engine's `MemoryVerifier` protocol is deprecated in favour of
`MemorySelector`. The five `memory.*` tool names
and the read-only vs mutating descriptor split are unchanged; `memory.write`
reports what actually happened — the tool emits `written`/`deduplicated` from
the store's `(entry, created)` outcome (`writeEntryOutcome`), so a write that
deduplicated against an active entry is reported as a duplicate returning the
existing entry, not as a save. `memory.update`
is an in-place content replacement that preserves the entry id (it does not
supersede), and no `global` memory scope is implemented or advertised — only
`project`. The public DTO surfaces only `.project`; the store maps it
internally to the engine's scope (`.all`) for `memory.search` and the
automatic recall pipeline, so the richer engine scopes never leak through the
facade.

## Telegram Single-Owner Routing and Persistence

Telegram routing is an authorization boundary, not presentation state. Schema 2
persists one global private-chat identity in `settings.json`; routes describe only
the owner's terminal sessions and optional private topics:

```json
{
  "telegram": {
    "enabled": true,
    "botToken": "…",
    "linkedChatID": 42,
    "linkedChatTitle": "…",
    "ownerUserID": 7,
    "routingVersion": 2,
    "routes": [{
      "topicID": 12,
      "roomID": "room-id",
      "lifecycle": "active",
      "generation": 1
    }]
  }
}
```

`TerminalTelegramSessionRouter` accepts ingress only when both the private chat
and sender match `(linkedChatID, ownerUserID)`. It serializes route create,
close, delete, resolution and validation; each mutation persists its normalized
draft before publishing it in memory. A lease retains the complete
`(chatID,userID,topicID?,roomID)` key and route generation, so suspended work
cannot cross an owner, session, lifecycle or generation change. A closed exact
topic stays closed. A missing or deleted topic may use the unique active
`topicID: null` fallback. Groups, supergroups, member lists and per-route ACLs
are unsupported and fail closed.

There is no schema-1 compatibility or runtime owner claim. Any non-schema-2,
ownerless or incoherent configuration is inactive and must be paired again.

`TerminalTelegramRouteRuntimeState` partitions prompt queue, attempted-delivery
ledger, draft ownership and reply receipts by the complete route key. Reply
targets must name the same room. Text prompt origins retain that key through the
TUI queue, and Bot API persistent sends carry the matching
`message_thread_id`. Stop-generation updates contain no reliable user identity:
they can only request cancellation of a locally owned `(route,draftID)` and are
never authorization evidence. Native drafts are optional private-chat UX.
Teardown removes one route bucket, while generation validation prevents late
work from recreating it. No Mini App or web deployment is part of this
architecture.

## Consumer Migration Note

The remaining root library products and imports, `zen`, and generated
Builder-feature wire and persistence contracts remain compatible. The former
`ZenCODESetup` product was intentionally folded into `ZenCODECore`; consumers
that imported it must depend on and import `ZenCODECore` instead. The former
root `XcodeToolsFeature` product was also intentionally removed: consumers must use
the standalone optional package rather than importing its implementation.
Optional feature executables
are no longer installed beside the `zen` binary or built by the root package.
Install the desired package with `zen --install-features [id,id,...]` (or select
it in setup) before selecting its tools. Installed catalog packages use the
same `~/.zencode/features/<id>/` layout and feature manifest behavior as a
Builder-created local feature. `ZenPackageMetadata` remains an internal
implementation detail.

The terminal-rendering concurrency migration is an intentional source-level
exception: `TerminalChat` operations that may render or update terminal UI are
async and callers must await them. Observable CLI output remains compatible;
the actor boundary prevents independent tasks from mutating formatter, cursor,
overlay, or status-bar state concurrently.

## Migration Rules

1. Add characterisation tests before moving a path that participates in JSON,
   persistence, feature adoption, or build discovery.
2. Make test imports direct in `Package.swift`; do not rely on transitive test
   dependencies.
3. Replace `#filePath` parent-count assumptions with a package-root resolver
   before moving source or test files.
4. Keep mechanical moves separate from behavioral fixes. A moved file should
   preserve public symbols and observable output.
5. Update source paths, package excludes, feature registry entries, scripts,
   and their parity tests in the same change.
6. Preserve existing test suite names during the first relocation so filters
   continue to work.
7. Retire aliases, facades, and legacy paths only in a later compatibility
   release after consumer and persisted-state migration coverage exists.

## Validation Gates

Every structural checkpoint must at least build the affected target and run its
focused tests. Before a release, resolve only from the tracked
`Package.resolved`, validate the root package graph, build `ZenCODECore`, run
the complete non-live root test suite with `swift test --no-parallel`, and build
the release `zen` product. An
optional feature change additionally runs `swift test` from its own
`Sources/Features/<Feature>` package (with an isolated scratch directory) and
checks its `--list-tools` output after installation. Validate shell syntax with
`bash -n Scripts/*.sh`, and finish with `git diff --check`.

The version/release contract is documented in [release.md](release.md): a
`vX.Y.Z` tag must equal `ZenPackageMetadata.version`, and release installers
receive the same immutable tag or full commit SHA through `--ref`. The tracked
GitHub Actions workflow mirrors the ordinary macOS/Linux non-live gate; network
and installer execution remain dedicated validation tasks rather than routine
checks for a layout-only change.
