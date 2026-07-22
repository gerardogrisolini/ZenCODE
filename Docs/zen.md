# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime in this repository. It runs as a standalone terminal agent, as an ACP stdio agent, with cloud providers or your ChatGPT/Claude subscription.

## Modes

```bash
zen          # standalone chat TUI
zen --acp    # ACP over stdio for compatible clients
```

Standalone `zen` uses providers/models from `~/.zencode/settings.json`.

## First Setup

```bash
zen --setup
```

Creates files under `~/.zencode/`:

- `settings.json` — provider/model configuration, selected model, optional Telegram and voice settings.
- `permissions.json` — persistent runtime approvals.
- `agents.json` — agent profiles, authorized model bindings, tools, and instructions.
- `AGENTS.md` — global operating guidance.
- `MEMORY.md` — lightweight global resume index.
- `sessions/` — saved session snapshots grouped by project.
- `features/` — generated Swift feature packages.

## Command Line Options

```text
zen [--setup] [--acp] [--agent NAME] [--model MODEL_ID] [--cwd PATH] [--skills LIST]
```

- `--setup`: open setup, then exit.
- `--acp`: run ACP JSON-RPC over stdio.
- `--agent NAME`: select an agent profile (default: `Developer`).
- `--model MODEL_ID`: request a model override for the direct session; delegated sub-agents remain restricted to the selected profile's authorized bindings.
- `--cwd PATH`: working directory for local tools.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt.
- `--max-output-tokens N`: maximum generated tokens per model call.
- `--verbose`: show status/tool progress on stderr.

Environment variables mirror these: `ZENCODE_AGENT_MODE`, `ZENCODE_AGENT_NAME`, `ZENCODE_AGENT_MODEL`, `ZENCODE_AGENT_CWD`, `ZENCODE_AGENT_SKILLS`, `ZENCODE_AGENT_VERBOSE`, `ZENCODE_AGENT_BEARER_TOKEN`.

## Agent Profiles

Agent profiles live in `~/.zencode/agents.json` and are managed in setup. The recommended profiles are `Developer`, `Builder`, `Minimal`, `Xcode`, `Planner`, `Reviewer`, and `Reporter`. Each defines tools, skills, instructions, and model bindings. Associate at least one binding with every profile intended to receive delegated work: a binding authorizes its profile-and-model pair and supplies its capability and optional thinking selection for routing. A binding-free profile remains supported only through the legacy fallback: a child created without an explicit model inherits the parent session's model and the profile is absent from capability-based delegation routing. See [agents.md](agents.md) for the complete binding behavior.

Switch profiles in the TUI without restarting:

```text
/agents                 # picker
/agents Builder         # by name
/agents 2               # by number
```

Switching resets the conversation so the new system prompt and tools apply cleanly. If the selected profile has bindings, its default is used when no model has been selected explicitly. `/models` always presents every configured model, and a manual selection overrides that default for the active session. Use `/bindings` to inspect the configured bindings for every profile, including the selected profile, defaults, capability, and thinking settings. See [agents.md](agents.md) for profile concepts and capability routing.

## Terminal TUI Commands

Commands start with `/`:

**Setup and navigation:**
- `/help` — show command help.
- `/models` — show every configured model and choose the model for the current session.
- `/agents [list|<name>|<number>]` — switch agent profile.
- `/bindings` — show every agent profile's model bindings, including defaults, capability, and thinking settings. Does not accept arguments.
- `/tools [all|none|tool-name|package-name|number]` — select exposed tool groups.
- `/skills` — select or install prompt skills.
- `/exit` — close the session.

**Sessions and memory:**
- `/sessions` — list and select saved sessions.
- `/sessions <name>` — save or overwrite a named snapshot.
- `/sessions save` — save the current session (derives a name from the first prompt if none is active).
- `/sessions compact` — force context compaction without saving.
- `/sessions new` — reset to a fresh, unsaved session.
- `/sessions delete` — delete a saved snapshot.
- `/sessions tree` — show the session checkpoint tree with entry IDs and branches.
- `/sessions branches` — list all branches (leaves) in the checkpoint tree.
- `/sessions checkpoint [label]` — create a named checkpoint at the current position.
- `/sessions restore [entry-id|branch-index]` — restore in-place from a checkpoint, branching from that point; without an argument an interactive picker over the checkpoint entries opens.

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
- `/plan <goal>` — delegate planning to a read-only `Planner` sub-agent. See [planner.md](planner.md).
- `/plan status` — show plan progress from the graph state.
- `/plan approve` — activate the plan and start implementation.
- `/plan clear` — archive the graph and remove the active plan.
- `/workflow <goal>` — plan and delegate all work to sub-agents. It creates an active workflow graph up front; every graph task is enforced as a sub-agent execution attempt. It refuses to start while an active `/plan` exists; finish that plan or use `/plan clear` first. The current agent stays as coordinator and final reviewer, retaining its normal tool grant for that work. No separate Planner sub-agent or approval step. Use `/tasks` to monitor progress.
- `/review [focus]` — delegate review to read-only `Reviewer` sub-agents. See [reviewer.md](reviewer.md).
- `/make-agents` — ask the model to create or update `AGENTS.md` for the current directory. Always run it when first opening a new or updated project so its workspace guidance stays current. Requires the `Files` tool group.
- `/feature` — manage Swift feature packages (Builder profile only). See [builder.md](builder.md).

**`/plan` vs `/workflow`:**

| | `/plan` | `/workflow` |
|---|---|---|
| **Planning** | Delegated to a read-only Planner sub-agent | Done by the current agent directly |
| **Approval step** | Yes — `/plan approve` activates the graph | No — starts immediately |
| **Task implementation** | The current agent works freely: directly or by delegating, as it sees fit | Every graph task must be claimed by a sub-agent; coordinator task attempts are rejected while its normal tool grant remains unchanged |
| **Sub-agent selection** | The model decides per task if and when to delegate | The model must assign the best-matching profile to every task |
| **Role of current agent** | Implementer (can delegate when useful) | Coordinator and final reviewer only |
| **Monitor progress** | `/plan status` or `/tasks` | `/tasks` |

**Optional integrations:**
- `/telegram` / `/telegram on` / `/telegram off` — remote control (requires setup). Available even while a prompt is running.
- `/voice` — record a voice prompt (requires setup).

**Interactive shortcuts:**
- `Ctrl+T` — toggle compact/full tool output.
- `Ctrl+A` — toggle default/full access mode (temporary, never persisted).

Full access bypasses only `local.exec` approval checks. It does not expose disabled tools or bypass OS permissions. The status bar shows a red dot while active.

`local.exec` authorization filters shell noise so that only significant commands trigger an approval prompt. Comments, decorative `echo`/`printf` (without output redirections), harmless built-ins (`true`, `false`, `cd`, `pwd`, …), environment assignments, wrappers (`env`, `command`, …), and control-flow keywords are stripped or skipped. Nested commands inside shell `-c` payloads, `$(...)`/backtick command substitutions, process substitutions `<(...)`/`>(...)`, and unquoted heredoc bodies are recursively extracted and each surfaced for authorization, while `$((...))` arithmetic expansion and quoted heredoc bodies are treated as literal. Wrapper options that consume an operand (`env -u NAME`, `env -C DIR`, `time -o FILE`) are handled so the real executable surfaces, and introspection-only forms (`command -v`) are not authorized as executions. When parsing hits its recursion or candidate limits it fails closed by emitting a conservative fallback candidate. The original command is still executed in full after approval; only the displayed authorization request is cleaned.

## Tool Selection

Tool groups include: filesystem, shell, text, search, Git, memory, sub-agents, Xcode (when running), Figma (when the desktop MCP server is available), generated Swift features, and bundled integrations. Use `/tools` to select per session. ACP clients pass enabled tools directly.

## Task Orchestration

`todo.*` is a lightweight checklist for model-local coordination. `tasks.*` operates on the authoritative session task graph owned by `SessionTaskOrchestrator` — a validated DAG with atomic creation, dependency gating, optimistic fencing, and attempt history.

When work has multiple units, dependencies, or concurrent delegation, the coordinator creates a task graph first, then selects runnable work with `tasks.list` and assigns delegated tasks through `agent.create(taskID:)`. Report-agent success completes a task; implementation-agent success moves it to `awaiting_validation` until independently validated. Record a successful validation as completion. For negative validation, record `failed` with `tasks.update`, call `tasks.retry` to return the task to `pending`, then use a **new** `agent.create(taskID:)` to claim the new attempt. Do not use `agent.message` to reopen the already completed agent.

`/workflow` uses a distinct graph source. Its tasks must declare `execution.executor: sub_agent`, and the orchestrator rejects coordinator attempts or graph replacement while that workflow is active. This enforces delegation at the task lifecycle boundary rather than by applying a read-only tool policy to the coordinator. A coordinator without `agent.create` may work directly only in a graph that permits coordinator execution; it must never create or directly execute a workflow task.

Checkpoints are written atomically under `~/.zencode/task-graphs/<project>/` and restored by session ID. Active attempts found during restore become `blocked` rather than silently resumed.

## Skills

```text
/skills                          # select or install skills
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

Every saved session stores its conversation as a **tree of entries** alongside the flat message history. The initial history is a linear tree: every message is an entry, even if you never create a manual checkpoint. A manual checkpoint is only a labelled marker that makes an important position easier to find. Entries are linked to their parent via an entry ID, so you can branch from any point and explore alternatives without losing the original path.

```text
/sessions tree                   # show the checkpoint tree (with entry IDs)
/sessions branches               # list all branches (leaves)
/sessions checkpoint stable      # create a labelled checkpoint
/sessions save                   # persist the checkpoint tree to disk
/sessions restore                # restore via interactive entry picker
/sessions restore a1b2c3d4       # restore in-place by entry ID (branches)
/sessions restore 2              # restore by branch index
```

The tree is visualised as a flat outline: single-child chains stay at the same indentation level, branch connectors (`├─`/`└─`) appear only where the tree actually forks, and `← active` marks the current position.

**In-place branching** with `/sessions restore` navigates the active session to an earlier entry. It does not require a manually labelled checkpoint: `/sessions restore` without an argument opens an interactive picker containing all entries in the saved session, including ordinary message entries. Messages you send after restoring form a new branch in the tree. The original path is preserved and remains visible in `/sessions tree`; selecting the current active entry simply leaves the conversation at its current position.

Restore changes the active runtime session, but it does **not** immediately overwrite the saved session on disk. After inspecting or continuing from the restored point, run `/sessions save` to persist the new active position and branch. Until then, the previously saved snapshot remains unchanged. Restore reloads the saved snapshot associated with the active session, so save first if the current conversation contains messages or other state that must not be discarded:

```text
/sessions save                   # preserve the current state first
/sessions restore                # choose a previous entry and branch
```

To split a conversation into a separate file, restore to the desired point and then `/sessions <new-name>`: the new snapshot keeps the full checkpoint tree while the original session file stays unchanged.

> Checkpoints created with `/sessions checkpoint` are in-memory until you run `/sessions save`. Run `/sessions save` before `/sessions restore` if you want a newly created manual checkpoint to be available after reloading the saved session.

### Session Format

Version 4 snapshots embed the checkpoint tree alongside the task graph and active plan. Sessions saved before v4 are not loadable. Remote sessions save the local transcript with replay metadata. Subscription sessions persist continuation metadata for efficient resume.

## Memory and Project Context

Durable context is separated by responsibility:

- Project `AGENTS.md` — workspace-specific constraints and workflows. Check into version control.
- Global `~/.zencode/AGENTS.md` — cross-workspace operating rules.
- Project `MEMORY.md` — codebase journal with `Timestamp`, `Summary`, `State`, `Next` entries.
- Global `~/.zencode/MEMORY.md` — lightweight resume index only.

ZenCODE reads `AGENTS.md` from the working directory when present. Startup never creates or rewrites it.

> **Keep project guidance current:** Always run `/make-agents` when first
> opening a new project or a project that has been updated. The command
> inspects the current workspace and conservatively creates or refreshes its
> `AGENTS.md`; review the result and commit it with the project. This explicit
> step is required because startup intentionally does not modify project files.

## ACP Mode

```bash
zen --acp --cwd /path/to/project
```

stdout contains only ACP JSON-RPC messages. Clients provide prompts, sessions, and tool exposure. `--agent`, `--model`, `--cwd`, `--skills`, and token environment variables still apply.

## Recommended Workflow

1. `zen --setup` — configure providers, models, agents.
2. `cd /path/to/project && zen` — start in the target project.
3. `/make-agents` — always create or refresh project-level guidance when first opening a new or updated project; review the resulting `AGENTS.md`.
4. `/tools` and `/skills` — select tools and skills.
5. `/plan <goal>` or `/workflow <goal>` — optional planning before editing. `/plan` delegates to a Planner sub-agent with an approval step; `/workflow` plans directly and delegates all implementation to sub-agents.
6. Implement with the active profile.
7. `/changes diff` and Git — inspect changes.
8. `/review` — read-only review before commit.
9. `/sessions name` — save meaningful checkpoints.
10. Update project `MEMORY.md` at handoff points.

## Troubleshooting

- **Setup starts automatically**: required `~/.zencode` files are missing; complete `--setup`.
- **Model not found**: run `/models` or check `settings.json`.
- **No tools available**: use `/tools`, switch profile, or check ACP client tool exposure.
- **`/make-agents` needs Files**: enable `Files` with `/tools` or switch profile.
- **`/feature` unavailable**: switch to `/agents Builder`.
- **`/plan`, `/workflow`, or `/review` needs sub-agents**: enable `sub-agents` with `/tools` or switch profile.
- **Xcode tools missing**: make sure Xcode is running. See [xcode.md](xcode.md).
- **Figma tools missing**: make sure the Figma desktop MCP server is enabled.
