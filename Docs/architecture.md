# Architecture and Layout

This document records the repository layout contract used when reorganising
ZenCODE. It is intentionally conservative: moving an implementation file must
not silently change a public module, executable, protocol, persistent format,
or build variant.

## Compatibility Contract

The following surface is stable unless a separately announced compatibility
migration says otherwise:

- package identity `ZenCODE` and Swift tools version 6.3;
- library products and imports `ZenCODECore`, `ZenCODESetup`, `FeatureKit`,
  `ToolCore`, `FeatureMCPBridgeKit`, `XcodeToolsFeature`, and
  `LocalToolsSupport`;
- executable `zen` and its ACP entry point;
- optional feature IDs, executable product names, tool names, selection
  prefixes, source-relative paths,
  and the `--list-tools` / `--invoke` JSON envelopes;
- settings, profiles, permissions, session snapshots,
  feature manifests, and cache key formats;
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
property, so `xcode-tools` is excluded there.

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

The task control plane follows the same compatibility rule: `SessionTaskOrchestrator` is the sole mutable owner, task checkpoint schema 1 is written atomically per project/session, and saved-session v4 embeds the checkpoint tree (`SessionCheckpointTree`) alongside the current graph. Sessions saved before v4 are not loadable. Backend replacement may rebuild transient model state but must not discard the graph; only a logical session reset deletes its checkpoint. Startup recovery identifies work by the pair `sessionID + graphID`, not by session alone: the selected graph must become active/current and that `currentGraphID` must be persisted before backend creation. A checkpoint's formerly current graph must never replace a different graph explicitly selected by the operator.

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
guidance through `skills.read`; revocation is non-retroactive (it blocks future
reads but cannot erase guidance already in the conversation without sacrificing
the continuation). A session persisted with a legacy eager/lazy skill catalog is
normalized to the static instruction on restore, which is a one-time full replay;
subsequent selection changes are cache-stable.

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
active. Events that already emitted replay-unsafe reasoning, refusal, content,
or tool output are never replayed or moved between transports. HTTP/SSE
completion requires a terminal Responses event; `[DONE]` or EOF alone cannot
commit partial output. Structured `error` events use stable transient identifiers
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

## Target Layout

The established public products remain stable while internal targets and source
layout are made explicit.

| Area | Intended responsibility and directory layout |
| --- | --- |
| `Sources/ToolCore` | Dependency-light wire, descriptor, environment, compatibility, and declarative tool-presentation types. It contains no registry or presentation policy keyed by tool name and does not contain Xcode-specific request or workspace behavior. |
| `Sources/FeatureKit` | Feature contracts, schemas, process protocol, and runner support; depends on `ToolCore`. Every `FeatureTool` owns and publishes its explicit `ToolPresentationDefinition`; `--list-tools` requires the same contract for generated and bundled features. Outputs may conform to `FeatureInvocationAttachmentProviding` to add validated local images to the model's multimodal tool context. |
| `Sources/FeatureMCPBridgeKit` | Generic MCP feature integration, configuration, transports, OAuth, execution, and injectable local-transport policy hooks. It has no Xcode-specific behavior. |
| `Sources/XcodeToolsFeature` | `XcodeToolsFeature` library target in the main graph: Xcode MCP configuration, policy, compatibility normalization, workspace selection, discovery, execution, and error mapping. |
| `Sources/Features/XcodeTools` | Standalone `xcode-tools-feature` package. Its thin executable target delegates to the `XcodeToolsFeature` product exported by the root package. |
| `Sources/Features/BrowserTools/Sources/BrowserToolsFeature` | `BrowserToolsFeature` library target owned by the standalone Browser package: the opt-in Chrome/CDP Browser runtime, direct URL policy plus a per-invocation Fetch/DNS request guard, persistent page handles, fixed viewport presets, scoped state reset, bounded semantic observations, snapshot-bound DOM/computed-CSS inspection, page and element wait/assertions, guarded interactions, redacted/filterable network diagnostics, decoded-pixel screenshot comparison with Browser-owned diff artifacts, and PNG/PDF artifacts. It denies downloads fail-closed, must not enable Browser in a default agent profile, and must not expose raw CDP/JavaScript evaluation or selectors to the model. The request guard is not a persistent network sandbox: pages may keep running between one-shot feature invocations, so durable isolation requires a separate browser guardian/proxy or host firewall boundary. |
| `Sources/Features/BrowserTools/Sources/browser-tools-feature` | Thin `browser-tools-feature` executable target that delegates to `BrowserToolsFeatureRunner`. |
| `Sources/LocalToolsSupport` | Reusable local file, search, text, and patch tooling. |
| `Sources/ZenPackageMetadata` | Internal bundled-feature distribution metadata used for catalog parity; it is not a public product. |
| `Sources/Features/<Feature>` | A self-contained optional SwiftPM package with its own `Package.swift`, `Sources/<product-name>/`, and package-local `Tests/`. It is outside the root graph; keep the entry point thin and place implementation in feature-owned support or library targets. The marker `// zencode:package-path` must immediately precede the root `.package(path: "../../..")` dependency so installation can rewrite only that path. |
| `Sources/ZenCODECore/ZenCODE` | Runtime domains: `Agent`, `Remote`, `Tools`, `Features`, `Context`, `Memory`, `FileChanges`, `Runtime`, and `Support`; `ZenCODETUI` and ACP remain source areas within this target. |
| `Sources/ZenCODECore/ZenCODE/Runtime/Sessions` | Neutral session state and persistence, including the authoritative task DAG, attempt fencing, execution scopes, atomic task-graph checkpoints, startup enumeration/recovery, and the session checkpoint tree (`SessionCheckpointTree`). Workflow-sourced graphs require sub-agent execution attempts, while coordinator tool grants remain independent of that lifecycle constraint. Startup recovery is graph-specific: the orchestrator restores the owning session, interrupts persisted active attempts, activates exactly the operator-selected graph, archives superseded active graphs, and persists `currentGraphID` before backend creation. A negative validation persists `failed`; `tasks.retry` returns the task to `pending`, and a new `agent.create(taskID:)` claims its fresh workflow attempt rather than messaging the completed agent. `AgentCoreSessionRunner` owns one orchestrator and injects it into every backend; direct task tools are stateless adapters and TUI/ACP code only projects or requests orchestrator-owned snapshot restoration. |
| `Sources/ZenCODECore/ZenCODE/ACP` | ACP protocol adaptation only: JSON-RPC routing, parsing, lifecycle, and event encoding. |
| `Sources/ZenCODECore/ZenCODETUI` | Terminal-only state, input, rendering, and presentation. `TerminalChatRenderCoordinator` is the sole owner of stateful chat writes and streaming formatter/cursor state; its stateless text normalization lives in `TerminalChatTextFormatting`, while `TerminalMarkdownStreamFormatter` owns incremental Markdown state and `TerminalWidth` centralizes cached terminal-width probes. `TerminalStatusBar` separately owns status and input-panel rendering state. Shared runtime types must not be introduced here. |
| `Sources/ZenCODESetup` | Interactive standalone-agent setup. |
| `Sources/zen` | The executable composition root, command-line dispatch, setup, and optional-feature installer CLI. |
| `Tests` | Root-package unit targets: `ToolCoreTests`, `FeatureKitTests`, `FeatureMCPBridgeKitTests`, `XcodeToolsFeatureTests`, `LocalToolsSupportTests`, `ZenCODECoreTests`, and `ZenCODESetupTests`. Feature packages own and run their package-local tests separately. |

The names of existing targets, products, executables, and feature roots are not
renamed during the first reorganisation pass. A future target split is allowed
only after the destination boundary has focused tests and a compatibility facade
where external imports require one.

## Dependency Direction

Arrows point from a dependency to its consumer. The actual direction is from
reusable leaf/support modules toward the runtime and executable composition
root:

```text
ToolCore ──→ FeatureKit ──→ LocalToolsSupport
    └────────────────────→ FeatureMCPBridgeKit
FeatureKit ──────────────→ FeatureMCPBridgeKit
ToolCore / FeatureKit / FeatureMCPBridgeKit ──→ XcodeToolsFeature

ZenPackageMetadata ─────→ ZenCODECore ──→ ZenCODESetup

ZenCODECore / ZenCODESetup / ZenPackageMetadata ───────────────→ zen

ZenCODE root products ──→ Sources/Features/<Feature>/Package.swift
                              └───────────────────────────────→ feature executable
```

`FeatureMCPBridgeKit` depends on `FeatureKit` and `ToolCore`;
`BrowserToolsFeature` depends on `FeatureKit` and is composed only by its thin
package-local `browser-tools-feature` executable; `XcodeToolsFeature` depends
on the generic MCP support targets and remains a root-package library consumed
by the package-local `xcode-tools-feature` executable;
`LocalToolsSupport` depends on `FeatureKit`; and `ZenCODECore` consumes all
five support targets plus `ZenPackageMetadata`. `ZenCODESetup` depends on
`ZenCODECore`. `ZenCODETUI` and ACP may consume neutral runtime
contracts, but Agent, Remote, and ACP code must not depend on terminal
presentation types. Remote providers receive backend factories through runtime
contracts rather than constructing Agent coordinators directly. `zen` is the
only composition root for backend selection.

## Consumer Migration Note

The root library products and imports, `zen`, and generated Builder-feature
wire and persistence contracts remain compatible. Optional feature executables
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
the complete non-live root test suite, and build the release `zen` product. An
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
