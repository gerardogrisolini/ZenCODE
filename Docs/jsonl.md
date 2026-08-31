# Headless JSONL Protocol

`zen --jsonl -p PROMPT` runs one non-interactive agent turn and writes a
machine-readable JSON Lines stream to standard output. Use it when a script,
CI job, or another process needs lifecycle events in addition to the final
assistant response.

```bash
zen --jsonl -p "Summarize the current changes"
```

JSONL mode requires `-p` or `--prompt`. It cannot be combined with `--acp`.
The ordinary `zen -p PROMPT` mode remains available when only the final text is
needed.

## Stream contract

While JSONL mode is active:

- stdout contains one complete compact JSON object per line;
- every line ends with LF (`\n`), including the terminal record;
- records are emitted in lifecycle order;
- every record contains `schema_version`, `type`, and the same opaque `run_id`;
- stderr is empty;
- a successful process exits with status `0`;
- a failed process emits an `error` record and exits with status `1`.

`run_id` correlates records from one invocation. Treat it as an opaque string;
it is not a session identifier and must not be parsed.

Each record currently uses `schema_version: 1`. Consumers should check this
field before interpreting a record. For resilient parsing, ignore unneeded
fields and event types, but do not interpret an unsupported schema version as
version 1.

JSON object member order is not significant. Only line order carries lifecycle
meaning.

## Record types

### `run.started`

The runtime accepted the request and started a headless run.

```json
{"schema_version":1,"type":"run.started","run_id":"A3B0..."}
```

There are no type-specific fields.

### `tool.started`

A tool call started.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Tool-call identifier, unique within the run |
| `name` | string | Public tool name, for example `local.readFile` |

```json
{"schema_version":1,"type":"tool.started","run_id":"A3B0...","id":"call-1","name":"local.readFile"}
```

### `tool.completed`

A tool call finished. This record is informational rather than terminal: a
failed tool may be handled by the agent and the run may still complete
successfully.

| Field | Type | Values |
| --- | --- | --- |
| `id` | string | Identifier from the matching `tool.started` record |
| `name` | string | Public tool name |
| `status` | string | `completed`, `failed`, or `permissionDenied` |

```json
{"schema_version":1,"type":"tool.completed","run_id":"A3B0...","id":"call-1","name":"local.readFile","status":"completed"}
```

A terminal run error can interrupt a tool call, so consumers must not wait
indefinitely for a matching `tool.completed` after receiving `error`.

### `message.completed`

The complete final assistant response. Version 1 does not expose partial
content events.

| Field | Type | Meaning |
| --- | --- | --- |
| `text` | string | Final assistant text; embedded newlines are JSON-escaped within the one physical JSONL line |

```json
{"schema_version":1,"type":"message.completed","run_id":"A3B0...","text":"No uncommitted changes."}
```

### `run.completed`

The terminal success record.

| Field | Type | Value |
| --- | --- | --- |
| `status` | string | `completed` |

```json
{"schema_version":1,"type":"run.completed","run_id":"A3B0...","status":"completed"}
```

### `error`

The terminal failure record. Error details are classified and redacted before
they reach the wire.

| Field | Type | Values |
| --- | --- | --- |
| `category` | string | `configuration`, `provider`, or `runtime` |
| `message` | string | Stable public description without raw diagnostics |

```json
{"schema_version":1,"type":"error","run_id":"A3B0...","category":"configuration","message":"No prompt provided. Pass text after -p/--prompt."}
```

Do not parse `message` to determine the error class; match on `category` and the
process exit status. Raw provider errors, URLs, paths, credentials, and internal
diagnostics are deliberately not serialized.

## Valid lifecycle endings

A successful run has this general shape:

```text
run.started
(tool.started / tool.completed records, when tools are used)
message.completed
run.completed
```

A runtime failure has this general shape:

```text
run.started
(optional tool lifecycle records)
error
```

An argument or configuration failure may happen before the runtime exists. In
that case `error` is the only record. The final record is always exactly one of
`run.completed` or `error`; once it is emitted, no more records follow.

## Input and shell examples

The prompt is passed with `-p` or `--prompt`:

```bash
zen --jsonl --prompt "List the risky changes"
```

Redirected stdin is plain additional prompt context; it is not a JSONL request
stream:

```bash
git diff | zen --jsonl -p "Review this diff"
```

Pretty-print every event with `jq`:

```bash
zen --jsonl -p "Summarize the repository" | jq
```

Extract only the final assistant text:

```bash
set -o pipefail
zen --jsonl -p "Summarize the repository" \
  | jq -r 'select(.type == "message.completed") | .text'
```

`set -o pipefail` preserves a nonzero `zen` status through the pipeline.
Programs that consume the stream directly should still handle the terminal
`error` record rather than relying only on the process status.

A minimal Python consumer can process the stream incrementally:

```python
import json
import subprocess

process = subprocess.Popen(
    ["zen", "--jsonl", "-p", "Summarize the repository"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

for line in process.stdout:
    record = json.loads(line)
    if record["schema_version"] != 1:
        raise RuntimeError("unsupported ZenCODE JSONL schema")
    if record["type"] == "tool.started":
        print(f"tool: {record['name']}")
    elif record["type"] == "message.completed":
        print(record["text"])
    elif record["type"] == "error":
        print(f"{record['category']}: {record['message']}")

if process.wait() != 0:
    raise SystemExit("ZenCODE run failed")
```

## Privacy boundary

Version 1 intentionally exposes only run lifecycle, tool identity and status,
the final assistant text, and redacted terminal errors. It does **not** expose:

- the prompt or piped stdin context;
- tool arguments, output, summaries, or attachments;
- model thinking, partial assistant content, or internal status updates;
- diagnostics, metrics, context-window data, subscription usage, or session
  snapshots.

The final assistant text itself may contain information derived from the prompt
or tool results. Consumers remain responsible for storing or forwarding that
text appropriately.

## Meta-commands

`--help`, `--version`, `--doctor`, and `--install-features` take precedence over
`--jsonl`. When one of them is present, JSONL mode is ignored and the command
keeps its existing human-readable stdout/stderr and exit behavior.

For example, this prints ordinary help text rather than JSONL:

```bash
zen --jsonl --help
```

## JSONL versus ACP

JSONL is a one-shot, output-only event stream for shell automation. It accepts
one ordinary text prompt from the command line, optionally augmented by piped
stdin, then exits.

ACP is a bidirectional JSON-RPC protocol over stdio for compatible interactive
clients. Use `zen --acp` for ACP integrations; `--jsonl` and `--acp` are mutually
exclusive.
