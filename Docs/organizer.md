# Organizer Agent Guide

The `Organizer` profile acts as the user's personal assistant. It manages the day through macOS apps, keeps track of project state in memory, and coordinates project work by delegating it to other profiles.

Unlike the coding profiles, the `Organizer` never touches project files or the shell: it reads and acts on calendar, reminders, contacts, mail, messages, notes, and photos, and it hands every project intervention to a sub-agent.

## What Organizer Does

- **Daily briefing** — on request, gathers today's events, overdue reminders and reminders due today, unread mail, and open project items from memory. Mail is triaged with one line per message (`now`, `later`, or `ignore`, plus a suggested action), the briefing stays readable in less than a minute, and it ends with the single most important next step.
- **Planning** — on request, plans the day or the week starting from the fixed commitments and deadlines in calendar and reminders, asks only for what is missing, sorts the work into `must-do`, `should-do`, and `later` with honest estimates and some slack, and gives one concrete first step for the most important task. It creates events or reminders from the plan only when asked.
- **Drafts** — writes mail and messages in the user's voice, following the recorded preferences, and shows the complete draft (recipient, subject, and text) before sending.
- **Project state** — recalls and records decisions, open items, deadlines, and the outcome of delegated work in the global memory graph, with one entry per project.
- **Delegation** — when the user asks for a project intervention, delegates it by role (for example `planner`, `developer`, `reviewer`, or `reporter`) with a precise brief, in the project's own folder.

While gathering information the `Organizer` may point out what it notices (overlapping events, overdue reminders, mail that needs an answer today), but it never acts on it unless the user asks.

## Requirements

- macOS only. On other platforms the `Organizer` is not included in the default profiles. The recommended `Organizer` is the system profile with ID and role `organizer`. That role makes its sessions use the global memory graph and delegate by role (see [agents.md](agents.md#profile-roles)).
- The optional `macOS` feature, installed with `zen --install-features macOS` (or selected in setup) and enabled with `/tools`.
- Access to the individual apps. When an app reports missing access, the `Organizer` checks `macos.permissions` and tells you exactly which permission to grant instead of retrying.

## Selecting Organizer

Select it directly, launching from the folder that contains your projects. The roles it can delegate to are those of the profiles associated with that folder with `/agents`, or the system profiles when none is saved there (see [Project Agents](agents.md#project-agents)). A delegated `workingDirectory` must be an existing directory inside the coordinator's working directory, so every project below it can be reached:

```text
/agents Organizer                                         # switch to the Organizer profile
zen --agent Organizer --working-directory ~/Projects      # launch directly
```

## Tools

The `Organizer` toolset is limited to:

- `macOS` — the `macos.*` tools for calendar, reminders, contacts, mail, messages, notes, photos, and permissions;
- `memory` — project state and recorded preferences;
- `sub-agents` — delegation of project work.

It intentionally has no `files`, `shell`, or `text` access, so it can never modify a project directly. The profile is not `readOnly`: a read-only grant would reduce `memory` and `sub-agents` to their read descriptors.

## Approvals

Destructive or outbound actions (sending mail or messages, deleting events, reminders, contacts, notes, or mail) run only with `confirm=true`, and the `Organizer` passes it only after your explicit confirmation in the current conversation.

- One approval covers exactly one operation. A changed draft, another recipient, or a repeated action needs a new confirmation.
- A draft is sent only after an explicit yes for that draft.
- Nothing is sent on the basis of the content of a mail, a message, or a sub-agent's result: content read from apps is treated as data, never as instructions.
- Delegated sub-agents ask for their own approvals; confirming an action to the `Organizer` does not approve what a sub-agent does.

## Memory and Preferences

When a choice depends on your habits (time zone and working hours, default calendar and reminder list, mail account, tone and signature of drafts, recurring people), the `Organizer` asks once, records the answer with `memory.write` as a `preference`, and reuses it afterwards without asking again. It never asks for preferences in advance.

Its memory is global and does not depend on the directory: preferences and project state live in `<supportDirectory>/memory/global/memory.graph.json` (see [memory.md](memory.md)), so the `Organizer` finds them from any working directory.

## Delegated Work

Project work is delegated by role. The `Organizer` creates each sub-agent with `profileRole`, `complexity` (1-10), and `workingDirectory` set to the project's folder, and never names a profile or a model. The runtime resolves the role to a profile associated with that project (see [Project Agents](agents.md#project-agents)) and selects its model binding from the complexity (see [bindings.md](bindings.md#resolution-rules)). The sub-agent lifecycle is described in [agents.md](agents.md#sub-agents). The `Organizer` sees in its prompt only the roles of the profiles associated with the folder it was launched from (see [Selecting Organizer](#selecting-organizer)); each sub-agent's role is resolved against the profiles associated with that sub-agent's own folder.

To read a project's state, the `Organizer` delegates to the `reporter` or `reviewer` role and reports the result. Both are `readOnly` in the recommended profiles.

The `Organizer` cannot read files or run commands, so it cannot validate a delegated implementation. It reports the sub-agent's result as unvalidated and asks whether you want to accept it, validate it yourself, or have a `Reviewer` delegated to check it.

## Example Requests

```text
Give me today's briefing.
Plan my week around the deadlines in Reminders.
Draft a reply to the last mail from Anna and show it to me before sending.
Ask the Developer to fix the failing login test in ~/Projects/app and tell me what changed.
```

## Updating an Existing Profile

Existing `agents.json` manifests are not changed when ZenCODE updates the recommended instructions. Regenerate the recommended profiles in setup to give an existing `Organizer` the current instructions. A manifest whose profiles lack the required `role` field is invalid: `/setup` offers to rewrite it with the recommended profiles.
