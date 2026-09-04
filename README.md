![ZenCODE](Docs/Images/social-preview.png)

[![CI](https://github.com/gerardogrisolini/ZenCODE/actions/workflows/ci.yml/badge.svg)](https://github.com/gerardogrisolini/ZenCODE/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gerardogrisolini/ZenCODE?sort=semver)](https://github.com/gerardogrisolini/ZenCODE/releases)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL-blue)](#install)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**ZenCODE** is a fast, native-Swift coding agent for the terminal and ACP. Bring any
OpenAI-compatible API key or sign in with your existing ChatGPT or Claude subscription —
no API key required. One compiled binary, no Node runtime, running on macOS, Linux, and
Windows (via WSL), all the way down to a Raspberry Pi.

## Highlights

- **Provider-agnostic** — any OpenAI-compatible endpoint (OpenRouter, local servers, any `/v1` API), or a browser sign-in with your ChatGPT or Claude subscription.
- **Native Swift, small footprint** — a single compiled binary with no interpreter or Node event loop, suitable for constrained ARM boards.
- **Runs everywhere** — macOS, Linux, and Windows (via WSL); model inference stays on the remote provider, so even a single-board computer can host the agent.
- **Automation-friendly** — run a one-shot prompt as plain text or consume the versioned `--jsonl` lifecycle stream from scripts and CI.
- **ACP native** — connects over stdio to compatible clients, including **Xcode 27**, as a native coding agent.
- **Agentic workflows** — dependency-aware task graph with `/plan`, `/goal`, and `/review`; `/plan save` and `/plan load` hand plans between sessions of the same project, plus [capability-based delegation](Docs/bindings.md) to specialized sub-agents.
- **Live agent chat** — while sub-agents run, the operator, coordinator, and agent instances share a transient chat room: message the coordinator or broadcast to all agents from the terminal with `@coordinator` / `@all`, or reach a specific agent by its handle. See [agents.md](Docs/agents.md).
- **Task recovery at startup** — incomplete task graphs are detected per project and presented in a scrollable picker, so you can resume the exact graph you selected or remove obsolete work before starting a new session.
- **Durable project memory** — workspace-scoped facts are recalled automatically without bloating conversation history; default retrieval stays local with BM25, and optional embeddings add semantic ranking.
- **Full control over tools** — granular `/tools` selection (filesystem, shell, Git, search, memory, sub-agents, Xcode, Figma, features), with change tracking and `/undo` as a safety net. Successful file edits return compact path-and-count confirmations instead of post-edit context or diffs.
- **Extensible** — the Builder generates reusable Dynamic Swift Features as durable tools; skills are selectable per session and installable from GitHub or a local folder.

See [Why ZenCODE](Docs/why-zen.md) for the full rationale.

## Providers

ZenCODE supports several ways to run the model, all selected during automatic first-run setup or later with `/setup`:

- **Cloud API providers** — bring an API key for any OpenAI-compatible endpoint, including OpenRouter, local servers, and any `/v1`-compatible provider.
- **ChatGPT Subscription** — sign in with your existing ChatGPT subscription through the browser. No API key required.
- **Claude Subscription** — sign in with your existing Claude (Anthropic) subscription through the browser. No API key required.

## Run

- `zen` opens the standalone terminal coding agent.
- `zen -p "Summarize the current changes"` runs one headless turn and prints only
  the final assistant text.
- `zen --jsonl -p "Summarize the current changes"` emits a versioned JSON Lines
  lifecycle stream for scripts and CI. See the [JSONL protocol guide](Docs/jsonl.md).
- `zen --acp` runs the ACP stdio agent for compatible clients.

## Install

### macOS

```bash
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install.sh" \
  | bash -s -- --ref v2.1.3
```

`--ref` pins the source checkout to the release tag. Replace it with the latest
[published release](https://github.com/gerardogrisolini/ZenCODE/releases).
Omit it for a development build from the moving `main` branch:

```bash
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install.sh" \
  | bash
```

The installer labels a moving ref clearly as a development build. See
[release and reproducibility](Docs/release.md) for the full release procedure.

Requires macOS 26 (Tahoe), Apple Silicon, Git, and the Swift toolchain from
Xcode or the Apple command line tools.

### Linux and Windows via WSL

```bash
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install-linux.sh" \
  | bash -s -- --ref v2.1.3
```

For a development build from the moving `main` branch:

```bash
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install-linux.sh" \
  | bash
```

Drive the agent through configured remote providers. Running `zen` opens setup
automatically when configuration is missing or invalid; use `/setup` later to
reconfigure it without leaving the TUI. The standalone agent, TUI, and ACP bridge
work normally. Optional Swift feature packages are selected from the Features
step of `/setup`, or installed later with `zen --install-features`; they are
compiled on demand under
`~/.zencode/features/<id>/`, not distributed as executables next to `zen`.

Windows is supported through WSL. Install Ubuntu first, then run the Linux
installer inside the Ubuntu shell:

```powershell
wsl --install -d Ubuntu
```

The installer reuses a Swift toolchain already available on `PATH`. If Swift is
missing, it automatically installs the latest stable toolchain with Swiftly,
following the [official Linux installation instructions](https://www.swift.org/install/linux/).

`/setup` supports both subscription logins on Linux: ChatGPT uses the
device-code page and Claude asks for the authorization code shown by its hosted
OAuth flow. ChatGPT generation remains WebSocket-based and, together with
HTTP/SSE generation, uses the shared cross-platform SwiftNIO transport.

## Quick Start

Choose how ZenCODE runs — a cloud API provider, or a ChatGPT or Claude
subscription — in the setup that opens automatically on first launch:

```bash
zen
```

Use `/setup` from the TUI whenever you want to reconfigure it without closing
the app.

### Optional workspace guidance

`AGENTS.md` is optional. If a project needs workspace-specific instructions,
create and edit `AGENTS.md` manually in the working directory, then commit it
to version control when appropriate. When the file is present, ZenCODE reads it
and adds its contents to the agent's context; ZenCODE does not automatically
create or rewrite a project file.

This project file is separate from the global `~/.zencode/AGENTS.md`, which
contains operating guidance shared across workspaces. The global file applies
to every project, while a project `AGENTS.md` applies only to its working
directory.

## Build From Source

Use a source checkout when developing ZenCODE itself:

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
swift build -c release --product zen
./.build/release/zen --install-features swift-tools --zen-package-path "$PWD"
```

## TUI Commands

```text
/help        Show available commands
/setup       Reconfigure ZenCODE, then restore the current session
/models      Select a model for the current session
/agents      Select an agent profile
/tools       Select tool groups (`/tools logs` opens the system log viewer)
/skills      Select, install, or uninstall prompt skills (`/skills uninstall`)
/sessions    Manage sessions and checkpoint trees
/open        Open a referenced file, URL, or attachment
/changes     Review the latest tracked file changes
/undo        Revert the latest tracked agent changes
/tasks       Inspect, retry, cancel, or clear the session task graph
/plan        Create, save, load, approve, inspect, or clear a delegated session plan
/goal        Plan and delegate all work to sub-agents
/review      Review tracked changes and verify task/plan claims
/feature     Manage Swift features with the Builder agent
/telegram    Turn Telegram remote control on/off when paired in setup
/exit        Close the session
```

`/sessions` also handles snapshots and checkpoint trees
(`save`, `new`, `compact`, `delete`, `restore`). See the
[ZenCODE guide](Docs/zen.md#terminal-tui-commands) for the complete command
reference.

`/plan save` writes the active plan — or the latest non-empty assistant response
when no plan is active — to the current project's reusable plan library. In a
session with no active plan, `/plan load` presents the latest saved plan as an
unapproved draft for review; use `/plan approve` only when it is ready to
implement. The [Planner guide](Docs/planner.md#saving-and-loading-plans)
describes the complete handoff flow.

## Layout

- `Sources/ToolCore`: dependency-light tool wire, descriptor, environment, and compatibility types.
- `Sources/FeatureKit`: feature contracts, schemas, process protocol, and runner support.
- `Sources/FeatureMCPBridgeKit`: generic MCP feature integration, transports, and injectable local-transport policies.
- `Sources/LocalToolsSupport`: reusable local file, search, text, and patch tooling.
- `Sources/ZenPackageMetadata`: internal bundled-feature distribution metadata and catalog parity support.
- `Sources/ZenCODECore`: reusable agent runtime, interactive setup, TUI, tools, skills, ACP, config, memory, sessions, and feature management.
- `Sources/zen`: the `zen` composition root and command-line dispatch.
- `Sources/Features`: self-contained optional SwiftPM feature packages. They own their implementations and package-local tests, are excluded from the root graph, and are installed on demand into `~/.zencode/features/<id>/` as local Builder-compatible features. The macOS-only Xcode integration lives entirely in `Sources/Features/XcodeTools`.
- `Tests`: SwiftPM test targets.
- `Docs`: detailed guides and feature documentation.

## Development Commands

```bash
swift test
swift build -c release --product zen

zen --help
zen --doctor
zen --working-directory /path/to/project
zen --acp --working-directory /path/to/project
```

## More Docs

Start here — [Docs index](Docs/README.md).

**Using ZenCODE**
- [ZenCODE guide](Docs/zen.md) — modes, commands, sessions, orchestration.
- [Headless JSONL protocol](Docs/jsonl.md) — schema v1 records, lifecycle, errors, privacy, and automation examples.
- [Why ZenCODE](Docs/why-zen.md) — rationale and differences.

**Agents and delegation**
- [Agents and sub-agents](Docs/agents.md) — profiles, tools, delegation.
- [Model bindings](Docs/bindings.md) — agent/model/workflow bindings and capability routing.
- Profile guides: [Builder](Docs/builder.md), [Planner](Docs/planner.md), [Reviewer](Docs/reviewer.md), [Reporter](Docs/reporter.md).

**Integrations**
- [Xcode ACP setup](Docs/xcode.md)
- [Aion UI manual setup](Docs/aion-ui.md)

**Project**
- [Architecture and layout contract](Docs/architecture.md)
- [Release and reproducible installs](Docs/release.md)
- [Persisted credential security](Docs/security.md)

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the build
requirements, the validation gate CI enforces, and the architecture rules a
change must preserve. Release history lives in [CHANGELOG.md](CHANGELOG.md).

To report a vulnerability, follow [SECURITY.md](SECURITY.md) — please do not
open a public issue.

## License

ZenCODE is released under the [MIT License](LICENSE).
