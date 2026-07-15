# ZenCODE DS4

`zen --ds4` runs the coding agent on a local DS4 runtime loaded in-process. It does not start or talk to `ds4-server`.

DS4 build support, runtime configuration, and model selection are separate. ZenCODE does not vendor DS4 headers: DS4-enabled builds use a local DS4 checkout selected during install. Runtime parameters and model selection happen later in `zen --setup`.

## Requirements

- macOS on Apple Silicon (bundled Metal build helper) or Linux (DS4 runtime built from checkout).
- A local DS4 source/build checkout.
- A DS4 GGUF model file (for example `ds4flash.gguf`).
- `make` and platform toolchains.

## Source Build

The installer asks whether to compile DS4 support (defaults to yes), then asks for the checkout directory and uses its `ds4.h` at build time:

```bash
Scripts/install.sh
```

Manual SwiftPM build:

```bash
ZENCODE_BUILD_DS4=1 ZENCODE_DS4_ROOT=/path/to/ds4 swift build -c release --product zen
```

On later installs, the saved directory from `~/.zencode/ds4/settings.json` is offered as default.

## Runtime Setup

### Register the runtime

```bash
zen --setup          # Local inference → DS4 runtime → enter checkout path
```

Or non-interactively:

```bash
Scripts/setup-ds4.sh /path/to/ds4                        # build + register
Scripts/setup-ds4.sh /path/to/ds4 --skip-build           # register existing library only
Scripts/setup-ds4.sh /path/to/ds4 --skip-build --library /path/to/ds4/libds4.so   # Linux
```

This validates the directory, builds `libds4.dylib` on macOS, and writes `~/.zencode/ds4/settings.json`. It does not select a model.

### Select the model

```bash
zen --setup          # Local inference → DS4 local GGUF model
```

Scans the DS4 root for `.gguf` files, or enter a model path manually.

### Validate and run

```bash
zen --ds4 --doctor   # validate configuration
zen --ds4            # run
```

## Configuration File

Install writes:

```json
{
  "ds4Root" : "/path/to/ds4",
  "libraryPath" : "/path/to/ds4/libds4.dylib",
  "version" : 1
}
```

`zen --setup` adds model path and runtime parameters:

```json
{
  "backend" : "metal",
  "contextWindow" : 65536,
  "ds4Root" : "/path/to/ds4",
  "libraryPath" : "/path/to/ds4/libds4.dylib",
  "modelPath" : "/path/to/model.gguf",
  "ssdStreaming" : true,
  "ssdStreamingCacheBytes" : 34359738368,
  "version" : 1
}
```

Stored at `~/.zencode/ds4/settings.json` (or under `ZENCODE_SUPPORT_DIRECTORY`).

## Overrides

Precedence: CLI arguments > environment variables > settings file.

```bash
zen --ds4 --ds4-root /path/to/ds4 --model /path/to/model.gguf
zen --ds4 --ctx 65536
zen --ds4 --library /path/to/libds4.dylib
```

```bash
export ZENCODE_DS4_ROOT=/path/to/ds4
export ZENCODE_DS4_LIBRARY=/path/to/ds4/libds4.dylib
export ZENCODE_DS4_MODEL=/path/to/ds4flash.gguf
export ZENCODE_DS4_TOP_K=0   # 0 disables top-k
```

## SSD Streaming

For models larger than available RAM:

```bash
zen --ds4 --ssd-streaming --ssd-streaming-cache-experts 32GB
```

Saveable from `zen --setup` under Local inference → DS4 runtime. When setup asks for `SSD streaming cache`, enter `32GB` (not just `32`, which means 32 experts).

## Rebuilding

```bash
Scripts/build-ds4-runtime.sh /path/to/ds4                    # rebuild dylib (macOS)
Scripts/setup-ds4.sh /path/to/ds4 --skip-build               # rewrite settings without rebuild
```

On Linux, build the runtime from the DS4 checkout, then register it with `--skip-build --library`.

## Troubleshooting

```bash
zen --ds4 --doctor
```

- **Missing DS4 root**: `Scripts/setup-ds4.sh /path/to/ds4`
- **Missing `libds4.dylib`**: `Scripts/build-ds4-runtime.sh /path/to/ds4`
- **Missing model**: `zen --setup` → Local inference → DS4 local GGUF model
- **Wrong flags**: `zen --setup` → Local inference → DS4 runtime

`zen --ds4` uses native tool calls in-process; tool execution does not require `ds4-server`.
