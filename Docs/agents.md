# Agents and Sub-Agents

How agent profiles work and how the runtime delegates to sub-agents.

- Model bindings, capability routing, and the bindings table: [bindings.md](bindings.md).
- Per-profile guides: [builder.md](builder.md), [planner.md](planner.md), [reviewer.md](reviewer.md), [reporter.md](reporter.md), [organizer.md](organizer.md).

## Agent Profiles

A profile is the persisted configuration that defines how a model session
behaves. Profiles live in `~/.zencode/agents.json` and are loaded at session
start by `AgentProfileStore`.

| Field | Purpose |
| --- | --- |
| `id` | Stable identity. A system profile has its role as ID (`developer`, `planner`, …); custom profiles have any other ID (setup generates a UUID). It has no other meaning |
| `name` | Human- and model-visible label; any text, with no meaning |
| `role` | **Required.** One of `developer`, `builder`, `minimal`, `planner`, `reviewer`, `reporter`, `organizer`, `promoter`: the only field that determines the kind of agent (see [Profile Roles](#profile-roles)) |
| `instructions` | System-prompt fragment defining the role and constraints |
| `tools` | Allowed tool groups and feature packages |
| `readOnly` | Enforces only non-mutating catalog-owned core tools (`false` by default) |
| `skills` | Optional prompt skills from the app catalog |
| `modelBindings` | Models explicitly authorized for the profile — see [bindings.md](bindings.md) |
| `defaultModelBindingID` | Profile default for direct/profile-selected sessions; delegation still names a binding explicitly |
| `symbolName` | SF Symbol shown in the TUI picker (presentational only) |

Select a profile with `/agents` (menu, `<name>`, or `<number>`) or `--agent <name>`
at launch. Switching to a different profile resets the conversation so the new
system prompt and tools apply cleanly. The `/agents` menu also associates
profiles with the current project; see [Project Agents](#project-agents).

Profile IDs and names share one case- and diacritic-insensitive POSIX identity
namespace. Duplicate names, duplicate IDs, and an ID that collides with another
profile's name make `agents.json` invalid; the store and delegation runtime fail
closed instead of selecting the first matching tool grant.

> **Associate at least one model binding with every profile that should receive
> delegated work.** A profile without bindings stays selectable and can still be
> delegated explicitly through the legacy fallback, but it is excluded from
> capability-based delegation routing.

> **Workspace guidance:** `AGENTS.md` is optional. Create or edit it manually
> in the working directory when the project needs workspace-specific
> instructions. When present, ZenCODE reads it and adds it to the agent
> context; it does not automatically create or rewrite the project file. This
> project file is distinct from the global `~/.zencode/AGENTS.md`, whose rules
> apply across workspaces.

## Profile Roles

Every profile has a required `role`, and the role is the only thing that
determines what kind of agent the profile is. The ID and the name carry no
meaning: a profile named `Planner` with the `developer` role is a developer,
and a profile can have any name in any role.

| Role | Effect |
| --- | --- |
| `developer` | The default agent: used when no agent is chosen at launch. Setup always keeps a profile with this role |
| `builder` | It can use `/feature` and receives the intrinsic feature-management tools |
| `minimal` | No runtime effect beyond the profile's own configuration |
| `planner` | `/plan` delegates to it; its catalog-owned core tools are forced read-only, whatever `readOnly` says |
| `reviewer` | `/review` delegates to it |
| `reporter` | No runtime effect beyond the profile's own configuration |
| `organizer` | Its sessions use the global memory graph and delegate by role (see [memory.md](memory.md)), and their context lists the first-level folders of the working directory as `Projects in the launch folder`, read once when the agent is selected (see [organizer.md](organizer.md#selecting-organizer)); otherwise no runtime effect beyond the profile's own configuration |
| `promoter` | No runtime effect beyond the profile's own configuration |

```json
{
  "id" : "7D2C4A10-5B6E-4F21-9C3D-2E8A1B0F6C55",
  "name" : "Pippo",
  "readOnly" : true,
  "role" : "reviewer",
  "tools" : ["files", "feature:search-tools", "text"]
}
```

**System and custom profiles.** The recommended profiles created by `/setup`
are the system profiles: each one has its role as ID (`"id" : "developer"`,
`"id" : "planner"`, and so on). A profile is a system profile exactly when its
ID equals its role (case-insensitive); custom profiles have a different ID, and
`/setup` gives them a UUID. Being a system profile matters only for
[Project Agents](#project-agents): a project without a saved selection sees the
system profiles alone.

**Strict format.** `role` must be present and spelled exactly as one of the
eight values above. The role is never deduced from the ID or the name, and
there is no automatic migration: an `agents.json` with a profile without
`role`, or with any other value, is invalid. ZenCODE then requires setup and
reports the profile, for example
`profile 'Developer' is missing the required "role" field (one of: developer, builder, minimal, planner, reviewer, reporter, organizer, promoter).`;
`/setup` asks `agents.json exists but is invalid. Rewrite it?` and, when
confirmed, starts over and offers to create the recommended profiles.

Set the role in `/setup` (the **Role** choice) or edit `agents.json`.

**Default developer.** With several profiles in the `developer` role, the
default agent is the system Developer (`"id" : "developer"`) when present,
otherwise the first developer profile in `agents.json` order. Setup adds the
system Developer only when no profile has the `developer` role, and the default
developer cannot be deleted in setup.

Several profiles can share a role. `/plan` and `/review` then list every
candidate visible to the project in their delegation instructions and the model
may use any of them; with a single candidate the instruction names just that
profile. The delegatable roster in the system prompt shows the role of every
profile next to the access mode, for example
`- Pippo [read-only; role: reviewer; tools: …]`, and the `/agents` menu
describes every profile by its role.

## Project Agents

The `sub-agents` tool delegates only to the profiles associated with the
project of each sub-agent: the directory it works in, which is the coordinator's
unless `workingDirectory` is set (see [Sub-Agents](#sub-agents)). `/agents`
opens one multiple-selection menu for both choices:

```text
> [x] Developer * - General software development; the default agent
  [x] Reviewer - /review delegates to it
  [ ] Pippo - /review delegates to it
```

| Key | Effect |
| --- | --- |
| `↑`/`↓` | Move the cursor (it starts on the active agent, marked ` *`) |
| `Space` / `X` | Tick or untick the highlighted profile for this project |
| `A` / `N` | Tick every profile / none |
| `Enter` | Save the ticks and make the highlighted profile the active agent |
| `Esc` / `Q` | Cancel: nothing is saved and nothing changes |

Confirming without moving the cursor keeps the active agent. Changing only the
ticks keeps the conversation and refreshes the delegatable roster in the system
prompt in place; choosing a different agent resets the session as before.
Choosing the active agent always lists every profile, whatever the project
association.

The association is stored outside the repository, one file per project, keyed
like the workspace memory by the standardized path of the working directory:

```text
~/.zencode/projects/<sha256 of the project path>/agents.json
```

```json
{
  "agentIDs" : [
    "7D2C4A10-5B6E-4F21-9C3D-2E8A1B0F6C55",
    "developer"
  ],
  "version" : 1,
  "workspacePath" : "/Users/me/Projects/App"
}
```

Profiles are saved by ID, so renaming a profile keeps its association. The file
is written only when the ticks change, so choosing another agent in a project
without a file does not create one.

- **No file:** the project is not configured yet. Only the system profiles
  (see [Profile Roles](#profile-roles)) are delegatable, and the menu shows just
  those ticked. The ticks take effect from the first save. An unreadable or
  corrupt file is treated the same way. When no system profile exists either,
  the prompt states that no profile is associated with the project.
- **Saved selection:** literal. Only the listed profiles appear in the
  "Delegatable agent profiles" roster and are accepted by `agent.create`;
  profiles created later are not added automatically.
- **Empty selection:** no profile is delegatable. The prompt states that no
  profile is associated with the project and tells the model not to call
  `agent.create`; the operator can associate profiles again with `/agents`.
- **Enforcement:** `agent.create` rejects a profile that is not associated with
  the sub-agent's project even if the model names it, so the roster is a boundary
  and not only a hint.
- **`/plan`, `/review`, and `/goal`:** these workflows delegate through the same
  `agent.create` call, so they can only delegate to the profiles visible to the
  project. `/plan` and `/review` use the visible profiles with the `planner`
  and `reviewer` role (see [Profile Roles](#profile-roles)): the saved
  selection, or the system profiles when there is none; with several
  candidates the model chooses among them. When no visible profile has the
  needed role, the command always stops with an error instead of delegating,
  with or without a saved selection and without falling back to the
  recommended profiles, for example
  `ZenCODE: no agent profile with the reviewer role is available for this project. Tick one with /agents.`

## Recommended Profiles

| Profile | ID and role | Purpose | Toolset |
| --- | --- | --- | --- |
| `Developer` | `developer` | General development and coordination | coding + web + sub-agents |
| `Builder` | `builder` | Swift feature packages | coding + web |
| `Minimal` | `minimal` | Essential tools, brief replies | shell, files, text |
| `Reviewer` | `reviewer` | Read-only code review | coding without shell; `readOnly` enforced |
| `Reporter` | `reporter` | Code analysis and evidence-based reports | files, search, text, git; `readOnly` enforced |
| `Planner` | `planner` | Read-only planning | files, search, text, git, memory, web; `readOnly` enforced |
| `Organizer` | `organizer` | Personal assistant: macOS apps, project state, delegation (macOS only) | macOS feature + memory + sub-agents |
| `Promoter` | `promoter` | Daily project promotion step with Browser drafts | memory + browser-tools |

These are the system profiles: each one has its role as ID. They are examples —
edit, add, or remove optional profiles in setup. A profile with the
`developer` role must always remain present, because it is the default agent;
`/feature` and its intrinsic feature-management tools are available only to a
profile with the `builder` role.

Existing `agents.json` manifests are not changed: regenerate the recommended
profiles in setup to give an existing `Reporter` the read-only setting.

## Tool Groups

**Core:** `shell`, `files`, `text`, `memory`, `sub-agents`.

**Feature packages** (discovered and enabled separately): `search-tools`,
`web-tools`, `git-tools`, `swift-tools`, `xcode-tools`, `figma-tools`,
`jira-tools`, `desktop-tools`, `browser-tools`, `macOS`.

Enabling a package makes it available; `/tools` exposes it in the current
session. The `sub-agents` group is what lets a profile create delegated
sub-agents.

## Sub-Agents

A sub-agent is a delegated, independently running model session spawned by the
coordinator. The coordinator stays in its own profile and directs the work.

Lifecycle:

1. The coordinator calls `agent.create` with the canonical `agents` array. Every
   model-visible item names either an exact `profile` (one associated with the
   project, see [Project Agents](#project-agents)) and the exact `binding:<id>`
   value shown in the delegation roster as `model`, or a `profileRole`. A
   `profileRole` is resolved to a profile associated with the sub-agent's
   directory, and its model binding is chosen from `complexity`.
2. The runtime resolves the profile and binding against one authoritative
   snapshot of the configured model catalog. Missing, stale, ambiguous, or
   capability-less bindings, and providers missing required authentication, are
   rejected before any reservation or task claim.
3. The resolved provider, model, API-key lookup, and generation settings travel
   with the child backend context. Backend creation does not repeat a global
   model lookup or route by a bare provider model slug.
4. The sub-agent works in the coordinator's working directory, or in the
   directory set by `workingDirectory`: an existing directory equal to or inside
   it, given as an absolute or relative path. Files, shell, git, project memory,
   and project-agent association follow that directory. Symlinks are resolved
   to check that it is inside the coordinator's directory and to name its target
   there: the sub-agent then works under the coordinator's own unresolved path
   (a link inside it is followed to the directory it points to), so it sees the
   same project selection and memory as a `zen` session started there. It
   receives the tools configured on that profile; `agent.create` cannot replace
   or narrow them.
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

### Messages

While sub-agents run, the coordinator and active agent instances share a live,
transient chat room (`AgentSharedChat`). It carries the `agent.message` tool and
the operator mentions typed in the terminal. It is bounded and in-memory: nothing
in it is written to a session snapshot or task checkpoint, and only
`SessionTaskOrchestrator` owns persisted state. A logical session reset drops it.

Three participant kinds share the room:

- **operator** — the human at the terminal. A trusted sender that never occupies
  a room slot or mailbox, so it can always reach the coordinator and active
  agents.
- **coordinator** — the current LLM agent directing the work.
- **agent** — a delegated sub-agent instance.

`agent.message` delivers through one destination:

| `to` | Recipients |
| --- | --- |
| `direct` (default) | The exact `id`/`name`/`ids` named. A direct message wakes an idle recipient immediately. |
| `operator` | The human terminal operator only. |
| `coordinator` | The coordinator only. |
| `peers` | Every other active delegated agent, never the sender. |
| `all` | The human terminal operator, coordinator, and every active delegated agent except the sender. |

From the terminal or linked Telegram chat the operator addresses the live room
with a leading mention: `@coordinator`, `@all`, or a readable `@agent-name`
handle derived from each active instance's display name by an actor-isolated
catalogue. The handle is a presentation alias: routing always resolves back to
the stable participant id, so it survives duplicate or renamed agents. Aliases
are never recycled within a session, and duplicate names are disambiguated with
a numeric suffix (`@worker`, `@worker-2`). `@all` and `@coordinator` are
reserved for the whole session, so an agent that collides with either name is
offered as `@all-2` or `@coordinator-2` and routes to that agent — the bare
broadcast spellings can never be captured. A name that yields no readable slug
(Unicode-only, bidi-only or punctuation-only) falls back to the stable handle
`@agent` (with numeric suffixes for further collisions); internal ids and UUIDs
are never shown. The legacy `@agent-Base64` spelling remains accepted for
backward compatibility but is never offered by the autocomplete list. A
recognised mention without a message body is rejected as invalid input rather
than queued behind a running generation.

Replies travel back through the same chat. Any message injected into a
coordinator or agent turn instructs the recipient to answer through
`agent.message`: ordinary model output is never part of the chat, so both the
coordinator and a delegated agent must send their reply via `agent.message`,
regardless of who the sender is. The operator sees every chat message in the
terminal's transient `Chat` reader; a delegated agent sees only what its
mailbox delivers. If a delegated agent's direct conversational turn was started
by the operator and it ends without calling `agent.message`, the runtime
delivers its final output once
to `operator` as a fallback rather than routing it through the coordinator or
duplicating an explicit chat reply.

Delivery is priority-based for the coordinator and delegated agents alike. When
a recipient is already working, its next tool result injects the message into
model-facing content (not visible tool output), so it replies immediately
through `agent.message` and then resumes its current work. Idle and standby
agents still receive a normal serialized work-loop prompt. If an active turn
ends without another tool call, the ordinary synthetic coordinator turn or
queued agent prompt is the lossless fallback. A message is never lost or
delivered twice: each state has exactly one mailbox owner, and the coordinator
authorises at most one
synthetic turn from the chat at a time. The bounded room transcript is replayed
to every active observer within the transcript bound and deduplicated by message
id; each client chooses its presentation. Shared-chat events are never dropped
from the terminal queue. In the terminal UI,
those events feed only the transient `Chat` reader: closed empty is invisible,
closed with messages is compact with total and unread counts, open empty remains
compact, and open with messages is expanded; message boxes are never appended to
the main transcript.

The coordinator authorises at most one synthetic turn from the chat at a time,
never starting a second generation behind a running one. `agent.message` is a
mutating core tool, so a read-only profile can receive chat messages but cannot
send them.

### Tool Authority

Write authority normally comes from the selected profile's configured tools. A child resolved to the coordinator's same profile instead inherits the coordinator's effective session allowlist; different profiles remain isolated:

- Every model-visible batch item names exactly one of `profile` or `profileRole`,
  which must resolve to a configured profile; otherwise `agent.create` fails.
  The `agent` name is a compatibility-only input alias.
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

`/plan` and `/review`, and `/goal` when it delegates, use the selected profile's own tools unless that profile is the coordinator's same resolved profile, in which case the coordinator's effective session allowlist is inherited. Different profiles remain isolated; configure each profile with exactly the access required for its role.

### Model Selection

Which model a sub-agent runs on is decided by the profile's currently routable
authorized bindings and the task complexity. The prompt lists one exact
`binding:<id>` reference for each eligible binding; `agent.create` requires that
explicit reference and carries the resulting provider selection through backend
creation. The exception is an item with `profileRole`: the runtime chooses its
profile and binding together from `complexity` (see
[Selection Policy](bindings.md#selection-policy)). A profile with no bindings can
still inherit the parent model through the legacy programmatic input path, but it
is not model-visible or eligible for capability routing. The resolution table,
the capability scale, and the ordered
selection policy are documented in [bindings.md](bindings.md).

## Task Graph Integration

Coordinated multi-step work is tracked by the session task graph
(`SessionTaskOrchestrator`). The coordinator creates tasks with dependencies,
selects runnable work with `tasks.list`, and assigns delegated tasks by passing
`taskID` to `agent.create` for atomic claims. A sub-agent joins a graph only at
creation time; taskless agents are for single self-contained lookups.

`/goal <goal>` automates this pattern:

1. It inspects the request, workspace, existing context, and project conventions to
   derive the concrete objective and testable acceptance criteria without requiring
   routine confirmation from the user.
2. It creates an active workflow graph.
3. The current agent adds its task definitions with `tasks.create`, including a
   `complexity` per task.
4. It executes directly using `tasks.update` (`pending` → `in_progress` →
   `completed` after validation), or delegates when useful through a canonical
   `agent.create` `agents` item containing `taskID`.
5. It validates and reviews the results.
6. If a coordinator generation ends while the graph is still open, the runtime
   automatically starts another coordinator generation on that same graph. It
   returns control after graph-backed completion, explicit cancellation, or a
   structured workflow pause (`awaiting_user` for clarification, `blocked` for an
   unresolved genuine blocker). A paused workflow is not automatically retried.

The coordinator pauses with `tasks.update`, using only `graphID`, the
`expectedRevision` returned by `tasks.list`, and `workflow: {state, message}`.
The message explains the question or blocker; no exact heading is required and
text alone does not suspend new workflows. This mode is root-only, rejects task
fields and changes to the original objective, and requires the current active
workflow graph. A user reply resumes that same graph. The original `/goal`
argument and workflow control state live in optional schema-1 checkpoint
metadata, separate from tasks, and are restored even before any tasks exist.
Legacy checkpoints remain readable; their missing objective is stated explicitly,
not guessed. Until first resumed or structurally updated, legacy graphs without
metadata retain their old heading-based clarification fallback.

Workflow tasks use `execution.executor: coordinator` for direct work or
`sub_agent` for delegation. The DAG is retained in both cases, and the normal
tool grant is unchanged: `/goal` neither requires nor implicitly enables
sub-agent tools or mutation tools. Delegated results require independent
validation; on failure use `tasks.retry` and a new attempt, not `agent.message`
to reopen a completed child. Direct retries use `tasks.update in_progress`;
delegated retries use a new `agent.create` item containing `taskID`.
Unlike `/plan`, there is no separate Planner sub-agent and no approval step.
See the [zen.md](zen.md#task-orchestration) task orchestration section.

## Setup Parameters

- **Model bindings** — models explicitly permitted for the profile, with their
  capability and thinking settings. See [bindings.md](bindings.md).
- **Tools** — restricts what the profile can call. Safety mechanism: `Reviewer`
  drops `shell`, `Minimal` keeps only essentials.
- **Read-only agent?** — persistently restricts catalog-owned core tools to
  their non-mutating descriptors, even if a later session tool selection asks
  for a mutable core group. Existing manifests default this field to `false`.
- **Role** — a required single choice among the eight roles (there is no
  "none"), saved as `role` (see [Profile Roles](#profile-roles)). The
  highlighted entry is the profile's current role, or `Developer` for a new
  profile, and must be confirmed; cancelling the choice ends the agents setup
  with an error, as the other prompts do.
- **Skills** — optional reusable prompt fragments from the catalog.
- **Instructions** — the role definition, edited in a real text editor.
- **Symbol** — SF Symbol for the TUI picker (presentational).

## Configuring Profiles

```text
/setup                # create or edit profiles interactively
/agents               # active agent and project profiles (menu)
/models                # choose any configured model for the current session
/tools                 # expose or hide tool groups per session
```

`/models` is intentionally independent from `/agents`: changing profile changes
role, instructions, tools, and the default binding, but never filters the
available model catalog.
