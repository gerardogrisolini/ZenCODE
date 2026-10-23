# ZenCODE Documentation

Guides for using, extending, and maintaining ZenCODE. Start with the
[project README](../README.md) for installation.

## Getting started

| Guide | Read it for |
| --- | --- |
| [why-zen.md](why-zen.md) | Why the project exists and how it differs from other agents |
| [zen.md](zen.md) | Modes, CLI options, TUI commands, sessions, task orchestration, and project memory |
| [jsonl.md](jsonl.md) | Versioned headless JSONL protocol, lifecycle records, errors, privacy, and consumer examples |

## Agents and delegation

| Guide | Read it for |
| --- | --- |
| [agents.md](agents.md) | Agent profiles, tool groups, sub-agent lifecycle, task graph |
| [bindings.md](bindings.md) | Agent/model/workflow bindings, capability routing |
| [builder.md](builder.md) | Creating Dynamic Swift Features with `/feature` |
| [planner.md](planner.md) | Read-only planning with `/plan`, including `/plan save` and `/plan load` handoffs |
| [reviewer.md](reviewer.md) | Read-only code review with `/review` |
| [reporter.md](reporter.md) | Evidence-based code analysis and reports |

## Integrations

| Guide | Read it for |
| --- | --- |
| [xcode.md](xcode.md) | Running `zen` as an ACP coding agent in Xcode 27 |
| [ds4.md](ds4.md) | Folder-only DS4 setup, compatibility checks, ownership, and supported integration levels |
| [voice.md](voice.md) | Voice mode (`/voice`) and Telegram voice messages on macOS and Linux: setup, language, privacy, troubleshooting |

## Project and maintenance

| Guide | Read it for |
| --- | --- |
| [architecture.md](architecture.md) | Layout contract, module boundaries, dependency direction, validation gates |
| [memory.md](memory.md) | Durable memory ownership, retrieval, embeddings, recall, and persisted graph format |
| [release.md](release.md) | Release checklist and reproducible installs |
| [security.md](security.md) | Protection model for persisted credentials |
| [editing-tool-size-baseline.md](editing-tool-size-baseline.md) | Size baseline enforced by the local editing-tool contract tests |

## Suggested reading order

1. [why-zen.md](why-zen.md) — decide if ZenCODE fits your workflow.
2. [zen.md](zen.md) — set up and drive the agent day to day.
3. [agents.md](agents.md) and [bindings.md](bindings.md) — configure profiles and
   delegation for `/plan`, `/review`, or optional delegation during `/goal`.
   `/goal` also works directly without sub-agent tools, retaining its task graph.
4. The profile guide matching the work you delegate.
5. [architecture.md](architecture.md) — before changing the codebase itself.

This index is the single catalogue of ZenCODE documentation; the project README
links here instead of repeating it.

- [Authenticated subscription catalogs](subscription-catalogs.md): setup discovery,
  account-scoped last-success cache, metadata and Anthropic live-validation limits.
