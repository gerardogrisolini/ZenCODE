![ZenCODE](Docs/Images/logo.png)

**ZenCODE** is a local-first coding agent powered by Apple MLX and DS4. Standalone terminal + ACP, no cloud required.

Keywords: ZenCODE, MLX coding agent, local LLM coding assistant, Apple Silicon AI agent, Apple MLX, ACP agent, on-device LLM, terminal coding agent for macOS.

The default macOS path can run fully on-device: no cloud, no API keys, and no data leaving your machine when you use the local MLX runtime. Remote providers are also available through setup when you want them.

## Runtimes

- `zen` runs the standalone terminal and ACP coding agent with configured providers.
- `zen --mlx` runs the same agent on the local MLX runtime directly, with no HTTP server and no remote provider required.
- `zen --ds4` runs the same agent on a local DS4 runtime loaded in-process, with native DSML tool calls and no DS4 webserver.

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

On Linux, `zen` runs in remote-only mode: the local MLX runtime is Apple-only,
so the build does not pull in MLX/Metal and you drive the agent through
configured remote providers (`zen --setup`). The standalone agent, TUI, ACP
bridge, and bundled feature executables work normally.

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
> requires Apple Silicon and Metal.

## Quick Start

Set up the standalone agent:

```bash
zen --setup
zen
```

Run the local MLX runtime:

```bash
zen --mlx
```

Run the local DS4 runtime:

```bash
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
/sessions    Save, compact, refresh, load, or delete session snapshots
/open        Open a referenced file, URL, or attachment
/changes     Review the latest tracked file changes
/undo        Revert the latest tracked agent changes
/review      Delegate a read-only review to Reviewer sub-agents
/features    Enable or disable feature packages with the Builder agent
/feature     Create and manage Swift features with the Builder agent
/telegram    Turn Telegram remote control on/off when paired in setup
/voice       Record a voice prompt when local voice tools are enabled in setup
/speak       Play the last assistant response aloud when local voice tools are enabled
/exit        Close the session
```

## Layout

- `Sources/ZenCODECore`: reusable agent runtime, TUI, tools, skills, ACP, config, memory, sessions, and feature management.
- `Sources/ZenCODESetup`: interactive setup for standalone `zen`.
- `Sources/zen`: `zen` executable, `--mlx` runtime entrypoint, reset commands, and Metal bootstrap.
- `Sources/MLXServerCore`: reusable local MLX runtime, model catalog, loading, generation gate, and disk KV cache.
- `Sources/MLXServerSetup`: local MLX runtime and model setup used by `zen --mlx`.
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

- [Why ZenCODE](Docs/why-zen.md)
- [ZenCODE guide](Docs/zen.md)
- [Local MLX runtime guide](Docs/mlx-runtime.md)
- [DS4 direct runtime guide](Docs/ds4.md)
- [Builder agent guide](Docs/builder.md)
- [Reviewer agent guide](Docs/reviewer.md)
- [Aion UI manual setup](Docs/aion-ui.md)
- [Xcode 27 ACP setup](Docs/xcode.md)
