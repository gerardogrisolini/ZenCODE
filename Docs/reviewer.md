# Reviewer Agent Guide

The `Reviewer` agent profile is the read-only code review profile included with `ZenCODE`. It is designed for delegated review, not implementation.

Use it through the `/review` TUI command when you want independent review feedback before applying fixes or committing changes.

## What Reviewer Does

Reviewer sub-agents inspect the current project and report findings. They should look for:

- correctness bugs and regressions;
- security, privacy, or concurrency issues;
- missing or weak tests;
- style, architecture, or project-convention violations;
- unclear behavior that should be documented or validated.

Findings should include severity and concrete `file:line` references whenever possible.

## Read-Only Safety

`/review` delegates with `isolationMode "report"` and restricts Reviewer sub-agents to a read-only tool allowlist. Reviewers may inspect files and search the codebase for context, but they must review only the tracked file changes made during the current session and must not edit files or run mutating commands.

The built-in `/review` read-only tool set includes local read/list tools, text utilities, and search tools. It intentionally excludes git and memory tools so an unscoped review cannot expand beyond the current session changes.

## Running A Review

From an interactive TUI session, use:

```text
/review
```

With no argument, `ZenCODE` reviews only the latest tracked file changes from the current session. If the session has no tracked file changes, `/review` exits without delegating. You can pass an optional focus, but it is applied only within those session changes.

To focus the session-change review on a specific area, pass a focus:

```text
/review Sources/ZenCODECore/ZenCODETUI/Chat
/review check the saved-session restore path and related tests
/review only the documentation updates
```

The command requires the `orchestration` tool group because it creates sub-agents. If it is unavailable, enable it with:

```text
/tools
```

or switch to a profile that includes orchestration.

## How Delegation Works

When `/review` runs:

1. The current agent remains the review director and does not switch profiles.
2. The director creates one or more sub-agents with role `Reviewer`.
3. Each Reviewer receives a focused review prompt and the read-only tool list.
4. Reviewers run in parallel when the review surface can be partitioned by file, module, or concern.
5. The director waits for the reviewers, consolidates duplicate findings, and summarizes issues by severity.
6. If changes are warranted, the director proposes a concrete correction plan instead of editing files in the review turn.

## Reviewer Profile

Setup can create a built-in `Reviewer` profile in `~/.zencode/agents.json`. The default profile instruction is to perform read-only code review and report concrete findings without editing files. When used by `/review`, the profile is constrained to the current session change surface.

`/review` prefers a user-configured profile named `Reviewer` from `agents.json`. If none is available, it falls back to the built-in default profile so the command can still run.

## Recommended Workflow

1. If the work is non-trivial, start with `/plan <goal>` to get a delegated Planner pass.
2. Implement or update files with the normal `Default`, `Xcode`, or other implementation profile.
3. Inspect the local change summary:

   ```text
   /changes diff
   ```

4. Run a review of the tracked session changes:

   ```text
   /review
   ```

5. Read the consolidated findings and correction plan.
6. Decide whether to apply the proposed fixes in a separate implementation turn.
7. Validate with the relevant build, test, or lint command before committing.
