# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime in this repository. It runs as a standalone terminal agent, as an ACP stdio agent, with cloud providers or your ChatGPT/Claude subscription.

## Modes

```bash
zen          # standalone chat TUI
zen --acp    # ACP over stdio for compatible clients
```

Standalone `zen` uses providers/models from `~/.zencode/settings.json`.

## Recovering Incomplete Tasks at Startup

When standalone `zen` starts in an interactive terminal, it scans the current
project for task-graph checkpoints left incomplete by earlier sessions. If any
are found, an orange, scrollable picker opens before the model session is
created. Use `↑`/`↓` to move and `Enter` to select the graph marked with `(x)`.
You can also choose **Start fresh** to leave every checkpoint unchanged.
The startup scan and picker are disabled when `zen` runs in `--acp` mode.

Selecting **Delete old tasks…** opens a multi-selection list. Use `Space` to
mark obsolete graphs with `[x]`, `A` to select all, `N` to select none, and
`Enter` to delete the selected graphs. Deletion is graph-specific: other graphs
stored in the same previous session are preserved.

> **Exact-graph recovery guarantee:** a recovery choice identifies both the
> previous logical session and the selected graph. ZenCODE restores the
> checkpoint, makes that exact graph active and current, persists the new
> `currentGraphID`, and only then creates the model/backend session. It never
> substitutes another graph merely because that graph was current when the old
> checkpoint was written. Any active execution attempt found in the checkpoint
> is marked `interrupted`, and its task becomes `blocked`; external work is not
> assumed to still be running after a process restart.

This startup recovery concerns the authoritative task graph. It is separate
from `/sessions restore`, which navigates the saved conversation checkpoint
tree and creates a new conversational branch.

## First Setup

```bash
zen
```

When required configuration is missing or invalid (`settings.json` or
`agents.json`), or when no model is configured, `zen` opens setup automatically before starting the chat. Use `/setup` later to
reconfigure ZenCODE; the TUI saves the current session, rebuilds the runtime,
and restores the conversation without closing the app.

Creates files under `~/.zencode/`:

- `settings.json` — provider/model configuration, selected model, optional Telegram, voice, and memory-embedding settings (endpoint, optional model).
- `permissions.json` — persistent runtime approvals.
- `agents.json` — agent profiles, authorized model bindings, tools, and instructions.
- `AGENTS.md` — global operating guidance shared across workspaces. This is
  separate from an optional project `AGENTS.md` in the working directory.
- `memory/` — per-workspace project memory graphs: one `memory.graph.json` per workspace, under a SHA-256 digest of the workspace path.
- `sessions/` — saved session snapshots grouped by project.
- `task-graphs/` — atomic project/session task checkpoints, including explicitly saved plans.
- `features/` — generated Builder packages and installed optional feature packages.
- `source/` — persistent ZenCODE checkout retained by the platform installer for later optional-feature builds.

## Data Management (Backup Export/Import)

The **Data management** entry of `/setup` (also available from first-run
setup, with no models configured yet) moves the whole `~/.zencode/`
directory between machines in one step:

- **Export backup** writes a single compressed `.tar.gz` archive containing
  every file under the support directory — including hidden files and
  nested directories such as `memory/`, `sessions/`, and `features/`.
  Temporary coordination artifacts of the export itself are excluded, and
  the archive is never added to itself when saved inside `~/.zencode/`.
  The export runs under the support directory's coordination lock, so the
  archive is a coherent snapshot of one moment in time rather than a mix
  of states captured while settings were being written. If the support
  directory contains a symbolic link, the export fails with an explicit
  error instead of silently skipping it — a backup that silently drops a
  link is worse than one that refuses to lie. Overwriting an existing
  archive keeps the old one until the new export is complete; a failure
  during the replacement restores the previous archive.
- **Import backup** validates the archive completely *before* touching any
  data — structure, version, per-file size and SHA-256 checksum, path
  traversal and symbolic-link rejection, and entry-count/size limits — and
  only then replaces the support directory in one atomic rename. The
  current data is moved aside and restored automatically if anything fails,
  so a failed or rejected import never leaves a half-replaced directory.
  The replacement also preserves the coordination lock file's inode, so
  concurrent processes keep a single shared exclusion boundary before,
  during, and after the swap.
- **Reset remote configuration** is the same reset previously found in the
  main setup menu, now grouped here with the other data operations.
- **Back** returns to the main setup menu. Cancelling any prompt leaves
  the data untouched.

Backups are **not encrypted**: they contain provider API keys, OAuth
tokens, and permissions in plain text, exactly as stored on disk. Keep the
archive private, and prefer a secure channel when moving it to another
machine. After a successful import, setup restarts so the imported
configuration is read from scratch.

The support directory actually used — including any `ZENCODE_SUPPORT_DIRECTORY`
override — is the one exported and imported, and every prompt prints the
exact paths involved.

## Command Line Options

```text
zen [--version] [--doctor] [--install-features [id,id,...]] [--no-features] [--zen-package-path DIR] [--acp] [--agent NAME] [--model MODEL_ID] [--working-directory PATH] [--skills LIST] [--max-tool-rounds N] [--max-output-tokens N]
```

- `--version`: print the ZenCODE version and exit.
- `--doctor`: print a redacted, read-only diagnostic report and exit. It never
  starts setup, accesses a provider, creates configuration, or writes a log.
- `--acp`: run ACP JSON-RPC over stdio.
- `--install-features [id,id,...]`: copy the requested optional feature package(s), build their release products, and enable them. With no IDs in an interactive terminal, opens the optional-feature picker.
- `--no-features`: skip optional-feature installation when used with `--install-features`.
- `--zen-package-path DIR`: use this ZenCODE checkout as the feature source and rewritten local package dependency. This is useful after a manual installation; platform installers preserve their checkout under `~/.zencode/source/` automatically.
- `--agent NAME`: select an agent profile (default: `Developer`).
- `--model MODEL_ID`: request a model override for the direct session; delegated sub-agents remain restricted to the selected profile's authorized bindings.
- `--working-directory PATH`: working directory for local tools.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt.
- `--max-output-tokens N`: maximum generated tokens per model call.

Environment variables mirror these: `ZENCODE_AGENT_MODE`, `ZENCODE_AGENT_NAME`, `ZENCODE_AGENT_MODEL`, `ZENCODE_AGENT_CWD`, `ZENCODE_AGENT_SKILLS`, `ZENCODE_AGENT_MAX_TOOL_ROUNDS`, and `ZENCODE_AGENT_MAX_OUTPUT_TOKENS`.

## Optional Feature Packages

Search, web, browser, Git, Swift, Jira, Figma, Xcode, and desktop integrations
are catalogued optional SwiftPM packages. They are **not** executable files
shipped next to `zen`, and the root `swift build` does not build them. Install
only the ones you need:

```bash
zen --install-features git-tools,swift-tools
zen --install-features                    # interactive picker
zen --install-features --no-features      # explicitly skip the picker/install
zen --install-features web-tools --zen-package-path /path/to/ZenCODE
```

The command copies each package into `~/.zencode/features/<id>/`, rewrites its
marked dependency on the ZenCODE checkout, creates the normal Builder-compatible
`feature.json`, builds its release product, then enables it. Consequently an
uninstalled feature remains visible as installable but contributes no available
tools to a profile or `/tools` selection. After installation, its package can be
selected and managed exactly like a local Builder feature.

The **Features** step of `/setup` covers the same lifecycle. Its rows are
grouped as `Bundled`/`Generated` (check to enable, uncheck to disable),
`Installable` (not installed yet), and, only when source changes are available,
`Update installed`. That last group is hidden when every installed package
already matches the current ZenCODE source. Checking an `Update installed` row
reinstalls that package and rebuilds it; the reinstall also applies the enabled
state expressed by that feature's own row.

The macOS/Linux installers do not offer a feature picker: they install `zen`
only. They remove the legacy `zen-features/`
directory and, when bootstrapped from a temporary URL checkout, keep a
source-only copy at `~/.zencode/source/` so future installs still work after
that temporary checkout is removed. An installer launched from a local checkout
uses that checkout directly. Set `ZENCODE_SUPPORT_DIRECTORY` to relocate both
`features/` and the persisted `source/` copy.

`xcode-tools` and `desktop-tools` are macOS-only and are never offered on Linux.
`desktop-tools` (`desktop.run`) drives the real desktop — pointer, keyboard,
clipboard, windows, app lifecycle, and PNG screenshots that are attached to the
model's multimodal context — so macOS asks for Screen Recording and
Accessibility consent on first use. Call `action=permissions` before anything
else, and enable it only for a profile that is meant to control the machine.

## Diagnostics

Run `zen --doctor` when setup, permissions, or provider configuration looks
wrong. It reports environment, configuration state, sensitive-file privacy, and
the diagnostic-log status without printing API keys, OAuth tokens, or Telegram
credentials. A missing setup is a warning, so the command remains convenient in
scripts and clean installations.

Local diagnostics are off by default and never use remote telemetry. Enable a
redacted system log explicitly when investigating an issue:

```bash
ZENCODE_LOG=debug zen
```

Diagnostics are emitted to the platform system log — Unified Logging on macOS
(subsystem `com.zencode.zen`, categories `diagnostics-*`) and syslog/journal on
Linux/WSL — with `ZENCODE_LOG` selecting the threshold (for example, `debug`,
`info`, `warning`, or `error`). They never write
to stdout, stderr, or an application-owned file, so ACP JSON-RPC output remains
clean. The legacy `ZENCODE_LOG_FILE` and `ZENCODE_LOG=stderr` destinations have
been removed and are reported as invalid by `zen --doctor`. Use `/tools logs`
to open the native system log viewer (Console.app on macOS). See
[security.md](security.md) for the protection model.

## Agent Profiles

Agent profiles live in `~/.zencode/agents.json` and are managed in setup. The
recommended profiles are `Developer`, `Builder`, `Minimal`, `Planner`,
`Reviewer`, and `Reporter`. Each defines tools, an optional enforced `readOnly`
core-tool policy, skills, instructions, and model bindings.

Switch profiles in the TUI without restarting:

```text
/agents                 # picker
/agents Builder         # by name
/agents 2               # by number
```

Switching resets the conversation so the new system prompt and tools apply
cleanly. If the selected profile has bindings, its default is used when no model
has been selected explicitly; `/models` always presents every configured model
and a manual selection overrides that default for the active session.

Use `/setup` to inspect and configure the model bindings of every profile — see
[bindings.md](bindings.md) for how bindings, capability, and task complexity
drive delegation, and [agents.md](agents.md) for profile and sub-agent concepts.

## Terminal TUI Commands

Commands start with `/`:

**Setup and navigation:**
- `/help` — show command help.
- `/setup` — save the current session, open setup, rebuild the runtime from the updated configuration, and restore the conversation.
- `/models` — show every configured model and choose the model for the current session.
- `/agents [list|<name>|<number>]` — switch agent profile.
- `/tools [all|none|tool-name|package-name|number]` — select exposed tool groups; `/tools logs` opens the platform system log viewer (Console.app on macOS).
- `/skills` — select or install prompt skills; `/skills uninstall` opens a multi-selection menu for removing app-installed skills.
- `/exit` — close the session.

**Sessions and memory:**
- `/sessions` — list and select saved sessions.
- `/sessions <name>` — save or overwrite a named snapshot.
- `/sessions save` — save the current session (derives a name from the first prompt if none is active).
- `/sessions compact` — force context compaction without saving.
- `/sessions new` — reset to a fresh, unsaved session.
- `/sessions delete` — delete a saved snapshot.
- `/sessions restore [entry-id]` — restore in-place from a checkpoint, branching from that point; without an argument an interactive picker over the checkpoint entries opens.

**Attachments:**
- `/attach <file> [file ...]` — attach image/video files to the next prompt.
- `/attach list` / `/attach delete [all|number]`.

**Files and changes:**
- `/open [file-or-url]` — list and open referenced files/URLs, or open one directly.
- `/changes` — show tracked file change summary.
- `/changes diff` — include patches.
- `/undo` — revert the most recent agent-tracked changes.

**Task graph:**
- `/tasks [status|list]` — show the session task graph.
- `/tasks show <id>` — show one task with dependencies and attempts.
- `/tasks retry <id>` — return a failed/blocked task to `pending`.
- `/tasks cancel <id> [reason]` — cancel task and active worker.
- `/tasks clear` — remove all task graphs for the logical session.

**Agentic workflow:**
- `/plan <goal>` — delegate planning to a sub-agent using the configured `Planner` profile. It may ask numbered clarification blocks over multiple turns; normal replies continue that runtime-only discussion with the same Planner, while a new goal closes and replaces it. The same command family is routed by the linked Telegram chat and ACP. See [planner.md](planner.md).
- `/plan save` — save the active plan, or the latest non-empty assistant response, as a reusable unapproved draft in the current project's plan library.
- `/plan load` — when no plan is active, load the latest saved project plan into the current context as unapproved and pending. Use `/plan clear` first to replace an active plan; loading never resumes old execution attempts.
- `/plan status` — show plan progress from the graph state.
- `/plan approve` — activate the plan and start implementation.
- `/plan clear` — archive the graph and remove the active plan.
- `/goal <goal>` — plan and delegate all work to sub-agents. It creates an active workflow graph up front; every graph task is enforced as a sub-agent execution attempt. It refuses to start while an active `/plan` exists; finish that plan or use `/plan clear` first. The current agent stays as coordinator and final reviewer, retaining its normal tool grant for that work. No separate Planner sub-agent or approval step. Use `/tasks` to monitor progress.
- `/review [focus]` — delegate review to sub-agents using the configured `Reviewer` profile. See [reviewer.md](reviewer.md).
- `/feature` — manage Swift feature packages (Builder profile only). See [builder.md](builder.md).

**`/plan` vs `/goal`:**

| | `/plan` | `/goal` |
|---|---|---|
| **Planning** | Delegated to a sub-agent using the configured Planner profile | Done by the current agent directly |
| **Approval step** | Yes — `/plan approve` activates the graph | No — starts immediately |
| **Task implementation** | The current agent works freely: directly or by delegating, as it sees fit | Every graph task must be claimed by a sub-agent; coordinator task attempts are rejected while its normal tool grant remains unchanged |
| **Sub-agent selection** | The model decides per task if and when to delegate | The model must assign the best-matching profile to every task |
| **Role of current agent** | Implementer (can delegate when useful) | Coordinator and final reviewer only |
| **Monitor progress** | `/plan status` or `/tasks` | `/tasks` |

### Live Agent Chat

While sub-agents are active, the coordinator and the agent instances share a
live, transient chat room. From the terminal **or linked Telegram chat**, address
it with a leading mention: `@coordinator` to message the live coordinator, `@all`
to reach the coordinator and every active agent, or a readable `@agent-name`
handle (derived from each instance's display name) to message it directly.
Autocomplete in the terminal lists every active agent by its readable handle;
routing always resolves back to the stable agent id behind the alias. Telegram
uses the same live-room routing for its linked session, including its native
replies to forwarded chat cards. The LLM side uses the `agent.message` tool with
the same destinations (`direct`, `operator`, `coordinator`, `peers`, `all`);
`operator` addresses only the human terminal operator. Every message is
available in the terminal's transient `Chat` reader; it is not rendered as a
message box in the main transcript. A coordinator or delegated agent already
working receives the message in the model-facing result of its next tool call,
replies immediately, and resumes its current work. If no further tool call
occurs, a synthetic coordinator turn or queued agent prompt is the fallback. A
direct turn started by the human operator normally replies with
`agent.message(to: "operator")`; if a provider instead completes with ordinary
final output, the runtime delivers that output to `operator` without involving
the coordinator or duplicating an explicit chat reply. The chat is in-memory and
never persisted; a session reset drops it. See the [Chat reader
states](#chat-reader-states) below and [agents.md](agents.md#messages).

#### Chat reader states

The terminal opens the reader with `Ctrl+Y` (`Ctrl+O` also works where the
terminal does not intercept it). The reader is a status-bar panel, separate
from the scrolling conversation transcript:

- **Closed with no messages:** the `Chat` panel is invisible and consumes no
  reserved rows.
- **Closed with messages:** the panel stays compact and shows the retained
  total plus the unread count, for example `Chat · 2 messages · 2 unread`.
- **Opened with no messages:** the panel remains compact, showing
  `Chat · 0 messages · Ctrl+Y close`; it does not create an empty body or
  footer.
- **Opened with messages:** the panel expands to show the selected message,
  unread count, and navigation hints. `Ctrl+Y` closes it back to the compact
  state.

Messages in every state remain out of the main transcript: the reader is the
only terminal rendering surface for these live chat entries.

### Saving and Loading Plans

`/plan save` stores a reusable copy for the current working directory. It uses
the active plan when one exists; otherwise it can promote the latest non-empty
assistant response into a text-only plan. The saved copy is reset to an
unapproved draft with pending task statuses, while the currently active plan is
left unchanged.

To hand a plan to another session, start a new session with `/sessions new` (or
use any session for the same working directory with no active plan), then run
`/plan load`. The command selects the newest saved plan, displays it, and adds a
handoff message to the model context. It refuses to replace an active plan, so
run `/plan clear` first when necessary. Loading does not restore the source
session, its active attempts, or its execution progress; review or revise the
draft, then run `/plan approve` to begin implementation.

Approval creates and activates the plan's task graph in the receiving session.
For a saved text-only plan with no structured items, ZenCODE creates one stable
implementation task rather than guessing a task breakdown from prose.

**Optional integrations:**
- `/telegram` / `/telegram on` / `/telegram off` — remote control (requires setup). Available even while a prompt is running.

Telegram pairs exactly one global owner through a private chat. That owner may route
multiple terminal sessions through a default private route or distinct private
`message_thread_id` topics; every route retains lifecycle, generation, lease and
wire-fence checks, including authorization prompts, voice notes and attachments.
Groups, shared members and per-route ACLs are not supported. Persisted routing uses
`routingVersion: 2`. Schema-1, ownerless or incoherent configurations remain
inactive and require a new pairing.

**Tool execution logs:** every direct tool call emits a secret-redacted structured
record through the platform system logger. Records include agent ID/name, model,
session, tool arguments, status, optional execution duration, and detailed typed
error causes; delegated agents are logged with the child's identity. On macOS the
records use Unified Logging subsystem `com.zencode.zen` and category
`tool-execution`. Use the exact command `/tools logs` to open Console.app. Console
does not accept a preconfigured filter when ZenCODE opens it, so paste
`c:tool-execution` into Console's search field and press Return. Then click
**Save**, give the search a name such as **ZenCODE**, and reuse it from Console's
Favorites whenever needed. Launcher failures are reported in the terminal and
never written to ACP stdout.

**Interactive shortcuts:**
- `Ctrl+G` — toggle default/full access mode (temporary, never persisted).

**Prompt editing shortcuts:**

These bindings follow the Emacs/readline conventions, so they work on every terminal, including laptop keyboards without `Home`/`End` keys. Terminals never receive `Command` shortcuts, so the macOS `Cmd+←`/`Cmd+→` motions are not available.

| Motion | Keys |
| --- | --- |
| Character left/right | `←`/`→`, `Ctrl+B`/`Ctrl+F` |
| Word left/right | `Alt+←`/`Alt+→`, `Ctrl+←`/`Ctrl+→`, `ESC b`/`ESC f` |
| Line start/end | `Ctrl+A`/`Ctrl+E`, `Home`/`End` |
| Draft start/end | `Alt+<`/`Alt+>`, `Ctrl+Home`/`Ctrl+End` |
| Previous/next line or history entry | `↑`/`↓`, `Ctrl+P`/`Ctrl+N` |
| Delete word before/after | `Ctrl+W` / `Alt+D` |
| Clear before/after cursor | `Ctrl+U`/`Ctrl+K` |
| Clear the whole draft | `Alt+Backspace` (macOS `Option+Delete`) |
| Newline without sending | `Shift+Enter` or `Option+Enter` |

On macOS, `Option+←/→` only reaches the prompt when the terminal sends the `Option` key as `Meta`: in Terminal.app enable *Settings → Profiles → Keyboard → Use Option as Meta key*, and in iTerm2 set *Settings → Profiles → Keys → Left Option key → Esc+*. `Ctrl+←/→` is captured by macOS Mission Control unless that system shortcut is disabled. `Ctrl+A`/`Ctrl+E` and `Alt+<`/`Alt+>` need no terminal configuration.

Full access bypasses only `local.exec` approval checks. It does not expose disabled tools or bypass OS permissions. The status bar shows a red dot while active.

`local.exec` authorization filters shell noise so that only significant commands trigger approval. Comments, decorative `echo`/`printf` (without output redirections), harmless built-ins (`true`, `false`, `cd`, `pwd`, …), environment assignments, wrappers (`env`, `command`, …), and control-flow keywords are stripped or skipped. Nested commands inside shell `-c` payloads, `$(...)`/backtick command substitutions, process substitutions `<(...)`/`>(...)`, and unquoted heredoc bodies are recursively inventoried, while `$((...))` arithmetic expansion and quoted heredoc bodies are treated as literal. Extended `[[ ... ]]` expressions, arithmetic `(( ... ))` commands, and `case` pattern alternatives remain opaque during pipeline segmentation, so regex, bitwise, and pattern `|` characters are not mistaken for shell pipes. Wrapper options that consume an operand (`env -u NAME`, `env -C DIR`, `time -o FILE`) are handled so the real executable surfaces, and introspection-only forms (`command -v`) are not authorized as executions. When parsing hits its recursion or candidate limits it fails closed by emitting a conservative fallback candidate. Each `local.exec` tool call presents one authorization request containing the full command; all parsed executable identities still participate in cache and persistence checks.

The terminal consent prompt makes the scope of **Always** explicit: for
`local.exec`, it remembers every parsed executable identity in the request across sessions; for
destructive direct tools it grants only the current process/session and is not
persisted. Use **Run once** when the broader executable-level approval is not
intended.

Delegated sub-agents ask for the same approvals as the coordinator. Their requests are routed on a runtime-minted delegation identity (the agent instance plus the operator session that owns its delegation tree) instead of the turn that spawned them, because delegated work keeps running after that turn returns. The prompt names the requesting agent, and a request whose root session is unknown to the runner is refused without asking. Full access bypasses these requests exactly as it does the coordinator's.

## Tool Selection

Tool groups include filesystem, shell, text, search, Git, memory, sub-agents, generated Swift features, and installed optional feature packages such as XcodeTools on macOS or FigmaTools. Use `/tools` to select per session. ACP clients pass enabled tools directly.

### Local file editing

`local.editFile`, `local.multiEdit`, and `local.replace` accept only the canonical `old`/`new` payload fields; the legacy aliases `oldString`, `old_string`, `newString`, and `new_string` are not supported. Empty or ambiguous matches are rejected, existing line endings are preserved, and `local.multiEdit` applies its edits atomically. Successful `local.editFile` and `local.multiEdit` responses are compact confirmations containing only the path and replacement/edit count; they do not return post-edit context or diffs.

## Task Orchestration

`todo.*` is a lightweight checklist for model-local coordination. `tasks.*` operates on the authoritative session task graph owned by `SessionTaskOrchestrator` — a validated DAG with atomic creation, dependency gating, optimistic fencing, and attempt history.

When work has multiple units, dependencies, or concurrent delegation, the coordinator creates a task graph first, then selects runnable work with `tasks.list` and assigns delegated tasks through `agent.create(taskID:)`. Each task carries a `complexity` (1–10) that is matched against the capability of the chosen profile's model binding — see [bindings.md](bindings.md). Report-agent success completes a task; implementation-agent success moves it to `awaiting_validation` until independently validated. Record a successful validation as completion. For negative validation, record `failed` with `tasks.update`, call `tasks.retry` to return the task to `pending`, then use a **new** `agent.create(taskID:)` to claim the new attempt. Do not use `agent.message` to reopen the already completed agent.

`/goal` uses a distinct graph source. Its tasks must declare `execution.executor: sub_agent`, and the orchestrator rejects coordinator attempts or graph replacement while that workflow is active. This enforces delegation at the task lifecycle boundary rather than by applying a read-only tool policy to the coordinator. A coordinator without `agent.create` may work directly only in a graph that permits coordinator execution; it must never create or directly execute a workflow task.

Checkpoints are written atomically under `~/.zencode/task-graphs/<project>/`.
`/plan save` reuses this checkpoint directory rather than creating a separate
plan store. It writes a draft copy of the active plan, or the latest non-empty
assistant response, to a stable project plan-library logical session, so
`/sessions new` may delete the live chat checkpoint without deleting explicitly
saved plans. Todo-derived items remain graph tasks, while optional metadata
carries the full goal and plan text needed by `/plan load`. `/plan load` selects
the newest saved draft only when no plan is active, adds its handoff to the
current model context, and does not activate its source session or resume old
execution state. Saved drafts are excluded from the interrupted-work startup
picker.
At interactive startup, ZenCODE enumerates every incomplete graph for the
current project and lets the operator resume one or delete obsolete graphs. A
selection is keyed by `sessionID + graphID`: the orchestrator restores the
owning session, makes the selected graph current, and persists that choice
before the backend session starts. Other active graphs from the same checkpoint
are archived when the selected graph takes ownership. Active attempts found
during restore are marked `interrupted` and their tasks become `blocked` rather
than being silently resumed. See
[Recovering Incomplete Tasks at Startup](#recovering-incomplete-tasks-at-startup).

## Skills

```text
/tools logs                       # open the platform system log viewer
/skills                          # select or install skills
/skills uninstall                # remove app-installed skills
zen --skills all                 # initial selection at launch
zen --skills "review,swift"
```

## Saved Sessions

```text
/sessions my-feature             # save named snapshot
/sessions save                   # refresh active snapshot
/sessions compact                # force context compaction
/sessions                        # list and load
/sessions delete
/sessions new                    # fresh, unsaved session
```

### Checkpoint Trees

Every saved session stores its conversation as a **tree of entries** alongside the flat message history. The initial history is a linear tree: every message is an entry. Entries are linked to their parent via an entry ID, so you can branch from any point and explore alternatives without losing the original path.

```text
/sessions save                   # persist the checkpoint tree to disk
/sessions restore                # restore via interactive entry picker
/sessions restore a1b2c3d4       # restore in-place by entry ID (branches)
```

**In-place branching** with `/sessions restore` navigates the active session to an earlier entry. It does not require a manually labelled checkpoint: `/sessions restore` without an argument opens an interactive picker containing all entries in the saved session, including ordinary message entries. Messages you send after restoring form a new branch in the tree. The original path is preserved; selecting the current active entry simply leaves the conversation at its current position.

Restore changes the active runtime session, but it does **not** immediately overwrite the saved session on disk. After inspecting or continuing from the restored point, run `/sessions save` to persist the new active position and branch. Until then, the previously saved snapshot remains unchanged. Restore reloads the saved snapshot associated with the active session, so save first if the current conversation contains messages or other state that must not be discarded:

```text
/sessions save                   # preserve the current state first
/sessions restore                # choose a previous entry and branch
```

To split a conversation into a separate file, restore to the desired point and then `/sessions <new-name>`: the new snapshot keeps the full checkpoint tree while the original session file stays unchanged.

### Session Format

Version 4 snapshots embed the checkpoint tree alongside the task graph and active plan. Sessions saved before v4 are not loadable. Remote sessions save the local transcript with replay metadata. Subscription sessions persist continuation metadata for efficient resume.

## Memory and Project Context

Durable context is separated by responsibility:

- Optional project `AGENTS.md` — workspace-specific constraints and workflows.
  Create and edit it manually in the working directory, and check it into
  version control when appropriate. When present, ZenCODE reads it and adds it
  to the agent context; it never creates or rewrites the project file
  automatically.
- Global `~/.zencode/AGENTS.md` — cross-workspace operating rules. This file is
  separate from the project file and applies across working directories.
- Project memory — a per-workspace graph of durable project facts stored outside the working tree at `~/.zencode/memory/<workspace-digest>/memory.graph.json` (honouring `ZENCODE_SUPPORT_DIRECTORY`). A legacy project `MEMORY.md` is imported into the graph in memory on first open and then left untouched — the graph file is created only by the first memory mutation or recall maintenance, so a cold search/read never writes — and `MEMORY.md` itself is no longer written. Memory is project-scoped only; there is no global memory store.

The Memory tool group maintains project memory without accumulating avoidable duplicates:

Treat this memory as a concise project journal, not a general preference or
activity log. Create or update an entry for a verified handoff, a material
architecture/compatibility decision, a durable blocker or caveat, or a
completed release/publication. A release entry records its version or
identifier, what was published, current caveats and useful next step, backed by
evidence such as a tag, artifact, successful validation, or deployment result;
a version or changelog edit alone does not prove publication. Do not journal
unimplemented plans, unverified claims, command-by-command activity, raw logs,
large diffs, temporary progress, or facts already obvious from current files.
A read-only agent can retrieve and verify journal context but cannot mutate it.

- `memory.read` reads recent entries; use `detail: "index"` for a compact summary/ID view and the default `detail: "full"` for complete content.
- `memory.search` runs BM25 keyword retrieval over the graph and follows links to related entries; with an embedding provider configured it fuses semantic hits in via reciprocal-rank fusion. It is strictly read-only: searching never rewrites the graph or its retrieval statistics — only automatic recall performs that maintenance.
- `memory.write` adds a new entry; writing content that already matches an active entry returns that entry instead of duplicating it, and the tool says so — the result reports `written`/`deduplicated` truthfully instead of claiming every call saved something.
- `memory.update` rewrites an entry in place: the id, creation date, and archive state are preserved, the original `Timestamp` is kept and `Updated` added when omitted.
- `memory.archive` deactivates a stale entry by id so it stops influencing retrieval without being deleted.

Before writing, search for an active entry about the same durable project fact. Update it when appropriate instead of appending a duplicate, and do not write when nothing materially changed. Embeddings are opt-in and off by default: without a provider, entries carry no vector and retrieval is pure BM25 keyword matching. The embedding configuration is an endpoint URL plus an optional model: configure it in `/setup` ("Memory embeddings": BM25 only / add / change / remove), where an OpenRouter choice is proposed immediately when OpenRouter is among the configured providers (canonical endpoint `https://openrouter.ai/api/v1/embeddings`, model `qwen/qwen3-embedding-8b`), or for compatibility export `ZENCODE_MEMORY_EMBEDDING_ENDPOINT` (endpoint only). Setup validates the URL locally and never connects to it. When a model is configured ZenCODE sends it in the request body; otherwise the endpoint identifies the embedding model itself and the request omits `model`, so an endpoint-only OpenAI-compatible `/v1/embeddings` server chooses. The OpenRouter preset reuses the configured provider's API key at runtime only when the referenced provider is a configured OpenRouter provider and the embedding endpoint is itself an OpenRouter endpoint — the key is never duplicated in the embedding settings, and manual endpoint edits reset to an endpoint-only configuration so an edited endpoint can never forward the key to another host; custom/legacy endpoint-only setups send no Authorization header. Entries record the model identity that embedded them, so changing the provider degrades retrieval to keyword matching instead of returning mismatched results. Mutations are serialized per workspace within one ZenCODE process, and each one commits only after the graph save succeeded: a failing save leaves the in-memory graph unchanged.

The vendored engine ships optional intelligence layers — a query analyzer (default `DirectMemoryQueryAnalyzer`, which uses the prompt as the query), a selector, an extractor (default `NoopMemoryExtractor`, which extracts nothing) and a context formatter — plus `context(for:)` (a ready-to-inject memory block) and `learn(from:)`; these remain unwired engine internals. Automatic recall is wired and on by default: before each turn ZenCODE retrieves relevant entries — BM25 plus graph expansion locally (or semantic similarity plus fusion when an endpoint is configured), never a second LLM call — and injects them as a labelled `<project-memory>` block into the outgoing copy of the last user message on every tool round, bounded by a deadline (`ZENCODE_MEMORY_RECALL_TIMEOUT_MS`, default 150 ms) so a slow, broken, or empty graph degrades to no memory instead of delaying the turn. The block itself does add input tokens to the request, so it is capped by a character budget (`ZENCODE_MEMORY_RECALL_MAX_CHARACTERS`, default 4 000 characters ≈ about 1k tokens, clamped to [200, 32 000]); recalled content is escaped so it cannot close the container, and the payload is truncated on line boundaries with a notice when it does not fit. The block is a transient per-turn channel merged into the outgoing copy of the last user message only — exactly once per round, because it is never written back into the session — and it never enters conversation history, saved-session snapshots, or the session cache key, so saved sessions and prompt caching are unaffected. Delegated sub-agent turns receive the same recall. The main model reads and writes durable memory explicitly through the five `memory.*` tools above. `ZENCODE_MEMORY_AUTO_RECALL` (default on) switches recall off.

`AGENTS.md` is optional and can be created or updated manually whenever a
project needs durable workspace guidance. If it exists in the working
directory, ZenCODE reads it and inserts it into the agent context. ZenCODE does
not create or rewrite this project file automatically. This project file is
distinct from the global `~/.zencode/AGENTS.md`, which supplies operating rules
across workspaces.

## ACP Mode

```bash
zen --acp --working-directory /path/to/project
```

stdout contains only ACP JSON-RPC messages. Clients provide prompts, sessions,
and tool exposure. `--agent`, `--model`, `--working-directory`, `--skills`, and
token environment variables still apply.

## Recommended Workflow

1. `cd /path/to/project && zen` — start in the target project; first-run setup opens automatically when required.
2. `/setup` — reconfigure providers, models, agents, or features later without leaving the TUI.
3. `/tools` and `/skills` — select tools and skills.
4. `/plan <goal>` or `/goal <goal>` — optional planning before editing. `/plan` delegates to a Planner sub-agent with an approval step; `/goal` plans directly and delegates all implementation to sub-agents.
5. Implement with the active profile.
6. `/changes diff` and Git — inspect changes.
7. `/review` — read-only review before commit.
8. `/sessions name` — save meaningful checkpoints.
9. Update project memory at handoff points (via `memory.write` / `memory.update`).

## Troubleshooting

- **Setup starts automatically**: required configuration (`settings.json` or `agents.json`) is missing or invalid, or no model is configured; complete setup before the chat starts. Use `/setup` later to reconfigure.
- **Model not found**: run `/models` or check `settings.json`.
- **A profile is never chosen for delegation**: check its role compatibility, its tool grant, and that it has a model binding with a capability — see [bindings.md](bindings.md).
- **No tools available**: use `/tools`, switch profile, or check ACP client tool exposure.
- **`/feature` unavailable**: switch to `/agents Builder`.
- **Optional feature tools are missing**: install the package with `zen --install-features <id>` (or choose it in setup), then enable/select it with `/tools`.
- **`/plan`, `/goal`, or `/review` needs sub-agents**: enable `sub-agents` with `/tools` or switch profile.
- **Xcode tools missing**: make sure Xcode is running. See [xcode.md](xcode.md).
- **Figma tools missing**: make sure the Figma desktop MCP server is enabled.
