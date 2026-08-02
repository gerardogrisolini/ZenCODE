# Planner Agent Guide

The `Planner` profile is the read-only planning profile. It authors delegated plans before implementation — it does not edit files.

## What Planner Does

The Planner inspects only the context needed to make a plan concrete, then identifies:

- the goal and assumptions;
- likely files, modules, or areas to change;
- implementation phases and recommended order;
- dependencies, risks, edge cases, and open questions;
- validation commands or manual checks;
- when to run `/review` after implementation.

## Running A Plan

```text
/plan <goal>          # delegate planning to a read-only Planner
/plan save            # persist the current plan for this project
/plan load            # load the latest saved plan as unapproved
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

## Read-Only Safety

`/plan` delegates with an explicit read-only tool allowlist: files, search, non-mutating Git, read-only memory/task tools, and web. The Planner cannot edit files, run shell commands, or perform mutating operations.

## How Delegation Works

1. The current agent stays as coordinator only — it cannot draft, consolidate, or rewrite the plan.
2. One read-only sub-agent named `plan-author` is created with profile `Planner`.
3. The Planner receives the complete goal and writes the final plan itself.
4. The coordinator copies the Planner's numbered points into a `todo.write` bootstrap. The TUI validates those in-memory todo items as a DAG and records them in the active, unapproved plan.
5. If the output is incomplete, the coordinator asks the same Planner to revise — it never fills gaps itself.
6. The Planner-authored plan becomes the active, unapproved session plan.

If no completed Planner output or valid graph is available, the turn fails rather than falling back to a plan from another profile.

## Saving A Plan For Another Session

`/plan save` stores the active plan in a stable project-scoped plan-library checkpoint owned by the existing task-graph store. The graph tasks contain the structured items produced through `todo.write`; optional checkpoint metadata retains the original goal and complete plan text. No separate plan store or directory is created, and `/sessions new` can discard the live chat checkpoint without deleting the saved plan.

If the current agent produced a plan outside `/plan`, `/plan save` can promote its latest non-empty assistant response into an unstructured active plan and persist it through the same checkpoint mechanism.

In another session for the same working directory, `/plan load` loads the newest saved plan, displays it, adds it to the model context, and resets it to **unapproved** with pending task statuses so it can be reviewed or revised safely. It does not resume old execution attempts and never starts implementation automatically. Use `/plan approve` only after the loaded plan is ready.

`todo.write` itself is session-scoped in-memory compatibility state; durable plan data belongs to `SessionTaskOrchestrator` and its atomic task-graph checkpoint.

## After Approval

`/plan approve` activates the graph and immediately starts implementation with the current profile — no additional prompt is needed. Use `/plan status` during implementation to see graph-projected progress (`pending`, `in_progress`, `awaiting_validation`, `completed`, `blocked`, `failed`, `cancelled`).

The intended loop:

```text
/plan <goal> -> /plan approve -> implementation -> /review -> corrections -> /review
```
