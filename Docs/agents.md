# Agents and Sub-Agents

How agent profiles work, how the runtime delegates to sub-agents, and what each setup parameter controls. Per-profile guides: [builder.md](builder.md), [planner.md](planner.md), [reviewer.md](reviewer.md), [reporter.md](reporter.md), [xcode.md](xcode.md).

## Agent Profiles

A profile is the persisted configuration that defines how a model session behaves. Profiles live in `~/.zencode/agents.json`, loaded at session start by `AgentProfileStore`.

Each profile carries:

| Field | Purpose |
| --- | --- |
| `name` | Human- and model-visible label |
| `instructions` | System-prompt fragment defining the role and constraints |
| `tools` | Allowed tool groups and feature packages |
| `skills` | Optional prompt skills from the app catalog |
| `modelBindings` | Per-profile model authorizations used for defaults and explicit sub-agent routing; configure at least one for every profile intended for delegated work |
| `defaultModelBindingID` | Binding used when the main session has no manual model selection, or when a sub-agent caller does not choose a binding explicitly |
| `symbolName` | SF Symbol shown in the TUI picker (presentational only) |

Select a profile with `/agents <name>` or `--agent <name>` at launch. Switching resets the conversation so the new system prompt and tools apply cleanly.

> **Important:** Associate at least one model binding with every profile that
> should receive delegated work. A binding authorizes a specific
> profile-and-model pair and carries the capability and optional thinking
> configuration used for routing. Bindings are optional only for legacy
> compatibility: a profile without one remains selectable as the active
> profile, but is not a candidate in the capability-based delegation roster.

> **Workspace guidance:** Always run [`/make-agents`](zen.md#memory-and-project-context)
> when first opening a new project or a project that has been updated. It
> inspects the workspace and conservatively creates or refreshes its
> project-level `AGENTS.md`, which supplies durable constraints and workflows
> to later agent sessions. Startup intentionally never performs this update
> automatically; review and commit the resulting project guidance.

## Recommended Profiles

| Profile | Role | Toolset |
| --- | --- | --- |
| `Developer` | General development and coordination | coding + web + sub-agents |
| `Builder` | Swift feature packages | coding + web |
| `Minimal` | Essential tools, brief replies | shell, files, text |
| `Reviewer` | Read-only code review | coding without shell |
| `Reporter` | Code analysis and evidence-based reports | files, search, text, git |
| `Planner` | Read-only planning | files, search, text, git, memory, web |

Profiles are examples — you can edit, add, or remove optional profiles in setup. `Developer` and `Builder` must always remain present: runtime fallback paths select `Developer`, while `Builder` owns the `/feature` workflow and its intrinsic feature-management tools.

## Tool Groups

**Core:** `shell`, `files`, `text`, `memory`, `sub-agents`.

**Feature packages** (discovered and enabled separately): `search-tools`, `web-tools`, `git-tools`, `swift-tools`, `xcode-tools`, `figma-tools`, `jira-tools`.

Enabling a package makes it available; `/tools` exposes it in the current session. The `sub-agents` group is what lets a profile create delegated sub-agents.

## Sub-Agents

A sub-agent is a delegated, independently running model session spawned by the coordinator. The coordinator stays in its own profile and directs work. A profile may authorize one model only, preserving the previous fixed-model behavior, or several model bindings for controlled routing.

Lifecycle:

1. The coordinator calls `agent.create`, passing a `profile` and, when the profile has more than one binding, a `model` or `modelID`.
2. The runtime resolves the profile and then resolves the requested binding only within that profile's authorized bindings.
3. The sub-agent inherits the workspace and its profile's tool allowlist.
4. While the child is still active, the coordinator uses `agent.message`, `agent.wait`, `agent.get`, and `agent.close`.

For a task-bound implementation agent, completion ends that attempt and normally
moves the task to `awaiting_validation`. If validation is negative, record the
failure with `tasks.update`, call `tasks.retry`, then claim the reset task with a
**new** `agent.create(taskID:)`. Do not use `agent.message` to correct a
completed workflow task: it cannot revive the prior attempt or make it runnable
again.

### Binding Behavior

| Profile configuration and request | Result |
| --- | --- |
| One or more bindings; no `model` / `modelID` | The profile's default binding selects the child model. |
| One or more bindings; matching `model` / `modelID` | The runtime uses the explicitly selected, authorized binding. |
| No bindings; no explicit model | The child is created through the legacy fallback and inherits the parent session's model. The profile is not available to capability-based delegation routing. |
| No bindings; explicit `model` / `modelID` | Rejected: the profile has no authorized binding for an explicit model. |

The fallback preserves existing manual configurations; it is not equivalent to
a binding. Associate bindings when a coordinator must deliberately:

- choose a profile/model pair,
- compare capability to task complexity, or
- apply binding-specific thinking settings.

An explicit model without a resolved profile, or a model not associated with
that profile, is also rejected before the task is claimed.

Write authority is determined by the sub-agent's **effective tool allowlist**, resolved as follows:

- **When a profile resolves,** its configured tools are the child grant, and `toolNames` can only narrow that grant.
- **When no profile resolves,** the child inherits the parent session's enabled tools, again narrowed by `toolNames`.
- **A child bound to a task** additionally receives the intrinsic `tasks.list`, `tasks.get`, and `tasks.update` tools needed to report its execution attempt.

Command-specific behavior builds on these rules:

- `/plan` and `/review` explicitly narrow their selected profile to read-only tools.
- `/workflow` delegates implementation work with the selected sub-agent profile's tools, so that profile must include the necessary editing tools.

## Capability Routing

The runtime builds a delegation roster containing only profiles with at least one binding that has a model and a capability. A binding without a capability does not make its profile eligible for this routing. Each profile entry includes the first non-empty line of its instructions and lists only its authorized bindings. A binding carries its own `modelID`, optional thinking selection, and `capability` (1–10):

```
Delegatable agent profiles and authorized model bindings (filter by role and constraints first):
- Developer: Developer agent. Implement the user's request with the available tools, keep changes focused, and validate important work before reporting completion.
  - gpt-mini [binding: quick] (capability 4/10)
  - gpt-strong [binding: deep] (capability 8/10, default)
```

The model applies this policy in order:

1. Determine the task type and required tools.
2. Exclude profiles whose stated role or constraints are incompatible. For example, never assign implementation or editing to a read-only planning or review profile.
3. Do not delegate when the effective child tool grant cannot perform the work. A resolved profile supplies that grant and `toolNames` can only narrow it; only when no profile resolves does the child inherit the parent grant.
4. For a compatible profile, choose the lowest-capability **authorized binding** that meets the task complexity.
5. If none of that profile's bindings meets the complexity, choose its highest-capability binding and explicitly report the capability gap.

The coordinator must never select a profile or binding by capability alone. Capability represents the effective routing strength of that particular profile–model configuration, not role, seniority, or tool authority. The runtime advises when complexity exceeds the selected binding's capability; it does not replace the coordinator's explicit profile and binding choice.

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph (`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies, selects runnable work with `tasks.list`, and assigns delegated tasks by passing `taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at creation time; taskless agents are for single self-contained lookups.

`/workflow <goal>` automates this pattern:

1. It creates an active workflow graph.
2. The current agent adds its task definitions with `tasks.create`.
3. It delegates every task to the best-matching sub-agent via `agent.create(taskID:)`.
4. It reviews the results.

Workflow tasks must use `execution.executor: sub_agent`; the orchestrator rejects coordinator task attempts without narrowing the coordinator's normal tool grant. After negative validation, the coordinator records failure, retries the task, and creates a new task-bound agent rather than messaging the completed agent. Unlike `/plan`, there is no separate Planner sub-agent or approval step — the current agent is the sole planner, coordinator, and final reviewer. See the [zen.md](zen.md) task orchestration section for details.

## Setup Parameters

When configuring a profile, setup asks for each parameter for a specific reason:

- **Model bindings** — one or more models explicitly permitted for the profile. Configure them for every delegatable profile: without a binding, the profile stays selectable with `/agents` but uses only the legacy parent-model fallback and is excluded from capability-based delegation routing.
- **Default binding** — the model used for that profile when a caller does not select one explicitly.
- **Capability (1–10)** — configured per binding for delegation routing. Leave unset only when that binding should not be offered to the coordinator.
- **Thinking** — configured per binding and validated against the selected model's supported options.
- **Tools** — restricts what the profile can call. Safety mechanism: `Reviewer` drops `shell`, `Minimal` keeps only essentials.
- **Skills** — optional reusable prompt fragments from the catalog.
- **Instructions** — the role definition, edited in a real text editor.
- **Symbol** — SF Symbol for the TUI picker (presentational).

## Configuring Profiles

```bash
zen setup              # create or edit profiles interactively
/agents                # select a profile in the TUI
/models                # choose any configured model for the current session
/tools                 # expose or hide tool groups per session
```

`/models` is intentionally independent from `/agents`: changing profile changes
role, instructions, tools, and the fallback binding, but never filters the
available model catalog. A manual model selection takes precedence over the
profile default for the active session. The binding authorization rule applies only when a coordinator
creates a sub-agent with an explicit profile and model reference.
