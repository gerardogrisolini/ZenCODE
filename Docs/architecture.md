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
- executable `zen`, its ACP entry point, and the
  bundled feature executable names;
- bundled feature IDs, tool names, selection prefixes, source-relative paths,
  and the `--list-tools` / `--invoke` JSON envelopes;
- settings, profiles, permissions, session snapshots,
  feature manifests, and cache key formats;
- public installer entry points under `Scripts/install*.sh`.

`Package.swift` remains the authoritative declaration of the SwiftPM graph,
platform conditions, products, and build flags. `ZenBundledFeatureCatalog` is the runtime
bundled-feature distribution catalog authority; parity checks reconcile its
records with the manifest and installer catalogs. On Linux,
`swift-tools-feature` is omitted from installation, not from the SwiftPM
product set.

The task control plane follows the same compatibility rule: `SessionTaskOrchestrator` is the sole mutable owner, task checkpoint schema 1 is written atomically per project/session, and saved-session v4 embeds the checkpoint tree (`SessionCheckpointTree`) alongside the current graph. Sessions saved before v4 are not loadable. Backend replacement may rebuild transient model state but must not discard the graph; only a logical session reset deletes its checkpoint.

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

## Target Layout

The established public products remain stable while internal targets and source
layout are made explicit.

| Area | Intended responsibility and directory layout |
| --- | --- |
| `Sources/ToolCore` | Dependency-light wire, descriptor, environment, and compatibility types. It does not contain Xcode-specific request or workspace behavior. |
| `Sources/FeatureKit` | Feature contracts, schemas, process protocol, and runner support; depends on `ToolCore`. |
| `Sources/FeatureMCPBridgeKit` | Generic MCP feature integration, configuration, transports, OAuth, execution, and injectable local-transport policy hooks. It has no Xcode-specific behavior. |
| `Sources/Features/XcodeTools/Feature` | `XcodeToolsFeature` library target: Xcode MCP configuration, policy, compatibility normalization, workspace selection, discovery, execution, and error mapping. |
| `Sources/Features/XcodeTools/Executable` | Thin `xcode-tools-feature` executable target that delegates to `XcodeToolsFeatureRunner`. |
| `Sources/Features/BrowserTools/Feature` | `BrowserToolsFeature` library target: the opt-in Chrome/CDP Browser runtime, direct URL policy plus a per-invocation Fetch/DNS request guard, persistent page handles, fixed viewport presets, scoped state reset, bounded semantic observations, snapshot-bound DOM/computed-CSS inspection, page and element wait/assertions, guarded interactions, redacted/filterable network diagnostics, decoded-pixel screenshot comparison with Browser-owned diff artifacts, and PNG/PDF artifacts. It denies downloads fail-closed, must not enable Browser in a default agent profile, and must not expose raw CDP/JavaScript evaluation or selectors to the model. The request guard is not a persistent network sandbox: pages may keep running between one-shot feature invocations, so durable isolation requires a separate browser guardian/proxy or host firewall boundary. |
| `Sources/Features/BrowserTools/Executable` | Thin `browser-tools-feature` executable target that delegates to `BrowserToolsFeatureRunner`; it retains the stable bundled executable name and feature root. |
| `Sources/LocalToolsSupport` | Reusable local file, search, text, and patch tooling. |
| `Sources/ZenPackageMetadata` | Internal bundled-feature distribution metadata used for catalog parity; it is not a public product. |
| `Sources/Features/<Feature>` | A standalone executable feature root. Keep its entry point thin and place implementation in feature-owned support or library targets; Xcode Tools and Browser Tools use explicit library-plus-executable boundaries. |
| `Sources/ZenCODECore/ZenCODE` | Runtime domains: `Agent`, `Remote`, `Tools`, `Features`, `Context`, `Memory`, `FileChanges`, `Runtime`, and `Support`; `ZenCODETUI` and ACP remain source areas within this target. |
| `Sources/ZenCODECore/ZenCODE/Runtime/Sessions` | Neutral session state and persistence, including the authoritative task DAG, attempt fencing, execution scopes, atomic task-graph checkpoints, and the session checkpoint tree (`SessionCheckpointTree`). Workflow-sourced graphs require sub-agent execution attempts, while coordinator tool grants remain independent of that lifecycle constraint. A negative validation persists `failed`; `tasks.retry` returns the task to `pending`, and a new `agent.create(taskID:)` claims its fresh workflow attempt rather than messaging the completed agent. `AgentCoreSessionRunner` owns one orchestrator and injects it into every backend; direct task tools are stateless adapters and TUI/ACP code only projects or restores snapshots. |
| `Sources/ZenCODECore/ZenCODE/ACP` | ACP protocol adaptation only: JSON-RPC routing, parsing, lifecycle, and event encoding. |
| `Sources/ZenCODECore/ZenCODETUI` | Terminal-only state, input, rendering, and presentation. `TerminalChatRenderCoordinator` is the sole owner of stateful chat writes and streaming formatter/cursor state; its stateless text normalization lives in `TerminalChatTextFormatting`, while `TerminalMarkdownStreamFormatter` owns incremental Markdown state and `TerminalWidth` centralizes cached terminal-width probes. `TerminalStatusBar` separately owns status and input-panel rendering state. Shared runtime types must not be introduced here. |
| `Sources/ZenCODESetup` | Interactive standalone-agent setup. |
| `Sources/zen` | The executable composition root, command-line dispatch, and bundled feature wiring. |
| `Tests` | Unit targets: `ToolCoreTests`, `FeatureKitTests`, `FeatureMCPBridgeKitTests`, `XcodeToolsFeatureTests`, `BrowserToolsFeatureTests`, `LocalToolsSupportTests`, `ZenCODECoreTests`, and `ZenCODESetupTests`. |

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
FeatureKit ──────────────→ BrowserToolsFeature ──→ browser-tools-feature
ToolCore / FeatureKit / FeatureMCPBridgeKit ──→ XcodeToolsFeature

ZenPackageMetadata ─────→ ZenCODECore ──→ ZenCODESetup

ZenCODECore / ZenCODESetup ────────────────────────────────────┐
ZenPackageMetadata / bundled feature executables ──────────────┤
                                                               ↓
                                                              zen
```

`FeatureMCPBridgeKit` depends on `FeatureKit` and `ToolCore`; `BrowserToolsFeature`
depends on `FeatureKit` and is composed only by the thin `browser-tools-feature`
executable;
`XcodeToolsFeature` depends on those generic MCP support targets;
`LocalToolsSupport` depends on `FeatureKit`; and `ZenCODECore` consumes all
five support targets plus `ZenPackageMetadata`. `ZenCODESetup` depends on
`ZenCODECore`. `ZenCODETUI` and ACP may consume neutral runtime
contracts, but Agent, Remote, and ACP code must not depend on terminal
presentation types. Remote providers receive backend factories through runtime
contracts rather than constructing Agent coordinators directly. `zen` is the
only composition root for backend selection.

## Consumer Migration Note

No consumer action is required for the source reorganization. Public products
and imports, `zen`, bundled feature executables, CLI behavior, and wire and
persistence contracts remain unchanged. Consumers depend on SwiftPM products
and modules, not repository source paths; `ZenPackageMetadata` is an internal
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
focused tests. Before release, validate the remote-only graph. Check feature `--list-tools` output, validate
shell syntax with `bash -n Scripts/*.sh`, and finish with `git diff --check`.

Network and installer execution are dedicated validation tasks;
they are not routine local checks for a layout-only change.
