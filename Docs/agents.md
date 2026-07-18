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
| `modelBindings` | Optional per-profile model defaults and explicit sub-agent routing choices |
| `defaultModelBindingID` | Binding used when the main session has no manual model selection, or when a sub-agent caller does not choose a binding explicitly |
| `symbolName` | SF Symbol shown in the TUI picker (presentational only) |

Select a profile with `/agents <name>` or `--agent <name>` at launch. Switching resets the conversation so the new system prompt and tools apply cleanly.

## Recommended Profiles

| Profile | Role | Toolset |
| --- | --- | --- |
| `Developer` | General development and coordination | coding + web + sub-agents |
| `Builder` | Swift feature packages | coding + web |
| `Minimal` | Essential tools, brief replies | shell, files, text |
| `Xcode` | Xcode-native via ACP | shell, memory, web |
| `Reviewer` | Read-only code review | coding without shell |
| `Reporter` | Code analysis and evidence-based reports | files, search, text, git |
| `Planner` | Read-only planning | files, search, text, git, memory, web |

Profiles are examples — you can edit, add, or remove them in setup. A `Developer` profile must always exist because runtime fallback paths select it.

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
4. The coordinator uses `agent.message`, `agent.wait`, `agent.get`, and `agent.close`.

An explicit model without a resolved profile, or a model not associated with that profile, is rejected before the task is claimed. A profile without bindings retains the legacy behavior and inherits the parent session model. Write authority is determined by the sub-agent's effective tool allowlist. By default it inherits the parent session's enabled tools; passing `toolNames` narrows that grant. `/plan` and `/review` explicitly pass read-only allowlists, while delegated coding work receives editing tools only when the parent grant permits them. `/workflow` delegates implementation tasks with the sub-agent's default inherited grant, so the parent profile must include the necessary editing tools.

## Capability Routing

The runtime builds a delegation roster containing only profiles with at least one binding that has a model and a capability. Each profile entry includes the first non-empty line of its instructions and lists only its authorized bindings. A binding carries its own `modelID`, optional thinking selection, and `capability` (1–10):

```
Delegatable agent profiles and authorized model bindings (filter by role and constraints first):
- Developer: Developer agent. Implement the user's request with the available tools, keep changes focused, and validate important work before reporting completion.
  - gpt-mini [binding: quick] (capability 4/10)
  - gpt-strong [binding: deep] (capability 8/10, default)
```

The model applies this policy in order:

1. Determine the task type and required tools.
2. Exclude profiles whose stated role or constraints are incompatible. For example, never assign implementation or editing to a read-only planning or review profile.
3. Do not delegate when the effective child tool grant cannot perform the work. A child inherits the parent grant, and `toolNames` can only narrow it.
4. For a compatible profile, choose the lowest-capability **authorized binding** that meets the task complexity.
5. If none of that profile's bindings meets the complexity, choose its highest-capability binding and explicitly report the capability gap.

The coordinator must never select a profile or binding by capability alone. Capability represents the effective routing strength of that particular profile–model configuration, not role, seniority, or tool authority. The runtime advises when complexity exceeds the selected binding's capability; it does not replace the coordinator's explicit profile and binding choice.

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph (`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies, selects runnable work with `tasks.list`, and assigns delegated tasks by passing `taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at creation time; taskless agents are for single self-contained lookups.

`/workflow <goal>` automates this pattern: the current agent inspects the workspace, creates the task graph with `tasks.create`, delegates every task to the best-matching sub-agent via `agent.create(taskID:)`, and reviews results. Unlike `/plan`, there is no separate Planner sub-agent or approval step — the current agent is the sole planner, coordinator, and final reviewer. See the [zen.md](zen.md) task orchestration section for details.

## Setup Parameters

When configuring a profile, setup asks for each parameter for a specific reason:

- **Model bindings** — one or more models explicitly permitted for the profile. Without a binding, the profile stays selectable with `/agents` but is excluded from dedicated-model delegation routing.
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
