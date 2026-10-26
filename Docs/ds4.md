# DS4 in-process engine

ZenCODE runs a DS4 model inside the `zen` process. There is no `ds4-server`, no
HTTP endpoint, and no loopback port. `ZenCODECore` loads a small library,
`libzencode-ds4`, that is built on your machine from your DS4 checkout, and calls
it directly. `zen` has no compile-time dependency on DS4.

The architecture and persistence contract behind this guide is in
[architecture.md](architecture.md#ds4-local-runtime-compatibility-ownership-and-persistence).

## Overview

| Part | What it is | Where |
| --- | --- | --- |
| Engine library | `libzencode-ds4.dylib` (macOS) or `libzencode-ds4.so` (Linux): a ZenCODE C shim (ABI v2) compiled against the `ds4.h` of your checkout and linked with the objects of the DS4 Makefile | `<support>/ds4/engines/<backend>-<hash16>/` |
| Build | `Scripts/build-ds4-engine.sh`, run by `/setup` or by hand | Writes the library and `build.json` next to it |
| Runtime | Loaded at runtime with `dlopen` (`RTLD_NOW` and `RTLD_LOCAL`); every engine call runs on one dedicated thread | One engine per `zen` process |
| Provider | The DS4 provider, with a `ds4Runtime` on each of its models | `settings.json` |

`<support>` is the ZenCODE support directory (`~/.zencode` by default). Setup
copies the shim sources to `<support>/ds4/shim/` before it builds.

## Requirements by backend

| Backend | Host | Toolchain | Build option (default) |
| --- | --- | --- | --- |
| `metal` | macOS | Xcode Command Line Tools; the checkout's `ds4_metal.m` and `metal/` | None |
| `cpu` | macOS or Linux | `cc`; the shim is built with `-DDS4_NO_GPU` | None |
| `cuda` | Linux | `nvcc` from the CUDA toolkit (`CUDA_HOME` or `NVCC`); the checkout's `ds4_cuda.cu` and `cuda/mmq/` | `--cuda-arch` (`native`); manifest `cudaArch` |
| `rocm` | Linux | `hipcc` from ROCm (`/opt/rocm` or `HIPCC`); the checkout's `ds4_rocm.cu` and `cuda/mmq/` | `--rocm-arch` (`gfx1151`, the `strix-halo` target); manifest `rocmArch` |

Every backend needs `make`, a C compiler (`CC`, default `cc`), a SHA-256 tool
(`shasum`, `sha256sum`, or `openssl`), and these files of the checkout:
`Makefile`, `ds4.h`, `ds4.c`, `ds4_kvstore.c`, `ds4_kvstore.h`,
`ds4_gpu_args.c`, `ds4_gpu_args.h`, `ds4_distributed.h`, and `ds4_tp.h`.
The build script stops with a message when one of them is missing.

Verification status: the `metal` build was verified with a real toolchain on
macOS and the `cpu` build on Linux arm64. `cuda` and `rocm` were verified only
with fake toolchains, so a run on a real GPU is still open.

## Building the engine library

Setup builds the library for you (see [Setup](#setup)). To build it by hand,
run the script with the same arguments setup uses:

```sh
Scripts/build-ds4-engine.sh --root ~/Projects/ds4 --backend metal \
  --shim <support>/ds4/shim --output <output-file>
```

| Option | Meaning |
| --- | --- |
| `--root <dir>` | DS4 checkout, which contains `ds4.h` and the Makefile |
| `--backend metal\|cpu\|cuda\|rocm` | Backend to build |
| `--cuda-arch <arch>` | nvcc architecture, for example `sm_120` or `native` (CUDA only) |
| `--rocm-arch <arch>` | ROCm target, for example `gfx1151` (ROCm only) |
| `--shim <dir>` | Directory with `zencode_ds4_shim.c` and `zencode_ds4_abi.h` |
| `--output <file>` | Library to produce; `build.json` is written next to it |

Environment variables: `CC`, `CUDA_HOME`, `NVCC`, and `HIPCC` select the
toolchain, as in the DS4 Makefile. `ZENCODE_DS4_BUILD_JOBS` sets the number of
parallel make jobs (default: the CPU count, at most 4).

For ZenCODE to find the library, `--output` must be
`<support>/ds4/engines/<backend>-<hash16>/libzencode-ds4.dylib` (or `.so` on
Linux). The hash is the first 16 hex characters of the SHA-256 of `ds4.h`,
`zencode_ds4_shim.c` and `zencode_ds4_abi.h` concatenated in that order:

```sh
cat <checkout>/ds4.h <shim>/zencode_ds4_shim.c <shim>/zencode_ds4_abi.h | shasum -a 256 | cut -c1-16
```

The script behaves as follows:

- It builds only the DS4 objects that the library links, by name. Other DS4
  programs are neither rebuilt nor relinked, and `make clean` never runs. The
  object files are written in the checkout, as `make` does, but the checkout's
  programs are not overwritten.
- On Linux it deletes those objects first and rebuilds them with `-fPIC`, which
  `make` cannot detect on its own.
- `build.json` records the root, backend, architecture, date, hash, and
  `abiVersion`.

A change to `ds4.h`, to the shim, or to the ABI header changes the hash and
therefore the directory. Setup then reports the library as **rebuild required**
when a library of the same backend already exists, and as **missing** otherwise,
and builds into the new directory. A change only to `ds4.c` does **not** change
the hash, so the library is not reported as stale. After you update `ds4.c`, run
the script again with the same arguments.

The shim sources are embedded in the binary, so an installed `zen` can build
the library without the repository. Their canonical copies are
`Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h` and
`zencode_ds4_shim.c`. `Scripts/GenerateDS4EngineShimSources.swift` generates the
embedded copy (`DS4EngineShimSources.generated.swift`). Run it with `--check` to
confirm that the copy is current; a parity test compares the two.

## Setup

1. Open `/setup` and select **DS4 local runtime**, or reconfigure the DS4
   provider from **Providers & models**. Both use the same flow and never call
   `/models`, because setup never loads the engine.
2. Enter the absolute path of the DS4 checkout. A previously configured folder
   is offered as the default.
3. ZenCODE scans only `<folder>/*.gguf` and `<folder>/gguf/*.gguf`, read-only,
   and shows every regular GGUF in a multi-select menu. Configured files are
   preselected. Each selected file becomes one model of the DS4 provider. An
   empty selection or cancelling leaves the settings unchanged.
4. For each selected model:
   - choose the backend from `metal`, `cuda`, `rocm`, and `cpu` (default: the
     model's previous backend, otherwise `metal` on macOS and `cpu` elsewhere);
   - optionally choose a vision projector and an MTP/DSpark support GGUF from
     the other GGUF files of the folder;
   - set the runtime tuning (listed below);
   - confirm the API model id, which is asked only when the file name does not
     match a known family.
5. Setup checks the engine library of each selected model. A library that is
   built needs nothing. A library that is missing, or that must be rebuilt, is
   built after you answer **Build the DS4 engine now?** (default: yes). If you
   decline, setup prints
   `DS4 engine build skipped. Run the DS4 setup again to build it before using DS4.`
   If the build fails, setup prints the error and the manual command, and keeps
   the staged configuration. The library state (built, missing, or rebuild
   required) is shown in the setup detail of the provider.
6. Finish setup normally. Only the final setup transaction writes settings.
   Non-DS4 providers, models, API keys, and unrelated settings are kept.
   Re-running the flow replaces the DS4 models with the new selection and keeps
   the id, title, parameter overrides, and thinking options of the models whose
   file is still selected.

Setup never downloads a checkout or model weights, probes the hardware, loads a
model, or calls `/models`. Each model keeps its own launch parameters. A new
model starts from the defaults and never inherits the settings of another model.

### Runtime tuning asked by setup

Each value is asked per model and defaults to the saved value of that model.
Cancelling any prompt leaves the settings unchanged.

| Prompt | Setting | Range and default |
| --- | --- | --- |
| Context window | `--ctx` (`contextWindow`) | 1 to 1,048,576 tokens; 65,536 |
| SSD streaming | `--ssd-streaming` | Off |
| MTP | `--mtp` (internal GLM multi-token prediction) | Off |
| Power | `--power` (`power`) | 1 to 100; 100 |
| Quality mode | `--quality` | Off |
| Warm weights | `--warm-weights` | Off |
| CPU threads | `-t` (`threads`) | Optional; `none` lets DS4 decide |
| Prefill chunk | `--prefill-chunk` (`prefillChunk`) | Optional; `none` uses the DS4 default |
| DSpark | `--dspark` | Off |
| MTP draft tokens and margin | `--mtp-draft`, `--mtp-margin` | Asked when MTP, DSpark, or an MTP/DSpark support model is set: 1 to 16, and 0 to 1000 |
| Steering file and scales | `--dir-steering-file`, `--dir-steering-ffn`, `--dir-steering-attn` | Scales from -100 to 100, asked when a file is set |
| CUDA or ROCm architecture | `cudaArch` or `rocmArch` | Asked for `cuda` or `rocm` only |
| Engine sessions | `engineSessions` | 1 to 8; 2 |
| Extra engine arguments | `extraEngineArguments` | Advanced; see below |

The SSD cache and preload options and cold streaming are not asked by setup. A
model keeps the values it already has.

## What is persisted

Each DS4 model records an optional `ds4Runtime` object. Every key is optional
when decoding, so older manifests load unchanged.

| Key | Meaning |
| --- | --- |
| `rootDirectory` | Canonical absolute path of the DS4 checkout |
| `modelRelativePath` | Model file, relative to the checkout |
| `backend` | `metal`, `cuda`, `rocm`, or `cpu` |
| `contextWindow` | Context window (`--ctx`) and the context size ZenCODE uses for the model |
| `ssdStreaming`, `ssdStreamingCacheExperts`, `ssdStreamingCacheBytes`, `ssdStreamingPreloadExperts`, `ssdStreamingCold` | SSD streaming and its cache, preload, and cold options |
| `mtp`, `power` | Internal GLM MTP and the power duty cycle (1 to 100) |
| `visionRelativePath` | Vision projector GGUF, relative to the checkout |
| `mtpRelativePath` | MTP/DSpark support GGUF, relative to the checkout |
| `steeringRelativePath`, `steeringFFN`, `steeringAttn` | Directional steering file and its FFN and attention scales (-100 to 100) |
| `dspark`, `mtpDraftTokens`, `mtpMargin` | DSpark, draft tokens (1 to 16), and MTP margin (0 to 1000) |
| `quality`, `threads`, `prefillChunk`, `warmWeights` | Engine options |
| `cudaArch`, `rocmArch` | Architecture used when the library is built |
| `engineSessions` | Sessions the engine keeps open at once (1 to 8; default 2) |
| `extraEngineArguments` | Opaque tokens for DS4's distributed, tensor-parallel, or multi-GPU options; the shim validates them with DS4's public parsers |

Auxiliary files are relative to the checkout and must not be symlinks. The
`batchedSessions` key is retired: it is ignored when decoding and never written.

The provider base URL, `http://127.0.0.1:8000/v1`, is a compatibility
placeholder. The engine runs in-process and does not use it.

Nothing else is stored: not the process or engine state, the KV cache, or the
values changed with `/ds4`. The only DS4 state that reaches disk is the optional
checkpoint described in [KV checkpoints](#kv-checkpoints-ds4kv).

## Runtime

### One engine per process

- The `DS4EngineRegistry` keeps at most one engine open per `zen` process. Asking
  for a different DS4 model closes the open engine after the generation in
  progress, then opens the new one.
- Generations are serialized by a FIFO lock: one `sync` and `generate` round at a
  time. Sub-agents that use the same model share its engine and queue.

### Session pool

- Each ZenCODE session has one DS4 session in the engine. The pool holds
  `engineSessions` sessions (default 2, 1 to 8) and evicts the least recently
  used one.
- An evicted session is rebuilt from the common prefix on its next turn.

### Instance lock

- DS4 holds an instance lock on `/tmp/ds4.lock`, or on the path in
  `DS4_LOCK_FILE` when it is set. A DS4 process that starts while the lock is
  held fails with `DS4 instance lock is held (...): another DS4 process is using this model.`
- A model is never shared between processes. Stop the other `zen`, `ds4-agent`,
  or `ds4-server` process and retry.
- The shim checks that the GGUF files exist before it opens the model.

### Errors and limits of DS4

- The stderr of DS4 is captured while the engine opens and is included in the
  error message.
- DS4 calls `exit()` when a GGUF is malformed or unsupported, and that ends
  `zen`. This is an accepted limit.
- The Metal kernel sources are found in the checkout. The shim exports
  `DS4_METAL_<STEM>_SOURCE` for each `<root>/metal/<stem>.metal`.

Closing an agent backend (for example on an agent switch) releases only its DS4 sessions; the loaded model stays resident. The engine is closed when `zen` exits, when a different DS4 model is requested, or when a new agent backend uses a non-DS4 model while no DS4 session is live.

## Using DS4 in ZenCODE

### `/ds4`

The `/ds4` command is available only while a DS4 model is selected. Its values
last for the session and are never saved.

| Command | Effect |
| --- | --- |
| `/ds4 status` | Shows the model, engine, backend, library state and path, context used and total, KV tokens reused at the last sync, sessions in the pool, power, steering, and hints. It does not open the model. |
| `/ds4 power <1-100>` | Sets the engine power for this session. If the engine is not open yet, the value applies when the model loads. |
| `/ds4 steer <-100..100>` | Sets the FFN directional steering scale. It needs a steering file (`steeringRelativePath`). |
| `/ds4 hints on` or `/ds4 hints off` | Turns brief programming hints on or off, with the texts of ds4-agent. They start off and take effect from the next conversation boundary. |

### Thinking (`/think`)

| ZenCODE level | DeepSeek V4.1 (effort level) | Other models (DS4 mode) |
| --- | --- | --- |
| `off` | None | None |
| `minimal` | 10 | LOW |
| `low` | 25 | LOW |
| `medium` | 50 | MEDIUM |
| `enabled` or `high` | 75 | HIGH |
| `xhigh` | 90 | HIGH |
| `max` or `ultra` | 100 | MAX |

DS4 adapts the mode to the context size, and it lowers MAX when the context is
below the minimum of the model.

### Sampling

Without overrides, a round samples with temperature 0.6, top-p 0.95, min-p 0,
and top-k off. GLM uses temperature 1.0 with the same other values. The
generation parameters of the model in ZenCODE take precedence. These defaults
differ from the defaults of ds4-agent.

### Transcript and tools

- Prompts are rendered in tokens with the native chat template and tool syntax
  of the model family: DSML for DeepSeek V4, DSML41 for DeepSeek V4.1, and the
  GLM and Qwen syntaxes. The KV cache of the common prefix is reused, and only
  the new suffix is prefilled.
- Turns that were already sent are reproduced exactly, from private `ds4_*` keys
  on the in-memory messages. A turn the engine generated is replayed with the
  exact token ids it sampled (`ds4_raw_tokens`), not with a new tokenization of
  its text: tokenizing the text again can split it differently, and a model with
  recurrent state (Qwen3.8-Flash-Next) would then find a divergence before the
  end of the live state and rebuild the whole prompt (`DS4 prefill: 0 cached`).
  The ids carry the identity of the model that produced them
  (`ds4_raw_tokens_model`, `<model id>-<routed quant bits>-<model name>`) and
  are replayed only by that model; with another model, or for turns without ids,
  the raw text is tokenized instead. Those keys are never saved in snapshots and
  are never sent to other providers.
- The system prompt is repeated every 50,000 tokens.
- A malformed tool call is returned to the model with a reminder of the syntax.
  Sampling inside tool blocks is greedy, as in ds4-agent.

### Context and compaction

- The context window is always the `contextWindow` of the manifest.
- ZenCODE compacts the session when the prompt reaches 85% of the context, or
  when the free room is at or below `max(min(8192, ctx/8), reserve + 128)`. The
  reserve is derived from the compaction request, as in ds4-agent. Compaction is
  deterministic: the compaction request is never sent to the model.
- A round generates at most `maxOutputTokens` (50,000 when unset), and never
  more than the room left in the context.

### Vision

- With `visionRelativePath` set, images in user messages and tool results are
  encoded for the model. The temporary files are written to `<support>/ds4/tmp`
  and removed right after use. Image observations from tools are sent in the
  user role.
- Without a vision projector, images are ignored and the diagnostic
  `DS4 model has no vision encoder configured; images were ignored` is shown.
- Limit: the images in the history are encoded again on every round.

## KV checkpoints (`.ds4kv`)

- A checkpoint is written only by `/sessions save` and `/sessions <name>`. It is
  stored next to the session file as `<name>.ds4kv`.
- When a session with a DS4 model is loaded, its checkpoint is restored and
  ZenCODE shows `Restored DS4 KV checkpoint.`. If the checkpoint is not
  compatible with the engine, ZenCODE shows
  `DS4 checkpoint not compatible, the prompt will be re-evaluated.` and evaluates
  the prompt again.
- A checkpoint is skipped when the session contains images
  (`KV checkpoint skipped: session contains images.`) or when there is no live
  DS4 state for the session (`DS4 KV checkpoint skipped: no live DS4 state for this session.`).
  Saving never opens the model.
- A save without a checkpoint removes an older `<name>.ds4kv`. Deleting a
  session deletes its checkpoint.
- The checkpoint carries a versioned JSON trailer (version 1) with the DS4
  metadata of each message, including the token ids of the turns the model
  generated. A trailer written before the token ids were added still loads: those
  turns are replayed from their text.
- A checkpoint is not part of session snapshots or task checkpoints. It can be
  several GB, and it is included in backups of the support directory.

## Limits and non-goals

- One model per process. Models are not shared between processes, and the
  instance lock makes a second process fail with an explicit error.
- No batching of several requests in one engine.
- Not implemented: `--prefix-file`, `--raw-prompt`, importing the sessions of
  `~/.ds4/kvcache` from ds4-agent, and automatic KV saving.
- DS4 ends the `zen` process when it meets a malformed or unsupported GGUF.
- `cuda` and `rocm` are not yet verified on a real GPU.

## Troubleshooting

| Message or observation | Meaning | Action |
| --- | --- | --- |
| `libzencode-ds4 is not built for the <backend> backend` | No library for this backend and checkout | Run the DS4 setup and accept the build, or run the script |
| `DS4 engine build skipped` | The build was declined during setup | Run the DS4 setup again |
| ABI mismatch or missing symbol in the engine library | The library is stale or was built from other sources | Rebuild it with the command shown in the message |
| `libzencode-ds4 at <path> was built from other sources, another DS4 root or another architecture` | The library does not match this checkout or architecture | Build it again for this checkout |
| `DS4 instance lock is held` | Another DS4 process is using the model | Stop the other process and retry |
| `DS4 model has no vision encoder configured; images were ignored` | Images were sent to a model without `visionRelativePath` | Select a vision projector in setup, or remove the images |

## Validation

The regular tests use a mock engine and fixtures, and they do not need model
weights.

The live test is opt-in because it loads a real model of tens of GiB:

```sh
ZENCODE_RUN_LIVE_DS4=1 swift test --filter DS4EngineLiveTests
```

By default it opens `~/Projects/ds4` with `ds4flash.gguf` on `metal`, with a
32,768-token context. The `ZENCODE_DS4_ROOT`, `ZENCODE_DS4_MODEL`,
`ZENCODE_DS4_BACKEND`, `ZENCODE_DS4_CTX`, and `ZENCODE_DS4_SUPPORT_DIR` variables
change these values. The engine library must already be built.
