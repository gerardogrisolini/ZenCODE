# ZenCODE DS4

`zen --ds4` runs the coding agent on a local DS4 runtime loaded in the
same process. It does not start or talk to `ds4-server`.

DS4 build support, runtime configuration, and model selection are separate.
ZenCODE does not vendor DS4 headers or source files: DS4-enabled builds use a
local DS4 checkout selected during install. Runtime parameters and model
selection happen later inside `zen --setup`.

## Requirements

- macOS on Apple Silicon for the bundled DS4 Metal build helper, or Linux with
  a DS4 runtime library built from the DS4 checkout.
- A local DS4 source/build checkout.
- A DS4 GGUF model file, for example `ds4flash.gguf`.
- `make` and platform toolchains needed by DS4.

## Source Build With DS4

The installer asks whether to compile DS4 support and defaults to yes. When DS4
is enabled, it then asks for the DS4 checkout directory, uses its `ds4.h` at
build time, and registers the runtime library:

```bash
Scripts/install.sh
```

On later installs, the DS4 directory saved in `~/.zencode/ds4/settings.json`
is offered as the default.

For manual SwiftPM builds:

```bash
ZENCODE_BUILD_DS4=1 ZENCODE_DS4_ROOT=/path/to/ds4 swift build -c release --product zen
```

## One-Time Runtime Setup

Open setup:

```bash
zen --setup
```

Then open `Local inference`, then `DS4 runtime`, and enter the local DS4
checkout/build directory. Setup registers the runtime library and can build
`libds4.dylib` on macOS when the bundled build helper is available.

For non-interactive installs, you can still use the helper script from a
checkout or from the `Scripts` directory installed next to `zen`:

```bash
Scripts/setup-ds4.sh /path/to/ds4
```

The runtime setup:

- validates the DS4 directory
- builds `/path/to/ds4/libds4.dylib` on macOS, or validates an existing
  runtime library when used with `--skip-build`
- writes `~/.zencode/ds4/settings.json`

It does not choose a model.

## Setup

After registering the runtime, choose the model from setup:

```bash
zen --setup
```

Open `Local inference`. The DS4 entries are:

- `DS4 runtime`: backend, context window, output/tool limits, SSD streaming,
  MTP, sampling, and other runtime flags.
- `DS4 models`: scans the DS4 root for `.gguf` files and also lets you enter a
  model path manually.

After configuring the runtime and selecting the model, validate the
configuration:

```bash
zen --ds4 --doctor
```

Then run DS4 mode with the stored settings:

```bash
zen --ds4
```

## Configuration File

The install script writes:

```json
{
  "ds4Root" : "/path/to/ds4",
  "libraryPath" : "/path/to/ds4/libds4.dylib",
  "version" : 1
}
```

`zen --setup` adds the selected model path and runtime parameters:

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

By default the file is stored at:

```text
~/.zencode/ds4/settings.json
```

If `ZENCODE_SUPPORT_DIRECTORY` is set, the DS4 settings file is stored under
that support directory instead.

## Overrides

Runtime configuration precedence is:

1. CLI arguments
2. environment variables
3. `~/.zencode/ds4/settings.json`

Useful CLI overrides:

```bash
zen --ds4 --ds4-root /path/to/ds4 --model /path/to/model.gguf
zen --ds4 --ctx 65536
zen --ds4 --library /path/to/libds4.dylib
```

Equivalent environment variables:

```bash
export ZENCODE_DS4_ROOT=/path/to/ds4
export ZENCODE_DS4_LIBRARY=/path/to/ds4/libds4.dylib
export ZENCODE_DS4_MODEL=/path/to/ds4flash.gguf
export ZENCODE_DS4_TOP_K=0   # top-k sampling cutoff; 0 disables top-k
```

## SSD Streaming

For models larger than available RAM, use DS4 SSD streaming options:

```bash
zen --ds4 \
  --ssd-streaming \
  --ssd-streaming-cache-experts 32GB
```

These options can be saved from `zen --setup` under `Local inference`,
then `DS4 runtime`. The install script only records the DS4 root and runtime
library. The model path is recorded by `DS4 models`.

When setup asks for `SSD streaming cache`, enter `32GB` to match the old
`--ssd-streaming-cache-experts 32GB` command. Entering only `32` means cache 32
experts, not 32GB of SSD streaming cache.

## Rebuilding DS4

To rebuild only the DS4 dynamic library:

```bash
Scripts/build-ds4-runtime.sh /path/to/ds4
```

The bundled build helper currently targets macOS/Metal. On Linux, build the DS4
runtime from the DS4 checkout, then register it with:

```bash
Scripts/setup-ds4.sh /path/to/ds4 --skip-build --library /path/to/ds4/libds4.so
```

To rewrite runtime settings without rebuilding:

```bash
Scripts/setup-ds4.sh /path/to/ds4 --skip-build
```

## Troubleshooting

If `zen --ds4` cannot find DS4, run:

```bash
zen --ds4 --doctor
```

Common fixes:

- missing DS4 root: run `Scripts/setup-ds4.sh /path/to/ds4`
- missing `libds4.dylib`: run `Scripts/build-ds4-runtime.sh /path/to/ds4`
- missing model: run `zen --setup`, open `Local inference`, then `DS4 models`
- wrong DS4 flags: run `zen --setup`, open `Local inference`, then `DS4 runtime`

`zen --ds4` uses native DSML tool calls in-process, so tool execution does
not require `ds4-server`.
