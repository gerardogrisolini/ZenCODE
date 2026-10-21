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
| Staged setup | Select one or more of the discovered GGUF files, then a backend and tuning values for each of them. No hardware probe or compatibility check is performed. | A staged provider with one model per selected file, each with its own launch parameters; the normal setup transaction persists it. |
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
- Every regular `.gguf` found is selectable. Files known to the bundled catalog
  get its display name and API model id; other files use the file name as the
  title and the API model id is inferred from the file name (see below). Only
  files the catalog marks as shards of a multi-artifact entry are not offered.
- For generation after setup, keep a runnable DS4 executable in the checkout's
  conventional location (`ds4-server`, `ds4`, `bin/ds4-server`, or `bin/ds4`),
  unless an internal composition root supplies an explicit executable. Setup
  itself does not launch or validate that process.

Setup performs no hardware probe and no compatibility advice: choosing a GGUF
and backend that fit the machine is up to you.

## Setup flow

1. Open `/setup` and select **DS4 local runtime**, or reconfigure the DS4
   provider from **Providers & models**. Both use the same flow and never call
   `/models` (DS4 is not running during setup).
2. Enter the existing DS4 folder. A prior canonical folder is offered as the
   default when one is already configured.
3. ZenCODE scans only `<folder>/*.gguf` and `<folder>/gguf/*.gguf` (read-only)
   and shows every regular GGUF in a multi-select menu. The files already
   configured are preselected. Each selected file becomes one model of the DS4
   provider; an empty selection or cancelling leaves the manifest unchanged.
4. For each selected model, choose its backend from a single-choice menu
   (`metal`, `cuda`, `rocm`, `cpu`). The default is that model's previous
   backend, otherwise `metal` on macOS and `cpu` elsewhere.
5. For each selected model, choose its managed runtime tuning values: context
   window (`--ctx`, default 65,536 tokens), SSD streaming
   (`--ssd-streaming`, defaulting to the model's prior value, otherwise off), embedded
   MTP (`--mtp`, off by default), and GPU duty-cycle power (`--power`, 1–100,
   default 100). When reconfiguring, each model is offered its own saved
   values; a newly added model starts from the defaults and never inherits
   another model's settings. Cancelling any prompt leaves the manifest unchanged.
6. Finish setup normally. Only the final setup transaction writes settings.
   Existing non-DS4 providers, models, API-key entries, and unrelated settings
   are retained. Re-running the flow replaces the DS4 models with the new
   selection while preserving the id, title, parameter overrides and thinking
   options of models whose file is still selected. The provider is staged at
   `http://127.0.0.1:8000/v1` (the conventional ds4-server loopback endpoint)
   when new; runtime first probes this bounded candidate and verifies the
   requested model id before adopting it, otherwise it starts its own child on a
   dynamically reserved loopback port. Setup itself never starts DS4.

A fresh model keeps a ZenCODE selection identity: `ds4:<catalog-id>` for a
catalog file or `ds4:<lowercased file stem>` otherwise (made unique when needed).
The model ID sent to DS4 and checked against `/v1/models` is the API id: the
catalog entry's canonical id, or for other files the id inferred from the file
name (case-insensitive, first match wins): `deepseek-v4.1` →
`deepseek-v4.1-flash`; `deepseek-v4-pro`/`v4-pro` → `deepseek-v4-pro`;
`deepseek-v4-flash` → `deepseek-v4-flash`; `qwen3.8` → `qwen3.8-flash-next`;
`glm-5.3` → `glm-5.3-flash`; `glm-5.2` → `glm-5.2`. If the name does not match,
setup asks you to pick one of those six ids, which are the only ones the ds4
server serves. These identities must not be interchanged when inspecting a
manifest or diagnosing readiness.

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
readiness state, process handle, or diagnostic output. The
provider's loopback URL is an adoption hint: setup defaults to
`http://127.0.0.1:8000/v1`, while a managed child may use a transient dynamic
port when that candidate is absent or incompatible. API-key storage remains
governed by the normal provider credential contract, and local DS4 requests
suppress credentials when sent to the loopback child.

## Runtime ownership and lifecycle

- `ZenCODECore` owns the scanner, catalog, setup integration, manifest
  DTOs, remote client adaptation, and `DS4ServerSupervisor`. `zen` remains the
  composition root; terminal, Telegram, and ACP layers do not own DS4
  processes.
- The supervisor starts lazily on preload/first generation. Before launching,
  it probes only the explicit loopback adoption candidate (the conventional
  `127.0.0.1:8000`, or the configured provider port), checks `/v1/models`, and
  verifies the expected API model ID. A compatible listener is represented as
  an adopted endpoint and is never terminated by ZenCODE. If adoption fails,
  the supervisor chooses or validates a loopback launch port for its own child,
  constructs direct argv, verifies readiness, and checks the same model ID.
  The supervisor owns the managed values for host, launch port, model path,
  working directory, backend, context, SSD streaming, MTP, power, and related
  server/security flags; arbitrary additional arguments cannot override them.
- `stop` detaches an adopted endpoint or reaps a managed child while keeping
  the supervisor reusable. `shutdown` is a terminal fence: it cancels pending
  startup, stops only the child owned by that supervisor, and prevents a late
  task from resurrecting it. A factory-created supervisor belongs to that
  backend incarnation and is shut down before a replacement backend takes
  over.
- A delegated client may borrow the root DS4 owner only when it keeps the same
  DS4 provider/model selection. A child that selects another provider receives
  neither the root supervisor nor its loopback endpoint.
- An injected endpoint is an internal test/composition seam. ZenCODE does not
  discover or terminate an unrelated process by PID or port; adopted endpoints
  are explicitly external and are never killed on backend reset or full exit.

## Troubleshooting boundaries

| Observation | Meaning | Action |
| --- | --- | --- |
| No GGUF found | The folder-only scanner found no usable artifact in its two scan locations. | Place an existing regular GGUF in the root or `gguf/`, then rerun setup. |
| Artifact is not in the catalog | The file is still selectable; its API model id is inferred from the file name, or asked. | Rename the file to include its family (for example `qwen3.8`) or pick one of the six served ids. |
| Multi-shard catalog artifact missing from the list | Shards of multi-artifact catalog entries cannot run on their own. | Join the shards into a single GGUF first. |
| Runtime executable/readiness failure | Setup succeeded as metadata staging, but the existing DS4 binary did not become a compatible loopback server. | Inspect the DS4 checkout and its own diagnostics; ZenCODE will not download or build it. |

For final validation, use fixture-based DS4 and setup tests. Do not point tests at
a real checkout, launch a real DS4 server, download/build model assets, or run
inference.
