# Reporter Agent Guide

The `Reporter` profile analyzes code and produces structured, evidence-based reports. It is designed for investigation and documentation, not implementation.

Unlike the `Reviewer`, which evaluates a change surface for defects, the `Reporter` explains how code works: architecture, dependencies, control and data flows, APIs, configuration, tests, and likely change impact.

## What Reporter Does

Reporter sub-agents inspect the requested code surface and report:

- architecture and module boundaries;
- dependencies and dependency directions;
- control and data flows;
- public APIs, configuration, and persisted formats;
- test coverage and implementation status;
- likely impact of a proposed change.

Reports distinguish verified facts from inferences and cite important evidence with `file:line` references.

## Selecting Reporter

The `Reporter` is a standard profile — select it directly or delegate to it:

```text
/agents Reporter                         # switch to the Reporter profile
zen --agent Reporter --cwd /path/to/proj  # launch directly
```

As a coordinator, delegate focused analysis to a `Reporter` sub-agent with `agent.create`, optionally narrowing its tools with `toolNames`. Because its toolset is intentionally minimal (`files`, search, text, Git), the Reporter stays scoped to investigation and reporting.

## Tools

The `Reporter` toolset is minimal and investigation-focused:

- `files` — read and inspect source files;
- search — locate symbols, references, and patterns;
- `text` — focused reads and text analysis;
- Git — history, blame, and diff context.

It intentionally excludes `shell`, `sub-agents`, memory, and web so reports stay grounded in the current project state.

## Capability Routing

`Reporter` is role-compatible with evidence-based analysis and reporting tasks. After filtering by role, constraints, and required tool access, the coordinator compares the task complexity with `Reporter`'s configured capability. See [agents.md](agents.md) for the complete selection policy.

## When To Use Reporter

- **Explain unfamiliar code** before planning a change.
- **Document architecture** for a module or subsystem.
- **Trace a data flow** or dependency chain across files.
- **Assess change impact** by citing the code that would be affected.

Pair it with `Planner` (`/plan`) when investigation should precede an implementation plan, or with `Reviewer` (`/review`) when you need both an explanation and a defect assessment.
