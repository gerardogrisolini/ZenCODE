# Planner Agent Guide

The `Planner` agent profile is the read-only planning profile included with `ZenCODE`. It is designed for delegated planning before implementation, not for editing files.

Use it through the `/plan` TUI command when you want an independent planning pass before starting or resuming work.

## What Planner Does

The Planner plan author inspects only the context needed to make an implementation plan concrete. It should identify:

- the goal and assumptions;
- likely files, modules, or documentation areas to inspect or change;
- implementation phases and recommended order;
- dependencies, risks, edge cases, and open questions;
- validation commands or manual checks;
- when to run `/review` after implementation.

## Read-Only Safety

`/plan` delegates to one plan-author `Planner` with `isolationMode "report"` and restricts it to a read-only planning tool allowlist. The Planner may inspect files, search the workspace, read project memory, query non-mutating Git state, and use web tools when available, but it must not edit files, run shell commands, or perform mutating Git, memory, todo, or task operations.

The built-in `/plan` read-only tool set includes local read/list tools, text utilities, search tools, non-mutating Git tools, read-only memory/task tools, and web search/fetch. The actual tools passed to the Planner are also filtered by the current parent session's enabled tools.

## Running A Plan

```text
/plan <goal>
/plan status
/plan approve
/plan clear
```

`ZenCODE` requires an explicit planning goal. If you run `/plan` without an argument, it reports the missing goal and does not create a Planner. A successfully authored plan is recorded in the current session as unapproved; a failed, cancelled, or empty planning turn does not replace the previous plan.

Pass the activity to plan as the command argument:

```text
/plan add support for archived memories in the memory search UI
/plan refactor TerminalChat command routing
/plan update docs and tests for the new Planner agent
```

The command requires the `sub-agents` tool group because it creates the delegated Planner. If it is unavailable, enable it with:

```text
/tools sub-agents
```

or switch to a profile that includes sub-agent delegation, such as `Default`.

## How Delegation Works

When `/plan` runs:

1. The current agent remains active only as the planning coordinator; it is explicitly forbidden from drafting, consolidating, or rewriting the plan.
2. The coordinator creates exactly one read-only sub-agent named `plan-author`, with role and profile `Planner`.
3. The Planner receives the complete goal, relevant conversation constraints, and the read-only planning tool list.
4. The Planner inspects the necessary context and writes the complete final plan, including ordered actionable points, likely files or areas, risks, open questions, and validation.
5. If the result is incomplete, the coordinator asks the same Planner to revise it instead of filling gaps itself.
6. The coordinator copies the Planner's numbered points and explicit dependencies into one `todo.write` bootstrap call. The TUI validates those points as a DAG, creates a persistent draft task graph, then takes the Planner's `latestOutput` directly, displays it, and records it as the active plan; any alternative plan text produced by the current agent is ignored. `todo.*` is not used for implementation progress after this bootstrap.
7. The Planner-authored plan and valid draft graph become the active, unapproved session plan. A later successful `/plan <goal>` archives the previous graph, replaces the plan, and requires approval again. If no completed Planner output or valid structured graph is available, the planning turn fails rather than falling back to a plan written by `Default` or another current profile.

## Planner Profile

Setup can create a built-in `Planner` profile in `~/.zencode/agents.json`. The default profile instruction is to perform read-only planning and produce concrete implementation guidance without editing files.

`/plan` prefers a user-configured profile named `Planner` from `agents.json`. If none is available, it falls back to the built-in default profile so the command can still run.

## Recommended Workflow

1. Start with a planning pass:

   ```text
   /plan <goal>
   ```

2. Explicitly approve the completed plan. Approval immediately starts implementation in the
   current agent profile and also makes the plan a review criterion:

   ```text
   /plan approve
   ```

   Use `/plan status` at any time to show the active plan as a table with one status per point. This command is local and does not require the `sub-agents` tool group.

   During implementation, the approved graph is the control plane. The model calls `task.list` for runnable work, uses `task.update` for direct coordinator attempts, and passes `taskID` to `agent.create` for atomic delegated claims. Dependencies gate execution; direct and delegated attempts retain output/error history. Successful report work can complete immediately, while delegated implementation stops at `awaiting_validation` until independently validated. `/plan status` projects these graph states into the plan table, and the TUI emits a compact graph overview as attempts change. Status is not inferred from free-form response text or from the presence of a diff.

   Use `/plan clear` when the active plan is no longer relevant. It archives the graph rather than erasing its history. The active plan and current task graph are preserved by v3 save/load snapshots and by automatic per-session graph checkpoints; a new logical session or agent switch interrupts workers and discards the graph. Older v2/legacy plans remain loadable without a graph.
3. ZenCODE implements the Planner-authored plan immediately with the current `Default`, `Xcode`, or other implementation profile; no additional prompt is required.
4. Validate with the planned build, test, lint, or diagnostic commands.
5. Run a read-only review of the tracked session changes and approved-plan coverage:

   ```text
   /review
   ```

6. Apply any corrections from the review, validate again, and repeat `/review` if needed. `/review` and `/undo` keep the approved plan active for this loop.

This creates the intended loop:

```text
/plan <goal> -> /plan approve -> implementation -> /review -> corrections -> /review
```
