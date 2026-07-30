# Agents and Sub-Agents

How agent profiles work and how the runtime delegates to sub-agents.

- Model bindings, capability routing, and the `/bindings` table: [bindings.md](bindings.md).
- Per-profile guides: [builder.md](builder.md), [planner.md](planner.md), [reviewer.md](reviewer.md), [reporter.md](reporter.md), [xcode.md](xcode.md).

## Agent Profiles

A profile is the persisted configuration that defines how a model session
behaves. Profiles live in `~/.zencode/agents.json` and are loaded at session
start by `AgentProfileStore`.

| Field | Purpose |
| --- | --- |
| `name` | Human- and model-visible label |
| `instructions` | System-prompt fragment defining the role and constraints |
| `tools` | Allowed tool groups and feature packages |
| `skills` | Optional prompt skills from the app catalog |
| `modelBindings` | Models explicitly authorized for the profile — see [bindings.md](bindings.md) |
| `defaultModelBindingID` | Binding used when no model is selected explicitly |
| `symbolName` | SF Symbol shown in the TUI picker (presentational only) |

Select a profile with `/agents <name>` or `--agent <name>` at launch. Switching
resets the conversation so the new system prompt and tools apply cleanly.

> **Associate at least one model binding with every profile that should receive
> delegated work.** A profile without bindings stays selectable and can still be
> delegated explicitly through the legacy fallback, but it is excluded from
> capability-based delegation routing.

> **Workspace guidance:** run [`/make-agents`](zen.md#memory-and-project-context)
> when first opening a new or updated project. It inspects the workspace and
> conservatively creates or refreshes its project-level `AGENTS.md`. Startup
> never does this automatically; review and commit the result.

## Recommended Profiles

| Profile | Role | Toolset |
| --- | --- | --- |
| `Developer` | General development and coordination | coding + web + sub-agents |
| `Builder` | Swift feature packages | coding + web |
| `Minimal` | Essential tools, brief replies | shell, files, text |
| `Reviewer` | Read-only code review | coding without shell |
| `Reporter` | Code analysis and evidence-based reports | files, search, text, git |
| `Planner` | Read-only planning | files, search, text, git, memory, web |

Profiles are examples — edit, add, or remove optional profiles in setup.
`Developer` and `Builder` must always remain present: runtime fallback paths
select `Developer`, while `Builder` owns the `/feature` workflow and its
intrinsic feature-management tools.

## Tool Groups

**Core:** `shell`, `files`, `text`, `memory`, `sub-agents`.

**Feature packages** (discovered and enabled separately): `search-tools`,
`web-tools`, `git-tools`, `swift-tools`, `xcode-tools`, `figma-tools`,
`jira-tools`, `desktop-tools`.

Enabling a package makes it available; `/tools` exposes it in the current
session. The `sub-agents` group is what lets a profile create delegated
sub-agents.

## Sub-Agents

A sub-agent is a delegated, independently running model session spawned by the
coordinator. The coordinator stays in its own profile and directs the work.

Lifecycle:

1. The coordinator calls `agent.create` with a `profile` and, when the profile
   has more than one binding, a `model` or `modelID`.
2. The runtime resolves the profile, then resolves the binding only within that
   profile's authorized bindings.
3. The sub-agent inherits the workspace and its profile's tool allowlist.
4. While the child is active, the coordinator uses `agent.message`,
   `agent.wait`, `agent.get`, and `agent.close`.

For a task-bound implementation agent, completion ends that attempt and normally
moves the task to `awaiting_validation`. If validation is negative, record the
failure with `tasks.update`, call `tasks.retry`, then claim the reset task with a
**new** `agent.create(taskID:)`. `agent.message` cannot revive a completed
attempt.

### Tool Authority

Write authority comes from the sub-agent's **effective tool allowlist**:

- **When a profile resolves,** its configured tools are the child grant, and
  `toolNames` can only narrow that grant.
- **When no profile resolves,** the child inherits the parent session's enabled
  tools, again narrowed by `toolNames`.
- **A child bound to a task** additionally receives the intrinsic `tasks.list`,
  `tasks.get`, and `tasks.update` tools needed to report its attempt.

Command-specific behavior builds on these rules:

- `/plan` and `/review` narrow their selected profile to read-only tools.
- `/workflow` delegates implementation with the selected profile's own tools, so
  that profile must include the necessary editing tools.

### Model Selection

Which model a sub-agent runs on is decided by the profile's authorized bindings
and the task complexity. A profile with no bindings falls back to the parent
session's model. The resolution table, the capability scale, and the ordered
selection policy are documented in [bindings.md](bindings.md).

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph
(`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies,
selects runnable work with `tasks.list`, and assigns delegated tasks by passing
`taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at
creation time; taskless agents are for single self-contained lookups.

`/workflow <goal>` automates this pattern:

1. It creates an active workflow graph.
2. The current agent adds its task definitions with `tasks.create`, including a
   `complexity` per task.
3. It delegates every task to the best-matching profile and binding via
   `agent.create(taskID:)`.
4. It validates and reviews the results.

Workflow tasks must use `execution.executor: sub_agent`; the orchestrator
rejects coordinator task attempts without narrowing the coordinator's normal tool
grant. Unlike `/plan`, there is no separate Planner sub-agent and no approval
step — the current agent is the sole planner, coordinator, and final reviewer.
See the [zen.md](zen.md#task-orchestration) task orchestration section.

## Setup Parameters

- **Model bindings** — models explicitly permitted for the profile, with their
  capability and thinking settings. See [bindings.md](bindings.md).
- **Tools** — restricts what the profile can call. Safety mechanism: `Reviewer`
  drops `shell`, `Minimal` keeps only essentials.
- **Skills** — optional reusable prompt fragments from the catalog.
- **Instructions** — the role definition, edited in a real text editor.
- **Symbol** — SF Symbol for the TUI picker (presentational).

## Configuring Profiles

```bash
zen --setup            # create or edit profiles interactively
/agents                # select a profile in the TUI
/models                # choose any configured model for the current session
/bindings              # inspect model bindings for every configured profile
/tools                 # expose or hide tool groups per session
```

`/models` is intentionally independent from `/agents`: changing profile changes
role, instructions, tools, and the default binding, but never filters the
available model catalog.
