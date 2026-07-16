![ZenCODE](Docs/Images/social-preview.png)

**ZenCODE** is a flexible coding agent for the terminal and ACP. Drive it with cloud providers, your existing ChatGPT and Claude subscriptions, or run fully on-device with Apple MLX and DS4.

Keywords: ZenCODE, coding agent, AI coding assistant, ChatGPT subscription coding agent, Claude subscription coding agent, cloud LLM agent, OpenAI-compatible coding agent, OpenRouter coding agent, local LLM coding assistant, Apple MLX, ACP agent, on-device LLM, terminal coding agent for macOS and Linux.

ZenCODE is provider-agnostic: bring your own API key for any OpenAI-compatible endpoint (OpenRouter, local servers, and more), sign in once with your ChatGPT or Claude subscription through the browser, or run completely on-device with the local MLX or DS4 runtimes — no cloud, no API keys, and no data leaving your machine.

## Providers and Runtimes

ZenCODE supports several ways to run the model, all selected through `zen --setup`:

- **Cloud API providers** — bring an API key for any OpenAI-compatible endpoint, including OpenRouter, local servers, and any `/v1`-compatible provider.
- **ChatGPT Subscription** — sign in with your existing ChatGPT subscription through the browser. No API key required.
- **Claude Subscription** — sign in with your existing Claude (Anthropic) subscription through the browser. No API key required.
- **Local MLX runtime** — run fully on-device with Apple MLX (`zen --mlx`), with no HTTP server and no remote provider required.
- **Local DS4 runtime** — run a local DS4 runtime loaded in-process (`zen --ds4`), with native DSML tool calls and no DS4 webserver.

## Run

- `zen` runs the standalone terminal and ACP coding agent with configured providers.
- `zen --mlx` runs the same agent on the local MLX runtime directly.
- `zen --ds4` runs the same agent on a local DS4 runtime loaded in-process.

## Install

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install.sh | bash
```

Re-run the same command to update. The installer downloads a temporary source
checkout, builds `zen`, installs the binary and feature executables, then
removes the checkout.

Requires macOS 26 (Tahoe), Apple Silicon, Git, and the Swift toolchain from
Xcode or the Apple command line tools.

### Linux and Windows via WSL

```bash
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install-linux.sh | bash
```

On Linux, the local MLX runtime is Apple-only and not available, but the local
DS4 runtime is supported. The Linux build does not pull in MLX/Metal
dependencies. You can drive the agent through configured remote providers
(`zen --setup`) or use local DS4 inference (`zen --ds4`) when DS4 support is
compiled in. The standalone agent, TUI, ACP bridge, and bundled feature
executables work normally.

Windows is supported through WSL. Install Ubuntu first, then run the Linux
installer inside the Ubuntu shell:

```powershell
wsl --install -d Ubuntu
```

Install Swift for Linux first: <https://www.swift.org/install/linux/>. Verify it
with:

```bash
swift --version
```

> Note: `zen --mlx` is unavailable on Linux/WSL because local MLX inference
> requires Apple Silicon and Metal. Local DS4 inference (`zen --ds4`) is
> available on Linux when DS4 support is compiled in; see the
> [DS4 guide](Docs/ds4.md).

## Quick Start

Choose how ZenCODE runs — a cloud API provider, a ChatGPT or Claude subscription, or a local runtime — during setup, then start the agent:

```bash
zen --setup
zen
```

Prefer fully on-device? Use the local runtimes:

```bash
zen --mlx
zen --ds4
```


## Build From Source

Use a source checkout when developing ZenCODE itself:

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
swift build -c release --product zen
```

To compile DS4 support from source, point the build at a local DS4 checkout:

```bash
ZENCODE_BUILD_DS4=1 ZENCODE_DS4_ROOT=/path/to/ds4 swift build -c release --product zen
```

## TUI Commands

```text
/help        Show available commands
/models      Select a model
/agents      Select an agent profile
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
               /sessions restore <id|index>   Restore in-place from a checkpoint
               /sessions fork <id|index> <new-name>  Fork into a new session file
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
- `Sources/LocalRuntimeSupport`: internal support for selecting local agent-runtime backends.
- `Sources/ZenCODESetup`: interactive setup for standalone `zen`.
- `Sources/zen`: the `zen` composition root and command-line dispatch, with optional MLX and DS4 adapters.
- `Sources/MLXServerCore`: conditional local MLX runtime, model catalog, loading, generation gate, and disk KV cache.
- `Sources/MLXServerSetup`: conditional local MLX settings and model configuration workflows, including Hugging Face model discovery and setup.
- `Sources/DS4RuntimeShim`: conditional C shim used only when DS4 support is enabled.
- `Sources/Features`: bundled Dynamic Swift Feature executables.
- `Tests`: SwiftPM test targets.
- `Docs`: detailed guides and feature documentation.

## Development Commands

```bash
swift test
swift build -c release --product zen

zen --help
zen --setup
zen --cwd /path/to/project
zen --acp --cwd /path/to/project

zen --mlx --help
zen --mlx --cwd /path/to/project
zen --mlx --acp --cwd /path/to/project
```

## More Docs

- [Architecture and layout contract](Docs/architecture.md)
- [Why ZenCODE](Docs/why-zen.md)
- [ZenCODE guide](Docs/zen.md)
- [Local MLX runtime guide](Docs/mlx-runtime.md)
- [DS4 direct runtime guide](Docs/ds4.md)
- [Agents and sub-agents guide](Docs/agents.md)
- [Builder agent guide](Docs/builder.md)
- [Planner agent guide](Docs/planner.md)
- [Reviewer agent guide](Docs/reviewer.md)
- [Reporter agent guide](Docs/reporter.md)
- [Aion UI manual setup](Docs/aion-ui.md)
- [Xcode 27 ACP setup](Docs/xcode.md)
