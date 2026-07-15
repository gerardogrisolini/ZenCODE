# Builder Agent Guide

The `Builder` profile creates and manages reusable Dynamic Swift Features. Use it when the agent needs a durable tool or integration available in later sessions — not for one-off file edits.

## Starting Builder

```bash
zen --agent Builder          # launch directly
zen --mlx --agent Builder    # fully local MLX runtime
/agents Builder              # switch inside an existing TUI session
```

Switching agents resets the conversation so the Builder system prompt and intrinsic feature-management tools apply cleanly.

## Feature Commands

```text
/feature                     # wizard: scaffold a new feature package
/feature list                # checkbox menu: enable/disable packages
/feature status              # textual package inventory
/feature enable <id|name|#>
/feature disable <id|name|#>
/feature edit <id|name|#> [requirements]
/feature build <id|name|#>
/feature validate <id|name|#>
/feature reload              # refresh after rebuilding an enabled feature
/feature delete <id|name|#>  # generated packages or local bundled copies only
```

## Creating A Feature

Run `/feature` to start the wizard. It asks for a template and metadata, then scaffolds a Swift package under `~/.zencode/features/<feature-id>/`:

```text
feature.json
Package.swift
Sources/<FeatureTarget>/main.swift
```

Generated packages are plain Swift 6.3 packages. They run out of process: the kernel starts the executable, sends JSON on stdin, expects JSON on stdout.

Templates:

- **Basic Swift feature** — one starter tool.
- **MCP Bridge** — forwards tool calls to an HTTP or stdio MCP server.

When the wizard finishes, Builder prepares an implementation prompt and can start implementing immediately if you provided requirements.

## Typical Workflow

1. `/feature` to scaffold.
2. Builder implements or edits the generated Swift code.
3. `/feature validate <id|name|#>`.
4. `/feature build <id|name|#>`.
5. `/feature enable <id|name|#>`.
6. `/tools` to expose the package in the current session.

After editing any feature, repeat validate → build → reload (if already enabled) → `/tools`.

## Enabling vs Exposing

Two separate steps:

- **Enable** (`/feature list` or `/feature enable`) makes a package available to ZenCODE.
- **Expose** (`/tools`) decides whether the model can call its tools in the current session.

Builder's own lifecycle tools (`feature.scaffold`, `feature.build`) are intrinsic to the agent and not selectable through `/tools`.

## Editing Existing Features

```text
/feature edit <id|name|#> [requirements]
```

- **Generated feature**: opens the existing package and prepares an implementation prompt.
- **Bundled feature**: creates a local editable copy in `~/.zencode/features/`, then prepares the same prompt.

For `xcode-tools` (bundled multi-target feature), edit the feature-owned implementation under `Sources/XcodeTools/Feature`, not shared `ToolCore` or `FeatureMCPBridgeKit`.

Local copies keep the same feature id and shadow the bundled package. `/feature delete` removes the local copy and restores the bundled package.

## Bundled Integrations

Bundled feature packages can include Search, Web, Git, Swift, Xcode, Figma, and Jira. They can be enabled directly or copied for local editing.

Core tools (shell, files, text, memory, sub-agents) are **not** feature packages — manage them through `/tools`, not `/feature`.

Some integrations need extra configuration. For example, Jira runs setup automatically on the first `jira.search` or `jira.read` call when no token is stored; `/feature enable jira-tools` only toggles package state and does not run authentication.
