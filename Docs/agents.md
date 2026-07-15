# Agents and Sub-Agents

How agent profiles work, how the runtime delegates to sub-agents, and what each setup parameter controls. Per-profile guides: [builder.md](builder.md), [planner.md](planner.md), [reviewer.md](reviewer.md), [xcode.md](xcode.md).

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

| Profile | Role | Default tools |
| --- | --- | --- |
| `Default` | General coding agent | coding + web + sub-agents |
| `Builder` | Swift feature packages | coding + web |
| `Minimal` | Essential tools, brief replies | shell, files, text |
| `Xcode` | Xcode-native via ACP | shell, memory, web |
| `Reviewer` | Read-only code review | coding without shell |
| `Planner` | Read-only planning | files, search, text, git, memory, web |

Profiles are examples — you can edit, add, or remove them in setup. A `Default` profile must always exist (several runtime paths fall back to it).

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

`isolationMode` controls write authority: `report` = read-only (used by `/plan` and `/review`); implementation modes grant write authority.

## Capability Routing

The runtime builds a delegation roster containing only profiles that have **both** `modelID` and `capability`. The model matches task complexity to agent capability:

```
Delegatable agent profiles (match agent capability to task complexity):
- Minimal (capability 3/10): minimal
- Default (capability 7/10): default
Low-complexity (1–3) → low-capability; medium (4–6) → mid; high (7–10) → high.
```

This is capability-based, not seniority-based: a junior/senior split is expressed by combining `capability` with `modelID` and a restrictive or permissive `tools` set — not by inventing nominal roles.

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph (`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies, selects runnable work with `tasks.list`, and assigns delegated tasks by passing `taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at creation time; taskless agents are for single self-contained lookups. See the [zen.md](zen.md) task orchestration section for details.

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
