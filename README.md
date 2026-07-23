![ZenCODE](Docs/Images/social-preview.png)

**ZenCODE** is a fast, native-Swift coding agent for the terminal and ACP. Bring any
OpenAI-compatible API key or sign in with your existing ChatGPT or Claude subscription —
no API key required. One compiled binary, no Node runtime, running on macOS, Linux, and
Windows (via WSL), all the way down to a Raspberry Pi.

Keywords: ZenCODE, coding agent, AI coding assistant, cloud LLM agent, OpenAI-compatible coding agent, OpenRouter coding agent, ACP agent, terminal coding agent for macOS and Linux.

## Highlights

- **Provider-agnostic** — any OpenAI-compatible endpoint (OpenRouter, local servers, any `/v1` API), or a browser sign-in with your ChatGPT or Claude subscription.
- **Native Swift, tiny footprint** — a single compiled binary with no interpreter or Node event loop; a few MB of RAM at idle, small enough to run on constrained ARM boards.
- **Runs everywhere** — macOS, Linux, and Windows (via WSL); model inference stays on the remote provider, so even a single-board computer can host the agent.
- **ACP native** — connects over stdio to compatible clients, including **Xcode 27**, with a dedicated agent profile.
- **Agentic workflows** — dependency-aware task graph with `/plan`, `/workflow`, and `/review`, plus capability-based delegation to specialized sub-agents.
- **Full control over tools** — granular `/tools` selection (filesystem, shell, Git, search, memory, sub-agents, Xcode, Figma, features), with change tracking and `/undo` as a safety net.
- **Extensible** — the Builder generates reusable Dynamic Swift Features as durable tools; skills are selectable per session and installable from GitHub or a local folder.

See [Why ZenCODE](Docs/why-zen.md) for the full rationale.

## Providers

ZenCODE supports several ways to run the model, all selected through `zen --setup`:

- **Cloud API providers** — bring an API key for any OpenAI-compatible endpoint, including OpenRouter, local servers, and any `/v1`-compatible provider.
- **ChatGPT Subscription** — sign in with your existing ChatGPT subscription through the browser. No API key required.
- **Claude Subscription** — sign in with your existing Claude (Anthropic) subscription through the browser. No API key required.

## Run

- `zen` runs the standalone terminal and ACP coding agent with configured providers.

## Install

### macOS

```bash
VERSION=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/${VERSION}/Scripts/install.sh" \
  | bash -s -- --ref "$VERSION"
```

Replace `vX.Y.Z` with a published release tag. The tag pins both the downloaded
installer and its source checkout. For a development build from the moving
`main` branch, use the same URL with `main`; the installer labels it clearly as
a development build. See [release and reproducibility](Docs/release.md) for
the full release procedure.

Requires macOS 26 (Tahoe), Apple Silicon, Git, and the Swift toolchain from
Xcode or the Apple command line tools.

### Linux and Windows via WSL

```bash
VERSION=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/${VERSION}/Scripts/install-linux.sh" \
  | bash -s -- --ref "$VERSION"
```

Drive the agent through configured remote providers (`zen --setup`). The
standalone agent, TUI, ACP bridge, and bundled feature executables work
normally.

Windows is supported through WSL. Install Ubuntu first, then run the Linux
installer inside the Ubuntu shell:

```powershell
wsl --install -d Ubuntu
```

The installer reuses a Swift toolchain already available on `PATH`. If Swift is
missing, it automatically installs the latest stable toolchain with Swiftly,
following the [official Linux installation instructions](https://www.swift.org/install/linux/).

`zen --setup` supports both subscription logins on Linux: ChatGPT uses the
device-code page and Claude asks for the authorization code shown by its hosted
OAuth flow. ChatGPT generation remains WebSocket-based and, together with
HTTP/SSE generation, uses the shared cross-platform SwiftNIO transport.

## Quick Start

Choose how ZenCODE runs — a cloud API provider, or a ChatGPT or Claude subscription — during setup, then start the agent:

```bash
zen --setup
zen
```

## Build From Source

Use a source checkout when developing ZenCODE itself:

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
swift build -c release --product zen
```

## TUI Commands

```text
/help        Show available commands
/models      Select a model
/agents      Select an agent profile
/bindings    Show agent model bindings
/tools       Select tool groups
/skills      Select or install prompt skills
/sessions    Manage sessions and checkpoint trees:
               /sessions                 List and select saved sessions
               /sessions <name>          Save or overwrite a named snapshot
               /sessions save            Save the current session
               /sessions new             Start a fresh session
               /sessions compact         Compact context
               /sessions delete          Delete a snapshot
               /sessions tree            Show the checkpoint tree
               /sessions branches        List branches (leaves)
               /sessions checkpoint [label]  Create a checkpoint
               /sessions restore [id|index]   Restore in-place from a checkpoint
                                              (interactive picker when omitted)
/open        Open a referenced file, URL, or attachment
/changes     Review the latest tracked file changes
/undo        Revert the latest tracked agent changes
/tasks       Inspect, retry, cancel, or clear the persistent session task graph
/plan        Create, approve, inspect, or clear a delegated session plan
/workflow    Plan and delegate all work to sub-agents from the current agent
/review      Review tracked changes and verify task/approved-plan claims
/feature     List, enable, disable, create, and manage Swift features with the Builder agent
/telegram    Turn Telegram remote control on/off when paired in setup
/voice       Record a voice prompt when local voice tools are enabled in setup
/exit        Close the session
```

## Layout

- `Sources/ToolCore`: dependency-light tool wire, descriptor, environment, and compatibility types.
- `Sources/FeatureKit`: feature contracts, schemas, process protocol, and runner support.
- `Sources/FeatureMCPBridgeKit`: generic MCP feature integration, transports, and injectable local-transport policies.
- `Sources/Features/XcodeTools/Feature`: `XcodeToolsFeature`, the feature-owned Xcode MCP implementation library.
- `Sources/Features/XcodeTools/Executable`: the thin `xcode-tools-feature` executable entry point.
- `Sources/LocalToolsSupport`: reusable local file, search, text, and patch tooling.
- `Sources/ZenPackageMetadata`: internal bundled-feature distribution metadata and catalog parity support.
- `Sources/ZenCODECore`: reusable agent runtime, TUI, tools, skills, ACP, config, memory, sessions, and feature management.
- `Sources/ZenCODESetup`: interactive setup for standalone `zen`.
- `Sources/zen`: the `zen` composition root and command-line dispatch.
- `Sources/Features`: bundled Dynamic Swift Feature executables.
- `Tests`: SwiftPM test targets.
- `Docs`: detailed guides and feature documentation.

## Development Commands

```bash
swift test
swift build -c release --product zen

zen --help
zen --doctor
zen --setup
zen --cwd /path/to/project
zen --acp --cwd /path/to/project
```

## More Docs

- [Architecture and layout contract](Docs/architecture.md)
- [Release and reproducible-install guide](Docs/release.md)
- [Persisted credential security](Docs/security.md)
- [Why ZenCODE](Docs/why-zen.md)
- [ZenCODE guide](Docs/zen.md)
- [Agents and sub-agents guide](Docs/agents.md)
- [Builder agent guide](Docs/builder.md)
- [Planner agent guide](Docs/planner.md)
- [Reviewer agent guide](Docs/reviewer.md)
- [Reporter agent guide](Docs/reporter.md)
- [Aion UI manual setup](Docs/aion-ui.md)
- [Xcode 27 ACP setup](Docs/xcode.md)
