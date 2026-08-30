# Planner Agent Guide

The `Planner` profile is the read-only planning profile. It authors delegated plans before implementation — it does not edit files.

## What Planner Does

Every new request addressed to the `Planner` profile begins with a mandatory
brainstorming turn, including when it is sent directly after selecting that
profile rather than through `/plan`. The Planner inspects only the context
needed to make the request concrete, then returns one focused numbered
`Planner questions` block; it does not produce a plan in that first turn. Its
final response, after the discussion is complete, is a concise, self-contained
functional analysis that an implementer can use with only the plan and the
workspace. It provides an ordered,
numbered implementation plan whose every point is self-contained as a
specification and implementable from the plan and workspace after its declared
dependencies.
Each point states:

- the concrete observable behavior and relevant flow;
- verified components, files, or symbols involved;
- applicable constraints and edge cases;
- a concrete validation command or manual check; and
- `Dependencies`, naming prerequisite point numbers or `none`.

The plan begins with `Specifiche concordate` and then its numbered
`Implementation plan`. The plan avoids generic formulations, placeholders, repetition, alternatives,
and decisions left to the implementer. It omits context summaries, generic
background, non-pertinent sections, and detail that does not change
implementation; it uses the fewest points and words that preserve implementation
certainty. It resolves needed decisions from the workspace and conversation; when
one is genuinely blocking, it asks one focused question rather than guessing. It
includes risks, open questions, persistence, compatibility, security,
concurrency, and other cross-cutting details only when they are pertinent to the
requested work.
Dependencies form a minimum-safe-edge DAG; independent points remain parallel
where that has a real latency or ownership benefit. The plan also indicates
when to run `/review` after implementation.

## Running A Plan

```text
/plan <goal>          # delegate planning to a read-only Planner
/plan save            # persist a reusable plan draft for this project
/plan load            # load the latest saved draft as unapproved
/plan status          # show plan progress from the graph state
/plan approve         # activate the plan and start implementation
/plan clear           # archive the graph and remove the active plan
```

A goal is required. Examples:

```text
/plan add support for archived memories in the memory search UI
/plan refactor TerminalChat command routing
```

Requires the `sub-agents` tool group. Enable it with `/tools sub-agents` or switch to a profile that includes it (such as `Developer`).

The same `/plan`, `/goal`, and `/review` command families are available from the terminal TUI,
the linked Telegram chat, and ACP clients. All three use the Agent Core command
routing kernel; Telegram keeps the Telegram chat as the response destination,
while ACP keeps the client's original command visible and sends only the hidden
operational prompt to the model. ACP resolves an optional leading `@agent` mention
before command routing.

Before finalizing, the first Planner turn always emits one numbered `Planner
questions` block, even when the request appears fully specified. It first
resolves what it can from the workspace and conversation so that question is
specific and useful. Ordinary follow-up messages answer that block and return
to the same Planner; it may emit one further question block per turn only when
a material decision remains unknown. This profile policy also applies to direct
Planner requests; `/plan` additionally supplies the managed continuation,
validation, and task-bootstrap workflow. Slash commands and live-chat
mentions retain their normal meanings. A new `/plan <goal>` closes the previous
Planner and replaces the unfinished discussion, while `/plan clear` cancels it.
The clarification control state and Planner ownership are runtime-only: neither is
saved in sessions, checkpoints, or the plan library, and collection must restart
after a new session, load/resume, setup restart, close, or shutdown. Visible
questions and replies may remain in ordinary chat history, but replay never
reactivates the collection and a question block is never accepted by `/plan save`.
While collection is active, `/plan save`, `/plan load`, `/plan approve`, and
`/goal` are refused; `/plan status`, list, delete, a replacement goal, and clear
remain available.

## Profile Tools

`/plan` selects the `Planner` profile explicitly. Selecting `Planner` directly
uses the same runtime brainstorming and plan-authoring policy. The delegated
Planner receives exactly the tools configured on that profile, plus runtime-intrinsic tools;
`agent.create` does not construct a separate tool list. The built-in profile has
`readOnly: true`; Planner identity also enforces that core read-only policy for
older manifests where the flag is absent or false. The filter runs after
`/tools`, app, ACP, or task-bound runtime grants are resolved, removes mutable
catalog-owned core tools, and preserves external or custom non-core grants. Optional
feature, MCP, and other external grants remain outside that classification.

## How Delegation Works

1. The current agent stays as coordinator only — it cannot draft, consolidate, or rewrite the plan.
2. One sub-agent named `plan-author` is created with profile `Planner`.
3. The Planner receives the complete goal and either asks its single question block or writes the final plan itself.
4. Only a final answer copies the Planner's numbered points into a `todo.write` bootstrap. The shared kernel validates those in-memory todo items as a DAG and records them in the active, unapproved plan.
5. If the output is incomplete, the coordinator asks the same Planner to revise — it never fills gaps itself. Follow-up turns accept only a fresh output revision from that Planner; recreation is allowed only when the previous instance is gone.
6. The Planner-authored plan becomes the active, unapproved session plan.

If no completed Planner output or valid graph is available, the turn fails rather than falling back to a plan from another profile.

## Saving and Loading Plans

`/plan save` writes a reusable copy of the active plan to a stable,
project-scoped plan-library checkpoint owned by the existing task-graph store.
The graph tasks contain the structured items produced through `todo.write`;
optional checkpoint metadata retains the original goal and complete plan text.
The saved copy is reset to an unapproved draft with pending task statuses, so it
does not carry execution progress or active attempts into another session. It
does not alter the plan that remains active in the current session. No separate
plan store or directory is created, and `/sessions new` can discard the live
chat checkpoint without deleting the saved plan.

If no plan is active, `/plan save` can promote the latest non-empty assistant
response into an unstructured active plan and persist it through the same
checkpoint mechanism. This supports plans written outside `/plan`; a text-only
save receives one stable implementation task at approval time rather than an
invented task breakdown.

In a session for the same working directory with **no active plan**, `/plan load`
retrieves the newest saved plan, displays it, adds it to the model context, and
resets it to **unapproved** with pending task statuses so it can be reviewed or
revised safely. It refuses to replace an active plan; run `/plan clear` first
when replacing one. Loading does not resume old execution attempts or the source
session and never starts implementation automatically. Use `/plan approve` only
after the loaded plan is ready.

`todo.write` itself is session-scoped in-memory compatibility state; durable plan data belongs to `SessionTaskOrchestrator` and its atomic task-graph checkpoint.

## After Approval

`/plan approve` creates and activates the graph in the current session, then
immediately starts implementation with the current profile — no additional
prompt is needed. Use `/plan status` during implementation to see graph-projected
progress (`pending`, `in_progress`, `awaiting_validation`, `completed`,
`blocked`, `failed`, `cancelled`).

The intended loop:

```text
/plan <goal> -> /plan save -> /sessions new (or /plan clear) -> /plan load -> review/revise -> /plan approve -> implementation -> /review
```
