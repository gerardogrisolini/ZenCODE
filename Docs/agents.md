# Agents and Sub-Agents

How agent profiles work and how the runtime delegates to sub-agents.

- Model bindings, capability routing, and the bindings table: [bindings.md](bindings.md).
- Per-profile guides: [builder.md](builder.md), [planner.md](planner.md), [reviewer.md](reviewer.md), [reporter.md](reporter.md).

## Agent Profiles

A profile is the persisted configuration that defines how a model session
behaves. Profiles live in `~/.zencode/agents.json` and are loaded at session
start by `AgentProfileStore`.

| Field | Purpose |
| --- | --- |
| `name` | Human- and model-visible label |
| `instructions` | System-prompt fragment defining the role and constraints |
| `tools` | Allowed tool groups and feature packages |
| `readOnly` | Enforces only non-mutating catalog-owned core tools (`false` by default) |
| `skills` | Optional prompt skills from the app catalog |
| `modelBindings` | Models explicitly authorized for the profile — see [bindings.md](bindings.md) |
| `defaultModelBindingID` | Profile default for direct/profile-selected sessions; delegation still names a binding explicitly |
| `symbolName` | SF Symbol shown in the TUI picker (presentational only) |

Select a profile with `/agents <name>` or `--agent <name>` at launch. Switching
resets the conversation so the new system prompt and tools apply cleanly.

Profile IDs and names share one case- and diacritic-insensitive POSIX identity
namespace. Duplicate names, duplicate IDs, and an ID that collides with another
profile's name make `agents.json` invalid; the store and delegation runtime fail
closed instead of selecting the first matching tool grant.

> **Associate at least one model binding with every profile that should receive
> delegated work.** A profile without bindings stays selectable and can still be
> delegated explicitly through the legacy fallback, but it is excluded from
> capability-based delegation routing.

> **Workspace guidance:** run [`/agents-md`](zen.md#memory-and-project-context)
> when first opening a new or updated project. It inspects the workspace and
> conservatively creates or refreshes its project-level `AGENTS.md`. Startup
> never does this automatically; review and commit the result.

## Recommended Profiles

| Profile | Role | Toolset |
| --- | --- | --- |
| `Developer` | General development and coordination | coding + web + sub-agents |
| `Builder` | Swift feature packages | coding + web |
| `Minimal` | Essential tools, brief replies | shell, files, text |
| `Reviewer` | Read-only code review | coding without shell; `readOnly` enforced |
| `Reporter` | Code analysis and evidence-based reports | files, search, text, git |
| `Planner` | Read-only planning | files, search, text, git, memory, web; `readOnly` enforced |

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

1. The coordinator calls `agent.create` with the canonical `agents` array. Every
   model-visible item names an exact `profile` and the exact `binding:<id>` value
   shown in the delegation roster as `model`.
2. The runtime resolves the profile and binding against one authoritative
   snapshot of the configured model catalog. Missing, stale, ambiguous, or
   capability-less bindings, and providers missing required authentication, are
   rejected before any reservation or task claim.
3. The resolved provider, model, API-key lookup, and generation settings travel
   with the child backend context. Backend creation does not repeat a global
   model lookup or route by a bare provider model slug.
4. The sub-agent inherits the workspace and receives the tools configured on
   that profile. `agent.create` cannot replace or narrow them.
5. While the child is active, the coordinator uses `agent.message`,
   `agent.wait`, `agent.get`, and `agent.close`.

The model-visible tool schema intentionally exposes only the canonical batch
shape. Historical root fields and aliases (`agent`, `modelID`, `items`, and
others) remain accepted by the compatibility parser for existing integrations,
but are not advertised to the model and conflicting aliases are rejected.

For a task-bound implementation agent, completion ends that attempt and normally
moves the task to `awaiting_validation`. If validation is negative, record the
failure with `tasks.update`, call `tasks.retry`, then claim the reset task with a
**new** `agent.create(taskID:)`. `agent.message` cannot revive a completed
attempt.

### Tool Authority

Write authority comes from the selected profile's configured tools:

- `profile` is required in every model-visible batch item and must resolve to a
  configured profile; otherwise `agent.create` fails. The `agent` name is a
  compatibility-only input alias.
- The request cannot assign, add, remove, or override the profile's tools.
- When `readOnly` is `true`, the runtime removes mutable descriptors from the
  catalog-owned core grant after resolving profile tools, `/tools`, app/ACP
  inputs, and child intrinsics. Optional feature packages, MCP tools, and other
  external grants are not classified or changed by this setting.
- **A child bound to a task** additionally receives the intrinsic `tasks.list`,
  `tasks.get`, and `tasks.update` tools needed to report its attempt. A
  read-only child retains all three because `tasks.update` is classified as a
  reporting/control-plane operation; `tasks.create`, `tasks.retry`, and
  `tasks.cancel` remain restricted.
- Every child receives the intrinsic `skills.list` and `skills.read` tools.

`/plan`, `/review`, and `/workflow` all delegate with the selected profile's own
tools. Configure each profile with exactly the access required for its role.

### Model Selection

Which model a sub-agent runs on is decided by the profile's currently routable
authorized bindings and the task complexity. The prompt lists one exact
`binding:<id>` reference for each eligible binding; `agent.create` requires that
explicit reference and carries the resulting provider selection through backend
creation. A profile with no bindings can still inherit the parent model through
the legacy programmatic input path, but it is not model-visible or eligible for
capability routing. The resolution table, the capability scale, and the ordered
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
- **Read-only agent?** — persistently restricts catalog-owned core tools to
  their non-mutating descriptors, even if a later session tool selection asks
  for a mutable core group. Existing manifests default this field to `false`.
- **Skills** — optional reusable prompt fragments from the catalog.
- **Instructions** — the role definition, edited in a real text editor.
- **Symbol** — SF Symbol for the TUI picker (presentational).

## Configuring Profiles

```text
/setup                # create or edit profiles interactively
/agents               # select a profile in the TUI
/models                # choose any configured model for the current session
/tools                 # expose or hide tool groups per session
```

`/models` is intentionally independent from `/agents`: changing profile changes
role, instructions, tools, and the default binding, but never filters the
available model catalog.
