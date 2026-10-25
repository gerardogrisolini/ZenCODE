# Organizer Agent Guide

The `Organizer` profile acts as the user's personal assistant. It manages the day through macOS apps, keeps track of project state in memory, and coordinates project work by delegating it to other profiles.

Unlike the coding profiles, the `Organizer` never touches project files or the shell: it reads and acts on calendar, reminders, contacts, mail, messages, notes, and photos, and it hands every project intervention to a sub-agent.

## What Organizer Does

- **Daily briefing** — on request, gathers today's events, overdue reminders and reminders due today, unread mail, and open project items from memory. Mail is triaged with one line per message (`now`, `later`, or `ignore`, plus a suggested action), the briefing stays readable in less than a minute, and it ends with the single most important next step.
- **Planning** — on request, plans the day or the week starting from the fixed commitments and deadlines in calendar and reminders, asks only for what is missing, sorts the work into `must-do`, `should-do`, and `later` with honest estimates and some slack, and gives one concrete first step for the most important task. It creates events or reminders from the plan only when asked.
- **Drafts** — writes mail and messages in the user's voice, following the recorded preferences, and shows the complete draft (recipient, subject, and text) before sending.
- **Project state** — recalls and records decisions, open items, deadlines, and the outcome of delegated work in project memory.
- **Delegation** — when the user asks for a project intervention, delegates it to the profile that fits the work (for example `Planner`, `Developer`, `Reviewer`, or `Reporter`) with a precise brief.

While gathering information the `Organizer` may point out what it notices (overlapping events, overdue reminders, mail that needs an answer today), but it never acts on it unless the user asks.

## Requirements

- macOS only. On other platforms the `Organizer` is not included in the default profiles. The recommended `Organizer` is the system profile with ID and role `organizer`; the role has no runtime effect beyond the profile's own configuration (see [agents.md](agents.md#profile-roles)).
- The optional `macOS` feature, installed with `zen --install-features macOS` (or selected in setup) and enabled with `/tools`.
- Access to the individual apps. When an app reports missing access, the `Organizer` checks `macos.permissions` and tells you exactly which permission to grant instead of retrying.

## Selecting Organizer

Select it directly, launching from the working directory whose project memory it should use:

```text
/agents Organizer                                         # switch to the Organizer profile
zen --agent Organizer --working-directory /path/to/dir    # launch directly
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

Project memory is scoped to the workspace: the graph lives in `<supportDirectory>/memory/<sha256(workspacePath)>/` (see [memory.md](memory.md)). Always start the `Organizer` from the same working directory to find your preferences and project state again.

## Delegated Work

Delegation goes through profiles that carry model bindings; see [bindings.md](bindings.md) for capability routing and [agents.md](agents.md) for the sub-agent lifecycle.

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
