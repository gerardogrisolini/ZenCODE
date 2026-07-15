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
4. The coordinator copies the Planner's numbered points into a `todo.write` bootstrap, which the TUI validates as a DAG and records as a draft task graph.
5. If the output is incomplete, the coordinator asks the same Planner to revise — it never fills gaps itself.
6. The Planner-authored plan becomes the active, unapproved session plan.

If no completed Planner output or valid graph is available, the turn fails rather than falling back to a plan from another profile.

## After Approval

`/plan approve` activates the graph and immediately starts implementation with the current profile — no additional prompt is needed. Use `/plan status` during implementation to see graph-projected progress (`pending`, `in_progress`, `awaiting_validation`, `completed`, `blocked`, `failed`, `cancelled`).

The intended loop:

```text
/plan <goal> -> /plan approve -> implementation -> /review -> corrections -> /review
```
