# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime in this repository. It runs as a standalone terminal agent, as an ACP stdio agent, with cloud providers or your ChatGPT/Claude subscription, or fully on-device through `zen --mlx`.

## Modes

```bash
zen          # standalone chat TUI
zen --acp    # ACP over stdio for compatible clients
zen --mlx    # direct local MLX runtime (no HTTP)
zen --ds4    # direct local DS4 runtime
```

Standalone `zen` uses providers/models from `~/.zencode/settings.json`. `zen --mlx` uses the local `~/.zencode/mlx/models.json` catalog and the MLX runtime directly. `zen --ds4` uses a local DS4 runtime loaded in-process.

## First Setup

```bash
zen --setup
```

Creates files under `~/.zencode/`:

- `settings.json` — provider/model configuration, selected model, optional Telegram and voice settings.
- `permissions.json` — persistent runtime approvals.
- `agents.json` — agent profiles, model overrides, tools, instructions.
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
- `--model MODEL_ID`: override the agent-selected model.
- `--cwd PATH`: working directory for local tools.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt.
- `--max-output-tokens N`: maximum generated tokens per model call.
- `--verbose`: show status/tool progress on stderr.

Environment variables mirror these: `ZENCODE_AGENT_MODE`, `ZENCODE_AGENT_NAME`, `ZENCODE_AGENT_MODEL`, `ZENCODE_AGENT_CWD`, `ZENCODE_AGENT_SKILLS`, `ZENCODE_AGENT_VERBOSE`, `ZENCODE_AGENT_BEARER_TOKEN`.

## Agent Profiles

Agent profiles live in `~/.zencode/agents.json` and are managed in setup. The recommended profiles are `Developer`, `Builder`, `Minimal`, `Xcode`, `Planner`, `Reviewer`, and `Reporter`. Each defines tools, skills, model, and instructions.

Switch profiles in the TUI without restarting:

```text
/agents                 # picker
/agents Builder         # by name
/agents 2               # by number
```

Switching resets the conversation so the new system prompt and tools apply cleanly. See [agents.md](agents.md) for profile concepts and capability routing.

## Terminal TUI Commands

Commands start with `/`:

**Setup and navigation:**
- `/help` — show command help.
- `/models` — show configured models, switch session model.
- `/agents [list|<name>|<number>]` — switch agent profile.
- `/tools [all|none|tool-name|package-name|number]` — select exposed tool groups.
- `/skills` — select or install prompt skills.
- `/exit` — close the session.

**Sessions and memory:**
- `/sessions [name]` — list/load sessions, or save a named snapshot.
- `/sessions save` — refresh the active saved session.
- `/sessions compact` — force context compaction without saving.
- `/sessions new` — reset to a fresh, unsaved session.
- `/sessions delete` — delete a saved snapshot.

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
- `/workflow <goal>` — plan and delegate all work to sub-agents. The current agent creates the task graph, delegates every task to the best-matching sub-agent, and stays as coordinator and final reviewer. No separate Planner sub-agent or approval step. Use `/tasks` to monitor progress.
- `/review [focus]` — delegate review to read-only `Reviewer` sub-agents. See [reviewer.md](reviewer.md).
- `/make-agents` — ask the model to create or update `AGENTS.md` for the current directory. Requires the `Files` tool group.
- `/feature` — manage Swift feature packages (Builder profile only). See [builder.md](builder.md).

**`/plan` vs `/workflow`:**

| | `/plan` | `/workflow` |
|---|---|---|
| **Planning** | Delegated to a read-only Planner sub-agent | Done by the current agent directly |
| **Approval step** | Yes — `/plan approve` activates the graph | No — starts immediately |
| **Task implementation** | The current agent works freely: directly or by delegating, as it sees fit | Every task is delegated to a sub-agent; the current agent never implements directly |
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

## Tool Selection

Tool groups include: filesystem, shell, text, search, Git, memory, sub-agents, Xcode (when running), Figma (when the desktop MCP server is available), generated Swift features, and bundled integrations. Use `/tools` to select per session. ACP clients pass enabled tools directly.

## Task Orchestration

`todo.*` is a lightweight checklist for model-local coordination. `tasks.*` operates on the authoritative session task graph owned by `SessionTaskOrchestrator` — a validated DAG with atomic creation, dependency gating, optimistic fencing, and attempt history.

When work has multiple units, dependencies, or concurrent delegation, the coordinator creates a task graph first, then selects runnable work with `tasks.list` and assigns delegated tasks through `agent.create(taskID:)`. Report-agent success completes a task; implementation-agent success moves it to `awaiting_validation` until independently validated.

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

Version 3 snapshots embed the current task graph and active plan; v2 remains loadable. MLX sessions save the runtime snapshot; remote sessions save the local transcript with replay metadata. Subscription sessions persist continuation metadata for efficient resume.

## Memory and Project Context

Durable context is separated by responsibility:

- Project `AGENTS.md` — workspace-specific constraints and workflows. Check into version control.
- Global `~/.zencode/AGENTS.md` — cross-workspace operating rules.
- Project `MEMORY.md` — codebase journal with `Timestamp`, `Summary`, `State`, `Next` entries.
- Global `~/.zencode/MEMORY.md` — lightweight resume index only.

ZenCODE reads `AGENTS.md` from the working directory when present. Startup never creates or rewrites it; use `/make-agents` in chat to ask the model to create or update it.

## ACP Mode

```bash
zen --acp --cwd /path/to/project
```

stdout contains only ACP JSON-RPC messages. Clients provide prompts, sessions, and tool exposure. `--agent`, `--model`, `--cwd`, `--skills`, and token environment variables still apply.

## Direct Local Runtimes

```bash
zen --mlx --cwd /path/to/project                    # local MLX
zen --ds4 --cwd /path/to/project                    # local DS4
zen --mlx --model qwen3-mlx --agent Developer       # explicit model and profile
```

See [mlx-runtime.md](mlx-runtime.md) and [ds4.md](ds4.md) for runtime-specific setup and configuration.

## Recommended Workflow

1. `zen --setup` — configure providers, models, agents.
2. `cd /path/to/project && zen` — start in the target project.
3. `/tools` and `/skills` — select tools and skills.
4. `/plan <goal>` or `/workflow <goal>` — optional planning before editing. `/plan` delegates to a Planner sub-agent with an approval step; `/workflow` plans directly and delegates all implementation to sub-agents.
5. Implement with the active profile.
6. `/changes diff` and Git — inspect changes.
7. `/review` — read-only review before commit.
8. `/sessions name` — save meaningful checkpoints.
9. Update project `MEMORY.md` at handoff points.

## Troubleshooting

- **Setup starts automatically**: required `~/.zencode` files are missing; complete `--setup`.
- **Model not found**: run `/models` or check `settings.json`; in MLX mode check `~/.zencode/mlx/models.json`.
- **No tools available**: use `/tools`, switch profile, or check ACP client tool exposure.
- **`/make-agents` needs Files**: enable `Files` with `/tools` or switch profile.
- **`/feature` unavailable**: switch to `/agents Builder`.
- **`/plan`, `/workflow`, or `/review` needs sub-agents**: enable `sub-agents` with `/tools` or switch profile.
- **Xcode tools missing**: make sure Xcode is running. See [xcode.md](xcode.md).
- **Figma tools missing**: make sure the Figma desktop MCP server is enabled.
