# ZenCODE Documentation

Guides for using, extending, and maintaining ZenCODE. Start with the
[project README](../README.md) for installation.

## Getting started

| Guide | Read it for |
| --- | --- |
| [why-zen.md](why-zen.md) | Why the project exists and how it differs from other agents |
| [zen.md](zen.md) | Modes, CLI options, TUI commands, sessions, task orchestration |

## Agents and delegation

| Guide | Read it for |
| --- | --- |
| [agents.md](agents.md) | Agent profiles, tool groups, sub-agent lifecycle, task graph |
| [bindings.md](bindings.md) | Agent/model/workflow bindings, capability routing, `/bindings` |
| [builder.md](builder.md) | Creating Dynamic Swift Features with `/feature` |
| [planner.md](planner.md) | Read-only planning with `/plan` |
| [reviewer.md](reviewer.md) | Read-only code review with `/review` |
| [reporter.md](reporter.md) | Evidence-based code analysis and reports |

## Integrations

| Guide | Read it for |
| --- | --- |
| [xcode.md](xcode.md) | Running `zen` as an ACP coding agent in Xcode 27 |
| [aion-ui.md](aion-ui.md) | Registering ZenCODE as an Aion UI custom agent |

## Project and maintenance

| Guide | Read it for |
| --- | --- |
| [architecture.md](architecture.md) | Layout contract, module boundaries, dependency direction, validation gates |
| [release.md](release.md) | Release checklist and reproducible installs |
| [security.md](security.md) | Protection model for persisted credentials |

## Suggested reading order

1. [why-zen.md](why-zen.md) — decide if ZenCODE fits your workflow.
2. [zen.md](zen.md) — set up and drive the agent day to day.
3. [agents.md](agents.md) and [bindings.md](bindings.md) — configure profiles and
   delegation before using `/plan`, `/workflow`, or `/review`.
4. The profile guide matching the work you delegate.
5. [architecture.md](architecture.md) — before changing the codebase itself.
