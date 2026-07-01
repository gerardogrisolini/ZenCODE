# Planner Agent Guide

The `Planner` agent profile is the read-only planning profile included with `ZenCODE`. It is designed for delegated planning before implementation, not for editing files.

Use it through the `/plan` TUI command when you want an independent planning pass before starting or resuming work.

## What Planner Does

Planner sub-agents inspect only the context needed to make an implementation plan concrete. They should identify:

- the goal and assumptions;
- likely files, modules, or documentation areas to inspect or change;
- implementation phases and recommended order;
- dependencies, risks, edge cases, and open questions;
- validation commands or manual checks;
- when to run `/review` after implementation.

## Read-Only Safety

`/plan` delegates with `isolationMode "report"` and restricts Planner sub-agents to a read-only planning tool allowlist. Planners may inspect files, search the workspace, read project memory, query non-mutating Git state, and use web tools when available, but they must not edit files, run shell commands, or perform mutating Git, memory, todo, or task operations.

The built-in `/plan` read-only tool set includes local read/list tools, text utilities, search tools, non-mutating Git tools, read-only memory/task tools, and web search/fetch. The actual tools passed to a Planner are also filtered by the current parent session's enabled tools.

## Running A Plan

```text
/plan <goal>
```

`ZenCODE` requires an explicit planning goal. If you run `/plan` without an argument, it reports the missing goal and does not create Planner sub-agents.

Pass the activity to plan as the command argument:

```text
/plan add support for archived memories in the memory search UI
/plan refactor TerminalChat command routing
/plan update docs and tests for the new Planner agent
```

The command requires the `orchestration` tool group because it creates sub-agents. If it is unavailable, enable it with:

```text
/tools orchestration
```

or switch to a profile that includes sub-agent delegation, such as `Default`.

## How Delegation Works

When `/plan` runs:

1. The current agent remains the planning director and does not switch profiles.
2. The director creates one or more sub-agents with role `Planner`.
3. Each Planner receives a focused planning prompt and the read-only planning tool list.
4. Planners run in parallel when the planning surface can be partitioned by module, concern, risk, or validation area.
5. The director waits for the Planners, consolidates overlapping recommendations, and returns one actionable plan.
6. The director does not edit files as part of the planning turn.

## Planner Profile

Setup can create a built-in `Planner` profile in `~/.zencode/agents.json`. The default profile instruction is to perform read-only planning and produce concrete implementation guidance without editing files.

`/plan` prefers a user-configured profile named `Planner` from `agents.json`. If none is available, it falls back to the built-in default profile so the command can still run.

## Recommended Workflow

1. Start with a planning pass:

   ```text
   /plan <goal>
   ```

2. Use the consolidated plan to implement the work with the normal `Default`, `Xcode`, or other implementation profile.
3. Validate with the planned build, test, lint, or diagnostic commands.
4. Run a read-only review of the tracked session changes:

   ```text
   /review
   ```

5. Apply any corrections from the review, validate again, and repeat `/review` if needed.

This creates the intended loop:

```text
/plan -> implementation work -> /review -> corrections -> validation
```
