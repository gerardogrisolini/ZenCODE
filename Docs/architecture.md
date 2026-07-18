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
  `ToolCore`, `FeatureMCPBridgeKit`, `XcodeToolsFeature`, `LocalToolsSupport`,
  and the conditional MLX products;
- executable `zen`, its `--mlx`, `--ds4`, and ACP entry points, and the
  bundled feature executable names;
- bundled feature IDs, tool names, selection prefixes, source-relative paths,
  and the `--list-tools` / `--invoke` JSON envelopes;
- settings, profiles, permissions, session snapshots (including the
  `.mlxsession` extension), feature manifests, and cache key formats;
- public installer entry points under `Scripts/install*.sh` and the build
  flags `ZENCODE_BUILD_LOCAL_MLX`, `ZENCODE_BUILD_DS4`,
  `ZENCODE_DS4_ROOT`, and legacy `DS4_ROOT`.

`Package.swift` remains the authoritative declaration of the SwiftPM graph,
platform conditions, products, and build flags. `ZenBundledFeatureCatalog` is the runtime
bundled-feature distribution catalog authority; parity checks reconcile its
records with the manifest and installer catalogs. On Linux,
`swift-tools-feature` is omitted from installation, not from the SwiftPM
product set.

The task control plane follows the same compatibility rule: `SessionTaskOrchestrator` is the sole mutable owner, task checkpoint schema 1 is written atomically per project/session, and saved-session v4 embeds the checkpoint tree (`SessionCheckpointTree`) alongside the current graph. Sessions saved before v4 are not loadable. Backend replacement may rebuild transient model state but must not discard the graph; only a logical session reset deletes its checkpoint.

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
| `Sources/LocalToolsSupport` | Reusable local file, search, text, and patch tooling. |
| `Sources/ZenPackageMetadata` | Internal bundled-feature distribution metadata used for catalog parity; it is not a public product. |
| `Sources/Features/<Feature>` | A standalone executable feature root. Keep its entry point thin and place implementation in feature-owned support or library targets; Xcode Tools is the library-plus-executable exception described above. |
| `Sources/ZenCODECore/ZenCODE` | Runtime domains: `Agent`, `Remote`, `Tools`, `Features`, `Context`, `Memory`, `FileChanges`, `Runtime`, and `Support`; `ZenCODETUI` and ACP remain source areas within this target. |
| `Sources/ZenCODECore/ZenCODE/Runtime/Sessions` | Neutral session state and persistence, including the authoritative task DAG, attempt fencing, execution scopes, atomic task-graph checkpoints, and the session checkpoint tree (`SessionCheckpointTree`). Workflow-sourced graphs require sub-agent execution attempts, while coordinator tool grants remain independent of that lifecycle constraint. A negative validation persists `failed`; `tasks.retry` returns the task to `pending`, and a new `agent.create(taskID:)` claims its fresh workflow attempt rather than messaging the completed agent. `AgentCoreSessionRunner` owns one orchestrator and injects it into every backend; direct task tools are stateless adapters and TUI/ACP code only projects or restores snapshots. |
| `Sources/ZenCODECore/ZenCODE/ACP` | ACP protocol adaptation only: JSON-RPC routing, parsing, lifecycle, and event encoding. |
| `Sources/ZenCODECore/ZenCODETUI` | Terminal-only state, input, rendering, and presentation. `TerminalChatRenderCoordinator` is the sole owner of stateful chat writes and streaming formatter/cursor state; its stateless text normalization lives in `TerminalChatTextFormatting`, while `TerminalMarkdownStreamFormatter` owns incremental Markdown state and `TerminalWidth` centralizes cached terminal-width probes. `TerminalStatusBar` separately owns status and input-panel rendering state. Shared runtime types must not be introduced here. |
| `Sources/LocalRuntimeSupport` | Internal local-runtime backend-selection support; it depends on `ZenCODECore` and is not a public product. |
| `Sources/ZenCODESetup` | Interactive standalone-agent setup. |
| `Sources/MLXServerCore` | Conditional local MLX runtime, catalog, loading, generation gate, and disk KV cache. |
| `Sources/MLXServerSetup` | Conditional local MLX settings and model configuration, including Hugging Face discovery and setup; it is not the MLX runtime itself. |
| `Sources/DS4RuntimeShim` | Conditional C shim compiled only when DS4 support is enabled. |
| `Sources/zen` | The executable composition root, command-line dispatch, bundled feature wiring, and optional MLX/DS4 adapters. |
| `Tests` | Unit targets: `ToolCoreTests`, `FeatureKitTests`, `FeatureMCPBridgeKitTests`, `XcodeToolsFeatureTests`, `LocalToolsSupportTests`, `ZenCODECoreTests`, `ZenCODELocalRuntimeTests`, and `ZenCODESetupTests`; conditional targets: `MLXServerCoreTests`/`MLXServerSetupTests` with MLX and `ZenCODEDS4Tests` with DS4. |

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

ZenPackageMetadata ──┬──→ ZenCODECore ──→ ZenCODESetup
                     │                  ├→ LocalRuntimeSupport
                     │                  └→ MLXServerSetup (conditional)
                     └──→ MLXServerCore ─→ MLXServerSetup (conditional)

ZenCODECore / ZenCODESetup / LocalRuntimeSupport ──────────────┐
ZenPackageMetadata / bundled feature executables ──────────────┤
MLXServerSetup (conditional) / DS4RuntimeShim (conditional) ──┤
                                                               ↓
                                                              zen
                              (only `zen` composes optional MLX/DS4 adapters)
```

`FeatureMCPBridgeKit` depends on `FeatureKit` and `ToolCore`;
`XcodeToolsFeature` depends on those generic MCP support targets;
`LocalToolsSupport` depends on `FeatureKit`; and `ZenCODECore` consumes all
five support targets plus `ZenPackageMetadata`. `LocalRuntimeSupport` and
`ZenCODESetup` depend on `ZenCODECore`. `MLXServerSetup` depends on
`ZenCODECore` and conditional `MLXServerCore`; `MLXServerCore` depends on
`ZenPackageMetadata`. `ZenCODETUI` and ACP may consume neutral runtime
contracts, but Agent, Remote, and ACP code must not depend on terminal
presentation types. Remote providers receive backend factories through runtime
contracts rather than constructing Agent coordinators directly. `zen` is the
only composition root for local backend selection.

## Consumer Migration Note

No consumer action is required for the source reorganization. Public products
and imports, `zen`, bundled feature executables, CLI behavior, and wire and
persistence contracts remain unchanged. Consumers depend on SwiftPM products
and modules, not repository source paths; internal targets such as
`LocalRuntimeSupport` and `ZenPackageMetadata` are implementation details.

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
focused tests. Before release, validate the remote-only graph, the default MLX
graph, and DS4 graphs when a valid DS4 checkout is available. Use the same
backend flags for build and test, check feature `--list-tools` output, validate
shell syntax with `bash -n Scripts/*.sh`, and finish with `git diff --check`.

Live MLX, DS4, network, and installer execution are dedicated validation tasks;
they are not routine local checks for a layout-only change.
