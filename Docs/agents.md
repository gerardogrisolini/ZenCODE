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
| `modelID` / `modelProvider` | Dedicated model bound to the profile |
| `thinkingSelection` | Extended-reasoning budget (for models that support it) |
| `capability` | 1–10 ranking for delegation routing |
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

A sub-agent is a delegated, independently running model session spawned by the coordinator. The coordinator stays in its own profile and directs work.

Lifecycle:

1. The coordinator calls `agent.create`, optionally passing a `profile`.
2. The runtime resolves the profile (or falls back to a built-in default) and spawns the sub-agent.
3. The sub-agent inherits the workspace and its profile's tool allowlist.
4. The coordinator uses `agent.message`, `agent.wait`, `agent.get`, and `agent.close`.

Write authority is determined by the sub-agent's effective tool allowlist. By default it inherits the parent session's enabled tools; passing `toolNames` narrows that grant. `/plan` and `/review` explicitly pass read-only allowlists, while delegated coding work receives editing tools only when the parent grant permits them. `/workflow` delegates implementation tasks with the sub-agent's default inherited grant, so the parent profile must include the necessary editing tools.

## Capability Routing

The runtime builds a delegation roster containing only profiles that have **both** `modelID` and `capability`. Each roster entry includes the first non-empty line of the profile instructions so the model can see its role and constraints. Profiles are ordered by capability, but capability is not the first selection criterion:

```
Delegatable agent profiles (ordered by capability; filter by role and constraints first):
- Minimal (capability 3/10): Minimal agent. Use essential tools only, answer briefly, and avoid extra workflow unless asked.
- Developer (capability 7/10): Developer agent. Implement the user's request with the available tools, keep changes focused, and validate important work before reporting completion.
```

The model applies this policy in order:

1. Determine the task type and required tools.
2. Exclude profiles whose stated role or constraints are incompatible. For example, never assign implementation or editing to a read-only planning or review profile.
3. Do not delegate when the effective child tool grant cannot perform the work. A child inherits the parent grant, and `toolNames` can only narrow it.
4. Among compatible profiles, choose the one with the lowest capability greater than or equal to task complexity.
5. If none meets the complexity, choose the highest-capability compatible profile and explicitly report the capability gap.

The model must never select a profile by capability alone. Capability represents model strength rather than role, seniority, or tool authority. The runtime currently advises when complexity exceeds the selected profile's capability; it does not replace the model's explicit profile choice.

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph (`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies, selects runnable work with `tasks.list`, and assigns delegated tasks by passing `taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at creation time; taskless agents are for single self-contained lookups.

`/workflow <goal>` automates this pattern: the current agent inspects the workspace, creates the task graph with `tasks.create`, delegates every task to the best-matching sub-agent via `agent.create(taskID:)`, and reviews results. Unlike `/plan`, there is no separate Planner sub-agent or approval step — the current agent is the sole planner, coordinator, and final reviewer. See the [zen.md](zen.md) task orchestration section for details.

## Setup Parameters

When configuring a profile, setup asks for each parameter for a specific reason:

- **Model** — a dedicated model makes the profile eligible for delegation. Without one, the profile stays selectable with `/agents` but is excluded from the delegation roster.
- **Capability (1–10)** — ranks the profile for delegation routing. Leave unset only when the profile should not be delegated to.
- **Thinking** — extended-reasoning budget for models that support it. Skipped automatically for models without thinking support.
- **Tools** — restricts what the profile can call. Safety mechanism: `Reviewer` drops `shell`, `Minimal` keeps only essentials.
- **Skills** — optional reusable prompt fragments from the catalog.
- **Instructions** — the role definition, edited in a real text editor.
- **Symbol** — SF Symbol for the TUI picker (presentational).

## Configuring Profiles

```bash
zen setup              # create or edit profiles interactively
/agents                # select a profile in the TUI
/tools                 # expose or hide tool groups per session
```
