# Folder-only DS4 setup

ZenCODE can use an existing local DS4 checkout as an optional OpenAI-compatible
provider. **Folder-only** means that ZenCODE receives a path to a checkout that
already exists on the machine. ZenCODE does not clone the checkout, download a
model, build DS4, inspect GGUF headers, or run inference during setup.

The architecture and persistence contract behind this guide is in
[architecture.md](architecture.md#ds4-local-runtime-compatibility-ownership-and-persistence).

## Supported integration levels

| Level | Supported contract | What ZenCODE owns |
| --- | --- | --- |
| Folder discovery | Point setup at an existing checkout. Discovery scans only the checkout root and its `gguf/` directory for regular `.gguf` files. | A read-only installation snapshot; no checkout changes. |
| Compatibility and staged setup | Compare the installed artifacts with the static catalog and a bounded, read-only hardware probe. Confirm one installed, catalog-recognized, operational model. | A staged provider/model manifest; the normal setup transaction persists it. |
| Managed local runtime | On first model use, start the existing DS4 executable on loopback, wait for `/v1/models`, and send OpenAI-compatible generation requests to the ready endpoint. | One actor-isolated supervisor and the child process for that backend lifetime. |
| Injected endpoint | A composition root or test may inject a ready `DS4ServerEndpoint`. | The embedding composition root owns readiness and any external process; this is not a user setup mode. |

The following are deliberately **not** integration levels: downloading model
weights, building DS4, starting a server during setup, or embedding a model and
performing inference inside ZenCODE. The provider boundary remains remote from
ZenCODE's point of view; DS4 is a separately managed local HTTP child.

## Prerequisites

Before opening setup, prepare the checkout outside ZenCODE:

- Use an absolute path to the existing DS4 folder. The folder is canonicalized
  and model paths must remain below it.
- Place at least one supported, regular GGUF artifact in either the checkout
  root or `gguf/`. Symlinked artifacts, directories named `*.gguf`, and files in
  arbitrary nested directories are ignored.
- Use a model represented by the bundled catalog. The catalog records download
  identities, artifact paths, approximate disk/RAM requirements, and supported
  backends; an unknown file is not silently treated as a supported model.
- For generation after setup, keep a runnable DS4 executable in the checkout's
  conventional location (`ds4-server`, `ds4`, `bin/ds4-server`, or `bin/ds4`),
  unless an internal composition root supplies an explicit executable. Setup
  itself does not launch or validate that process.
- Have a proven operational GPU backend and enough physical memory for the
  selected catalog proposal. Metal, CUDA, and ROCm are represented when the
  bounded probe proves them. CPU is diagnostic/reference-only and is not an
  operational setup recommendation.

The scanner and advisor are offline with respect to model acquisition. Disk
capacity is not substituted for physical RAM, and unknown hardware or memory
never becomes a positive compatibility claim.

## Setup flow

1. Open `/setup` and select **DS4 local runtime**.
2. Enter the existing DS4 checkout folder. A prior canonical folder is offered
   as the default when one is already configured.
3. ZenCODE scans only `<folder>/*.gguf` and `<folder>/gguf/*.gguf`, then prints
   the discovered artifacts, platform, architecture, physical RAM, GPU/backend
   evidence, and catalog proposals. These operations are read-only.
4. Select an installed proposal when more than one operational proposal is
   available. Confirmation is offered only for a complete, catalog-recognized,
   single-artifact model with a proven operational backend. Shard-only or
   multi-artifact proposals are not reduced to their first file.
5. Confirm the proposal. Setup stages a local provider at
   `http://127.0.0.1/v1`; it does not start DS4. Cancelling, declining,
   supplying an invalid folder, finding no GGUF, or finding no operational
   proposal leaves the existing manifest unchanged.
6. After confirming the proposal, choose the managed runtime tuning values:
   context window (`--ctx`, default 65,536 tokens), SSD streaming
   (`--ssd-streaming`, defaulting to the prior value or the compatibility
   proposal), embedded MTP (`--mtp`, off by default), and GPU duty-cycle power
   (`--power`, 1–100, default 100). Existing values are offered again when
   reconfiguring the same DS4 runtime; cancelling any tuning prompt leaves the
   manifest unchanged.
7. Finish setup normally. Only the final setup transaction writes settings.
   Existing non-DS4 providers, models, API-key entries, and unrelated settings
   are retained. Re-running the section updates the existing DS4 entry and
   retains its runtime tuning where possible.

A fresh model keeps a ZenCODE selection identity such as `ds4:<catalog-id>`.
The model ID sent to DS4 and checked against `/v1/models` is the catalog entry's
canonical API ID (for example, a download/quantization identity can map to the
server's advertised `deepseek-v4-flash` ID). These identities must not be
interchanged when inspecting a manifest or diagnosing readiness.

## What is persisted

The optional `ds4Runtime` metadata is additive and backward-compatible with
manifests that have no DS4 section. It records:

- the canonical absolute checkout root;
- the model path relative to that root;
- the selected backend (`metal`, `cuda`, `rocm`, or `cpu`);
- context-window and batching settings;
- runtime tuning for `--ssd-streaming`, `--mtp`, and `--power` (with SSD
  cache/preload tuning when selected).

It never records a PID, listening port, endpoint URL discovered at runtime,
readiness state, process handle, hardware snapshot, or diagnostic output. The
provider's loopback base URL is a persisted capability placeholder; the actual
port and endpoint are transient. API-key storage remains governed by the normal
provider credential contract, and local DS4 requests suppress credentials when
sent to the loopback child.

## Runtime ownership and lifecycle

- `ZenCODECore` owns the scanner, catalog/advisor, setup integration, manifest
  DTOs, remote client adaptation, and `DS4ServerSupervisor`. `zen` remains the
  composition root; terminal, Telegram, and ACP layers do not own DS4
  processes.
- The supervisor starts lazily on preload/first generation, binds only a
  loopback host, chooses or validates a loopback port, constructs direct argv,
  verifies readiness through `/v1/models`, and checks the expected API model ID.
  The supervisor owns the managed values for host, port, model path, working
  directory, backend, context, SSD streaming, MTP, power, and related
  server/security flags; arbitrary additional arguments cannot override them.
- `stop` reaps the child while keeping the supervisor reusable. `shutdown` is a
  terminal fence: it cancels pending startup, stops the child owned by that
  supervisor, and prevents a late task from resurrecting it. A factory-created
  supervisor belongs to that backend incarnation and is shut down before a
  replacement backend takes over.
- A delegated client may borrow the root DS4 owner only when it keeps the same
  DS4 provider/model selection. A child that selects another provider receives
  neither the root supervisor nor its loopback endpoint.
- An injected endpoint is an internal test/composition seam. ZenCODE does not
  discover or terminate an unrelated process by PID or port.

## Troubleshooting boundaries

| Observation | Meaning | Action |
| --- | --- | --- |
| No GGUF found | The folder-only scanner found no usable artifact in its two scan locations. | Place an existing regular GGUF in the root or `gguf/`, then rerun setup. |
| Artifact is not in the catalog | ZenCODE has no evidence-backed mapping for that file/model. | Use a catalog-supported artifact; do not assume a filename is compatible. |
| Hardware or memory is unknown | The diagnostic probe could not prove an operational choice. | Resolve the host/tooling issue outside setup; no automatic fallback is made. |
| No operational proposal | The artifact may be partial, unsupported by the proven backend, or too large for the documented mode. | Choose another already-installed catalog artifact or configure the host externally. |
| Runtime executable/readiness failure | Setup succeeded as metadata staging, but the existing DS4 binary did not become a compatible loopback server. | Inspect the DS4 checkout and its own diagnostics; ZenCODE will not download or build it. |

For final validation, use fixture-based DS4 and setup tests. Do not point tests at
a real checkout, launch a real DS4 server, download/build model assets, or run
inference.
