# Xcode ACP setup

Xcode can run `zen` as an ACP stdio coding agent.

## Prerequisites

1. Install `ZenCODE` and run it once. Setup opens automatically when the
   configuration is missing:

   ```bash
   zen
   ```

2. If you want the optional Xcode-native tools, install their macOS-only feature package:

   ```bash
   zen --install-features xcode-tools
   ```

   The Xcode MCP implementation is not part of the `zen` executable or the root
   SwiftPM graph. It runs through the separately installed
   `xcode-tools-feature` process.

3. Make sure the recommended agents exist. The setup can create `Developer`, `Builder`, `Minimal`, `Planner`, `Reviewer`, and `Reporter`.
4. Verify the executable path:

   ```bash
   which zen
   ```

   The default script install usually returns `/usr/local/bin/zen`.

## Add `ZenCODE` in Xcode

1. Open **Xcode**.
2. Open **Xcode > Settings…**.
3. Select **Intelligence**.
4. In **Coding Agents**, click **Add an Agent**.

![Xcode Intelligence settings showing Coding Agents](Images/xcode-intelligence-agents.png)

## Configure the agent

In the agent editor, set:

- **Name**: `ZenCODE`
- **Executable**: the full path returned by `which zen`, for example `/usr/local/bin/zen`
- **Arguments**: `--acp`
- **Interpreter**: leave empty

To pin a specific agent profile, add this environment variable:
- **Name**: `ZENCODE_AGENT_NAME`
- **Value**: `Minimal`

![Xcode agent arguments and environment configuration](Images/xcode-agent-arguments.png)

Save the agent.

## Recommended configuration

Use this final configuration:

```text
Name: ZenCODE
Executable: /usr/local/bin/zen
Arguments: --acp
Interpreter: <empty>
Environment:
  ZENCODE_AGENT_NAME=Minimal
```

## Troubleshooting

- **Xcode cannot start the agent**: use an absolute executable path, not just `zen`.
- **Xcode tools are unavailable**: install or update `xcode-tools` with `zen --install-features xcode-tools`, keep Xcode open, enable the package in `/tools`, and approve any MCP/automation prompt shown by Xcode.
- **No model is configured**: run `zen` in Terminal; setup opens automatically. If the TUI is already running, use `/setup`.
- **“This provider requires authentication” in Xcode 27 beta 3**: update ZenCODE, select **Continue with ZenCODE**, then retry the session. This is an Xcode ACP compatibility acknowledgment, not provider authentication.

## Standard ACP presentation: scope and verification

ZenCODE emits standard ACP v1 `plan`, `tool_call`, `tool_call_update` and
`available_commands_update` updates. Only the supported, capability-gated `goal`,
`review` and `plan` commands are advertised; textual command responses remain the
fallback. Creating a delegated agent is distinct from that agent's execution and
from task validation. Failed/blocked/cancelled plan entries are explicitly labelled
because ACP's plan status enum has no matching failure values. Taskless idle or
standby alone is not evidence of successful execution.

Diffs are **per operation**, not a reconstructed end-of-turn summary. When Xcode
advertises the standard ACP filesystem capabilities, `local.readFile` /
`local.readFiles` read client text, and `local.writeFile` / `local.editFile` /
`local.multiEdit` / `local.replace` write through the client rather than bypassing
its buffers. The latter three require both read and write capabilities. No extra
agent, MCP extension or Xcode setting is required. The tool descriptions direct
text edits to these client-backed tools; project structure, builds, tests and
diagnostics continue to use the Xcode tools. Other local operations (including
append, applyPatch, move and delete) retain their filesystem implementation.

For client writes, a complete known preimage is rechecked before the write and the
acknowledged result is reread before emitting a standard diff. This is not atomic
against concurrent editor changes: ACP v1 has no revision-conditional write. A
missing/unreadable preimage is unknown, not proof that a file was absent. Client
errors never fall back to disk; failed verification after an acknowledged write
suppresses the diff without falsely reporting that the write failed. Client-owned
parent-directory handling and actual UI rendering remain client behavior. The
capabilities are checked on every connection and are not persisted.

Without negotiated client access, diffs are **per local operation**. The
local write/edit/replace/multiEdit/append/applyPatch/delete/move paths capture
actual before/committed text; delegated tool rows have agent-qualified IDs. Binary
or unreadable files, directories, failed/rolled-back operations, and opaque
shell/Git/MCP effects retain text instead of inventing a diff. A move is represented
as deletion at the source and a write at the destination. Partial rollback failures
retain their existing explicit error text. No patch string is passed off as a
file's old or new contents. Capture is limited to verified regular files, at most
64 KiB per text and 256 KiB per operation. Snapshot reads and emitted old/new
content have separate cumulative 256 KiB budgets; oversize evidence falls back to
text without truncation. Ordinary tool results without operation evidence keep
only their existing output content, without synthetic diff-unavailable notices.

Concurrent known local commits are serialized. An overlapping opaque execution
suppresses reliable-diff presentation. **After a successful background exec launch,
that conservative suppression lasts until this ZenCODE process exits**, even if
the job later finishes: there is no trustworthy end-of-writers signal here.
Unrelated external writers are outside the in-process attribution guarantee.

Permission dialogs use the root ACP session for delegated requests, with distinct
per-agent consent keys and root cleanup. Only offered `allow_once`/`allow_always`
choices authorize; cancellation takes precedence over contradictory selection
fields. Legacy response envelopes are still decoded, but an invented `allow_*`
option is not authorization. Full-access policy and persistent local.exec consent
remain unchanged. Pending tool rows do not claim execution while permission is
still being requested.

Wire/schema tests **do not demonstrate that Xcode renders these views**. Rendering
must be verified independently in a real Xcode session (plan replacement/clear,
parallel agents and retry, file diff, command catalog, permission cancel/deny).
No live-provider/network exercise or Xcode UI verification accompanies these source
changes. Added focused suites: `ACPStandardPresentationTests`,
`ACPPresentationLifecycleIntegrationTests` and `OperationFileChangeTests`; the new
regressions require independent execution before release. Presentation observers
are prompt-scoped and do not claim live updates while no ACP prompt is active.
The next prompt reattaches existing runtime observation even when the root emits
only text. Each taskless runtime execution has a separate transient identity;
previous output cannot complete a later running turn. Close drains accepted
updates before replying; replacement prompt/session fences suppress stale output.
