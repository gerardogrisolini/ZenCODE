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
copies the shim sources and `build-ds4-engine.sh` (executable) to
`<support>/ds4/shim/` before it builds.

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

With a `zen` that is installed without the repository, run the script that
setup extracted: `<support>/ds4/shim/build-ds4-engine.sh`. The manual command
that setup prints after a build error uses that path.

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
therefore the directory. Setup reports the library as **rebuild required**
when:

- the expected library exists, but its `build.json` is missing, cannot be read,
  or records another DS4 root, another backend, or another architecture (for
  example after you change the DS4 folder, `cudaArch`, or `rocmArch`);
- the expected directory has no library, but another `<backend>-<hash16>`
  directory of the same backend contains one.

Otherwise it reports the library as **missing**. In both cases the build goes
into the expected directory.

A change only to `ds4.c` does **not** change the hash, so the library is not
reported as stale. After you update `ds4.c`, run the script again with the same
arguments.

The shim sources and the build script are embedded in the binary, so an
installed `zen` can build the library without the repository. Three files are
embedded: `zencode_ds4_abi.h`, `zencode_ds4_shim.c`, and `build-ds4-engine.sh`.
Their canonical copies are
`Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h`,
`Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_shim.c`, and
`Scripts/build-ds4-engine.sh`. `Scripts/GenerateDS4EngineShimSources.swift`
generates the embedded copy (`DS4EngineShimSources.generated.swift`). Run it with
`--check` to confirm that the copy is current; a parity test compares all three
files.

## Setup

1. Open `/setup` and select **DS4 local runtime (in-process engine)**, or
   reconfigure the DS4 provider from **Providers and models**. Both use the same
   flow and never call `/models`, because setup never loads the engine.
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
   - the API model id is never typed. Setup takes it from the catalog of known
     models, then from the file name, then from the id already saved for the
     model when it is a served id. Only when none of the three identifies it,
     setup asks you to pick it from a menu of the ids that DS4 serves.
5. Setup checks the engine library of each selected model. A library that is
   built needs nothing. A library that is missing, or that must be rebuilt, is
   built after you answer **Build the DS4 engine now?** (default: yes). Setup
   asks this once for all the libraries to build; they are deduplicated by
   folder, backend, and architecture. If you decline, setup prints
   `DS4 engine build skipped. Run the DS4 setup again to build it before using DS4.`
   - If `ds4.h` is missing from the folder, the library cannot be derived. Setup
     prints `DS4 engine (<target>) not built: <error>` and does not offer the
     build.
   - If the build fails, setup prints the error and, when the script was already
     extracted, the manual command. For an unsupported platform, an invalid
     architecture, or an error while extracting the shim, there is no manual
     command: setup tells you to fix the problem and run the DS4 setup again.
   - In every case the staged configuration is kept.

   The library state (built, missing, or rebuild required) is shown in the setup
   detail of the provider.
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

Each DS4 model records an optional `ds4Runtime` object. `rootDirectory` is
required; every other key is optional when decoding, so older manifests load
unchanged.

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
  held fails with `DS4 instance lock is held (<detail>): another DS4 process is using this model. Stop the other ds4-server/ds4-agent/ZenCODE session and retry.`
- A model is never shared between processes. Stop the other `zen`, `ds4-agent`,
  or `ds4-server` process and retry.
- Before it opens the model, the shim checks that the model GGUF and the MTP
  and vision GGUFs can be opened, are regular files, and are at least 32 bytes
  long. Otherwise DS4 would call `exit()`.

### Errors and limits of DS4

- The stderr of DS4 is captured while the engine opens, while a session is
  created, and while power and steering are set. The captured text is included
  in the error message.
- DS4 calls `exit()` when a GGUF is malformed or unsupported, and that ends
  `zen`. This is an accepted limit.
- The Metal kernel sources are found in the checkout. The shim exports
  `DS4_METAL_<STEM>_SOURCE` for each `<root>/metal/<stem>.metal`.

Closing an agent backend (for example on an agent switch) releases only its DS4 sessions; the loaded model stays resident. The engine is closed when `zen` exits normally, when a different DS4 model is requested, or when a new agent backend uses a non-DS4 model while no DS4 session is live. On a normal exit the engine closes only when nothing uses it: no DS4 session is live, and no generation or engine opening is in progress. This check never waits; when the engine is in use, it is left open. An exit by signal does not go through this close: the operating system frees the memory and the lock.

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

Without a selected level the mode is `enabled`, that is HIGH (75 for DeepSeek
V4.1), the default of ds4-agent.

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
  Sampling is greedy on the structural parts of a tool block (the opening, the
  tags between the parameters, and the end of a value), as in ds4-agent. The
  content of the parameter values is sampled normally.

### Context and compaction

- The context window is the one reported by the open engine. In practice it is
  the `contextWindow` of the manifest, passed as `--ctx`. The manifest is the
  fallback when the engine does not report it.
- ZenCODE compacts the session when the prompt reaches 85% of the context, or
  when the free room is at or below `max(min(8192, ctx/8), reserve + 128)`. The
  reserve is derived from the compaction request, as in ds4-agent. Compaction is
  deterministic: the compaction request is never sent to the model.
- A round generates at most `min(maxOutputTokens, ctx - prompt - reserve)`
  tokens, with `maxOutputTokens` at 50,000 when unset. The compaction reserve is
  subtracted from the free room as well. When the result is not positive, the
  request fails with `The DS4 context is exhausted: ...`.

### Throughput

- While a DS4 model works, the status bar of the TUI shows a single throughput
  label after the token counters. Only DS4 shows it; other providers do not.
- During prefill the label is `p:1.2k/8.0k 512.0 tok/s`: the tokens evaluated so
  far out of the tokens to evaluate in this sync (the prefix already in cache
  is not counted), and the prefill speed. It is `p:0/8.0k` until the speed can
  be measured.
- After prefill, and during generation, the label is `p:512.0 g:42.1 tok/s`: the
  prefill speed next to the live generation speed. When the whole prompt was
  already in cache, only `g:` is shown.
- The label updates at most every 250 ms. The first update of each phase is
  immediate.
- At the end of a round the exact values reported by the engine stay on screen
  until the next request replaces them.
- Speeds always have one decimal.

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
  Saving never opens the model. Restoring does: it opens the model if it is not
  loaded yet (status `Loading DS4 model …`) and waits its turn in the generation
  queue.
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
