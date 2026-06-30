# Local MLX Runtime

`zen --mlx` runs the coding agent with the local MLX runtime embedded in the same process. It does not start an HTTP server.

## Setup

```bash
zen --setup
```

Choose the local MLX runtime and local MLX models actions from the setup menu.
Those actions write:

```text
~/.zencode/mlx/settings.json
~/.zencode/mlx/models.json
~/.zencode/mlx/KVCaches/
```

## Run

```bash
zen --mlx --cwd /path/to/project
zen --mlx --agent Feature --model qwen3-mlx --cwd /path/to/project
zen --mlx --acp --cwd /path/to/project
```

## KV Cache Persistence

The local MLX runtime keeps a per-session KV cache so a continued conversation
does not re-prefill the whole transcript on every turn. The live cache lives in
memory during a session and is persisted to disk in `~/.zencode/mlx/KVCaches/`.

Persistence behavior:

- The disk cache is written when a session is closed (ACP `session/close`) or
  when the runtime shuts down, not after every request.
- On reconnect, the cache is restored from disk through `session/load`,
  `session/resume`, and `session/new` when the request carries transcript
  history.
- Cache lookup is keyed by session identity. When an ACP client provides a
  `sessionKey`/`cacheKey`, that key is used. When no key is provided, the
  runtime derives a stable key from the conversation opening (system prompt and
  first user message), so stateless clients that resend their transcript still
  reuse the cache across reconnections, even without a `session_id`.
- A restore only succeeds when the model, cache layout, tools, and the stored
  transcript prefix match the incoming request; otherwise the runtime falls
  back to a normal prefill.

Empty the disk cache with:

```bash
zen --setup
```

## Reset

```bash
zen --setup
```

Choose the reset actions from the setup menu. Local MLX reset removes managed
MLX settings and model catalog files from `~/.zencode/mlx/`; local MLX disk
cache reset empties `~/.zencode/mlx/KVCaches/`.
