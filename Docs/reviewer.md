# Reviewer Agent Guide

The `Reviewer` profile is the read-only code review profile. It is designed for delegated review, not implementation.

Use it through `/review` when you want independent review feedback before applying fixes or committing.

## What Reviewer Does

Reviewer sub-agents inspect the current project and report:

- correctness bugs and regressions;
- security, privacy, or concurrency issues;
- missing or weak tests;
- style, architecture, or convention violations;
- unclear behavior that should be documented or validated.

Findings include severity and concrete `file:line` references.

## Running A Review

```text
/review                              # review tracked session changes
/review Sources/ZenCODECore/ZenCODETUI/Chat   # focus on a path
/review check the session restore flow          # focus on a concern
```

With no argument, `/review` reviews the latest tracked file changes. If a task graph or approved plan exists, it also verifies every task/plan claim against current files and actual validation output, classifying each as `implemented`, `validated`, `unverified`, `failed`, `deviated`, `cancelled`, or `blocked`.

A graph or approved plan enables coverage-only review even without tracked changes. With no inputs, `/review` exits with `No tracked session file changes to review.`

Requires the `sub-agents` tool group. Enable it with `/tools sub-agents` or switch to a profile that includes it.

## Read-Only Safety

`/review` delegates with `isolationMode "report"` and a read-only tool allowlist: local read/list, text, and search tools. It intentionally excludes Git and memory tools so a review cannot expand beyond the current session changes.

## How Delegation Works

1. The current agent remains the review director — it does not switch profiles.
2. With an active task graph, the director adds one independent review task per `Reviewer`, including a focused reviewer, then selects runnable work. Without a graph, a single focused review can create a `Reviewer` directly.
3. Each Reviewer receives a focused prompt, the read-only tool list, and a `taskID` for graph work.
4. Independent reviews run in parallel when the surface can be partitioned by file, module, or concern.
5. At least one coverage Reviewer verifies task/plan claims against current files when a graph or plan exists.
6. The director consolidates findings and summarizes by severity plus task/plan coverage.
7. If changes are warranted, the director proposes a correction plan — it does not edit files in the review turn.
