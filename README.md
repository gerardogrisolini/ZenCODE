# ZenCODE

**ZenCODE** is a local-first AI coding agent for Apple Silicon, powered by Apple MLX. It runs a standalone terminal and ACP coding agent on your Mac — no cloud, no API keys, and no data leaving your machine when you use the local MLX runtime.

Keywords: ZenCODE, MLX coding agent, local LLM coding assistant, Apple Silicon AI agent, Apple MLX, ACP agent, on-device LLM, terminal coding agent for macOS.

`ZenCODE` is a Swift Package centered on a local-first coding agent for Apple Silicon.

- **`zen`** runs the standalone terminal and ACP coding agent with configured providers.
- **`zen --mlx`** runs the same agent on the local MLX runtime directly, with no HTTP server and no remote provider required.
- **`zen --ds4`** runs the same agent on a local DS4 runtime loaded in-process, with native DSML tool calls and no DS4 webserver.

Local MLX model setup, model catalog management, reset, and runtime launch now live under `zen --mlx`.

## Install

### Installer Script

Use the installer script to build ZenCODE and install the selected local runtime
modules. Re-run the same script to update an existing script installation.

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
./Scripts/install.sh
```

Update an existing script installation from the checkout with:

```bash
git pull
./Scripts/install.sh
```

Requires macOS 26 (Tahoe) on Apple Silicon.

### Build From Source

```bash
swift build -c release --product zen
```

To compile DS4 support from source, point the build at a local DS4 checkout:

```bash
ZENCODE_BUILD_DS4=1 ZENCODE_DS4_ROOT=/path/to/ds4 swift build -c release --product zen
```

### Linux (and Windows via WSL)

On Linux, `zen` runs in remote-only mode: the local MLX runtime is
Apple-only, so the build never pulls in MLX/Metal and you drive the agent
through configured remote providers (`zen --setup`). The standalone
agent, TUI, ACP bridge, and bundled feature executables all work normally.

Windows is supported through **WSL (Windows Subsystem for Linux)**. Inside a
WSL Ubuntu shell you run a real Linux toolchain, so the steps below apply
unchanged — no native Windows build is required.

#### 1. Install a Swift toolchain

- **Native Linux:** install Swift for Linux following
  <https://www.swift.org/install/linux/> (a distribution package or `swiftly`).
- **Windows:** install WSL first, then a Linux distribution:

  ```powershell
  wsl --install -d Ubuntu
  ```

  Open the **Ubuntu** shell and install Swift inside it exactly as on native
  Linux. Everything from here on runs in that Ubuntu shell.

Verify the toolchain:

```bash
swift --version
```

#### 2. Build and install from source

```bash
git clone https://github.com/gerardogrisolini/ZenCODE.git
cd ZenCODE
./Scripts/install-linux.sh
```

The script compiles `ZenCODE` plus the bundled feature executables and
installs them to `/usr/local/bin` (with feature binaries under
`/usr/local/bin/zen-features/`). Useful options:

```bash
# Install into a custom prefix (no sudo needed if it is user-writable)
INSTALL_DIR="$HOME/.local/bin" ./Scripts/install-linux.sh

# or
./Scripts/install-linux.sh --prefix "$HOME/.local/bin"

# Build the debug configuration instead of release
./Scripts/install-linux.sh --debug
```

Make sure the chosen install directory is on your `PATH`.

#### 3. Configure and run

```bash
zen --setup
zen --cwd /path/to/project
```

> Note: `zen --mlx` (local MLX inference) is unavailable on Linux/WSL
> because it requires Apple Silicon and Metal. Use a configured remote provider
> instead.

## Quick Start

Set up the standalone agent:

```bash
zen --setup
zen --cwd /path/to/project
```

Set up and run the local MLX runtime:

```bash
zen --setup
zen --mlx --cwd /path/to/project
```

Run ACP over stdio with the local MLX runtime:

```bash
zen --mlx --acp --cwd /path/to/project
```

## Local MLX Mode

`zen --mlx` starts the `ZenCODE` agent with `MLXServerRuntime` embedded in the same process. It does not start a webserver and does not serialize model calls over HTTP.

Useful commands:

```bash
zen --mlx --help
zen --mlx --agent Feature --model qwen3-mlx --cwd /path/to/project
zen --setup
```

Local MLX configuration lives in:

```text
~/.zencode/mlx/settings.json
~/.zencode/mlx/models.json
~/.zencode/mlx/KVCaches/
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

## Common Commands

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
