# Agents and Sub-Agents

This guide explains how `ZenCODE` agent profiles work, how the runtime delegates
work to sub-agents, and why setup asks for each parameter. It is the general
reference; per-profile guides live in the sibling documents:

- `builder.md`
- `planner.md`
- `reviewer.md`
- `xcode.md`

## What An Agent Profile Is

An agent profile is the named, persisted configuration that defines how a model
session behaves. Profiles are stored in `~/.zencode/agents.json` and are loaded
at session start by `AgentProfileStore`.

Each profile carries:

- `id` — stable identity used for selection, delegation, and task-graph routing.
- `name` — the human- and model-visible label (for example `Default`,
  `Reviewer`, `Planner`).
- `instructions` — the system-prompt fragment that defines the role and the
  operating constraints for that profile.
- `tools` — the tool groups and feature packages the profile is allowed to use.
- `skills` — optional prompt skills selected from the app catalog.
- `modelID` and `modelProvider` — the dedicated model bound to the profile.
- `thinkingSelection` — the thinking budget for models that support extended
  reasoning.
- `capability` — a 1–10 value that ranks the profile for delegation routing.

The active profile is selected with `/agents <name>` inside a TUI session or
with `--agent <name>` at launch. Selecting an agent resets the active
conversation so the new system prompt and intrinsic tools are applied cleanly.

## Recommended Profiles

Setup can create the six built-in profiles in `agents.json`:

| Profile     | Role                              | Default tool set                                   |
| ----------- | --------------------------------- | -------------------------------------------------- |
| `Default`   | General coding agent              | coding tools + web + sub-agents                    |
| `Builder`   | Swift feature package management  | coding tools + web                                 |
| `Minimal`   | Essential tools, brief replies    | shell, files, text                                 |
| `Xcode`     | Xcode-native work via ACP         | shell, memory, web                                 |
| `Reviewer`  | Read-only code review             | coding tools without shell                         |
| `Planner`   | Read-only planning                | files, search, text, git, memory, web              |

Profiles are examples, not fixed roles. You can edit, add, or remove profiles
during setup. The only hard constraint is that a `Default` profile must always
exist, because several runtime paths fall back to it.

## Tool Groups

A profile's `tools` field holds a mix of intrinsic core groups and optional
feature packages.

Core tool groups:

- `shell` — run shell commands in the workspace.
- `files` — read, write, edit, and move local files.
- `text` — inspect and transform local text files.
- `memory` — manage memory notes and the session todo list.
- `sub-agents` — delegate work to sub-agents and coordinate session tasks.

Feature packages are discovered and enabled separately:

- `search-tools`
- `web-tools`
- `git-tools`
- `swift-tools`
- `xcode-tools`
- `figma-tools`
- `jira-tools`

Enabling a feature package makes it available to `ZenCODE`. To expose a package
in the current model session, select it with `/tools`. The `sub-agents` group is
what lets a profile create delegated sub-agents; without it, profiles such as
`Planner` and `Reviewer` cannot run their dedicated `/plan` and `/review`
commands.

## Sub-Agents

A sub-agent is a delegated, independently running model session spawned by the
active coordinator. The coordinator stays in its own profile and directs work;
each sub-agent runs with its own profile, model, tools, and constraints.

The delegation lifecycle is:

1. The coordinator decides the work is delegated (explicitly, or through a task
   graph) and calls `agent.create`, optionally passing a `profile`.
2. The runtime resolves the profile from `agents.json`, or falls back to a
   built-in default, and spawns the sub-agent session.
3. The sub-agent inherits the coordinator's workspace and the tool allowlist
   defined by its profile.
4. The coordinator sends messages with `agent.message`, waits with `agent.wait`,
   inspects output with `agent.get`, and closes the sub-agent with
   `agent.close`.

`isolationMode` controls write authority:

- `report` — read-only. Used by `/plan` and `/review` so delegated planners and
  reviewers cannot mutate files.
- implementation modes — granted write authority for implementation work.

A sub-agent that owns a task-graph task receives the corresponding `taskID` so
its claim and execution attempt are recorded atomically. A taskless sub-agent
(one created without a `taskID` while a graph is active) cannot be retroactively
attached to a graph.

## Capability Routing

The runtime exposes a roster of delegatable profiles to the model so the model
can match task complexity to agent capability when delegating. The roster is
generated by `SystemPromptBuilder.delegatableAgentsSection` and contains only
profiles that have **both** a `modelID` and a `capability`.

```
Delegatable agent profiles (match agent capability to task complexity):
- Minimal (capability 3/10): minimal
- Default (capability 7/10): default
- Reviewer (capability 9/10): reviewer
- Planner (capability 10/10): planner
Low-complexity tasks (1–3) → low-capability agent; medium (4–6) → mid-capability; high (7–10) → high-capability.
```

This is why the two parameters matter together:

- **`modelID`** — a dedicated model makes a profile eligible for delegation.
  Profiles without a model stay available for direct selection with `/agents`,
  but are excluded from the delegation roster.
- **`capability`** — a 1–10 ranking that guides which profile the model picks
  for a delegated task. The runtime maps it to task complexity:
  1–3 lightweight lookups and simple edits, 4–6 standard implementation,
  7–10 complex reasoning and architecture.

`capability` is a capability-based mechanism, not a seniority label. A junior
versus senior split is expressed by combining `capability` with `modelID` and a
restrictive or permissive `tools` set, not by inventing nominal roles.

## Task Graph And Delegation

Coordinated multi-step work is tracked by the session task graph, owned by
`SessionTaskOrchestrator`. The graph is the control plane for delegation:

- The coordinator creates tasks with `tasks.create`, including dependencies.
- Runnable work is selected with `tasks.list`.
- Direct attempts are recorded with `tasks.update`.
- Delegated attempts pass the `taskID` to `agent.create` so the claim is atomic.
- Dependencies gate execution; completed report work can finish immediately,
  while delegated implementation stops at `awaiting_validation` until
  independently validated.

A sub-agent is assigned to a graph task only at creation time. When a task graph
is active, every delegated agent must use a `taskID`; taskless agents are
reserved for single self-contained lookups. `/plan status` projects graph states
into the active plan table, and the TUI emits a compact graph overview as
attempts change.

## Why Setup Asks For Each Parameter

### Model

A dedicated model binds a profile to a specific provider and model id. This is
required for the profile to appear in the delegation roster. Setup groups
configured models by provider and shows the resolved thinking default. Choosing
*No dedicated model* leaves the profile selectable with `/agents` but removes it
from delegation routing.

### Capability

Capability (1–10) ranks the profile against other delegatable profiles so the
model can route a delegated task to a matching level of power. Setup prints the
guidance inline:

```
1–3: lightweight model (lookups, simple edits)
4–6: balanced model (standard implementation)
7–10: powerful model (complex reasoning, architecture)
```

Leave capability unset only when the profile should not be eligible for
delegation.

### Thinking

Thinking selection sets the extended-reasoning budget for models that support
it. The available options depend on the chosen model. Setup shows the model's
default and lets you override it per profile. Models without thinking support
skip this step entirely.

### Tools

The tool selection restricts what the profile can actually call. This is a
safety and focus mechanism: `Reviewer` drops `shell` so it cannot run arbitrary
commands, while `Minimal` keeps only shell, files, and text to stay fast and
predictable. Feature packages appear here only when enabled.

### Skills

Skills are reusable prompt fragments from the app catalog. They are optional and
add domain-specific context or instructions to the profile. Setup lists
installed skills and marks any saved skill that is no longer installed.

### Instructions

Instructions are the role definition. They are edited in a real text editor
(temporary file opened with `/usr/bin/open -W -t`) so long, structured prompts
are practical. Built-in instructions are kept stable across memory-tool
availability; custom instructions are preserved verbatim.

### Symbol

`symbolName` is the SF Symbol shown next to the profile in the TUI agent picker
and overview. It is purely presentational.

## Configuring Profiles

Run setup to create or edit profiles:

```bash
zen --setup
```

The agents step lets you regenerate the recommended six, edit the list, or start
from a custom set. A second step assigns a dedicated model and capability to
each profile; profiles without a model are excluded from the delegation roster.

Inside a running session:

- `/agents` — select a profile and reset the session.
- `/agents <name>` — switch directly to a named profile.
- `/tools` — expose or hide tool groups and feature packages for the current
  session.

## Related Commands

- `/plan <goal>` — delegate read-only planning to one `Planner` sub-agent.
  Requires the `sub-agents` tool group. See `planner.md`.
- `/review` — delegate read-only review to `Reviewer` sub-agents. Requires the
  `sub-agents` tool group. See `reviewer.md`.
- `/feature` — manage Swift feature packages from the `Builder` profile. See
  `builder.md`.
