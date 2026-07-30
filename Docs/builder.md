# Builder Agent Guide

The `Builder` profile creates and manages reusable Dynamic Swift Features. Use it when the agent needs a durable tool or integration available in later sessions — not for one-off file edits.

## Starting Builder

```bash
zen --agent Builder          # launch directly
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
/feature reload              # manual refresh after external changes/discovery
/feature delete <id|name|#>  # generated packages or local bundled copies only
```

## Creating A Feature

Run `/feature` to start the wizard. This remains the single entry point for both
new Swift tools and MCP bridges; there are no separate creation subcommands.
The wizard asks for the goal first, then the template and metadata, and
scaffolds a Swift package under `~/.zencode/features/<feature-id>/`:

```text
feature.json
Package.swift
Sources/<FeatureTarget>/main.swift
```

Generated packages are plain Swift 6.3 packages. They run out of process: the kernel starts the executable, sends JSON on stdin, expects JSON on stdout.

Generated tools use the same contracts as bundled tools: basic scaffolds conform
to `FeatureTool` and run through `FeatureRunner`, while every tool publishes an
explicit `ToolPresentationDefinition` from its own feature source. The
`--list-tools` response carries that definition; ZenCODECore does not infer
presentation rules from a tool name. MCP Bridge scaffolds likewise attach their
feature-owned presentation metadata to every discovered MCP descriptor.
Current Builder manifests and `--list-tools` responses use schema version 2,
which requires a semantically valid presentation definition for every tool.
Version 1 payloads remain readable for compatibility, but their missing
metadata stays absent rather than being replaced by an inferred rule.

Templates:

- **Basic Swift Feature** (default) — creates one disabled starter tool. Builder
  implements the real behavior before the first validation and build. The
  placeholder is never enabled or exposed.
- **MCP Bridge** — forwards tool calls to an HTTP or stdio MCP server. The
  configured bridge is validated and built immediately; if requested, it is
  enabled and selected only after that build succeeds.

For a Basic Feature, the wizard prepares an implementation prompt and starts it
immediately when requirements were supplied; an empty goal leaves the prompt
ready for review. For a successfully built MCP Bridge no second implementation
prompt is needed. If its validation or build fails, Builder receives a repair
prompt and the disabled scaffold remains available for inspection.

## Typical Workflow

1. Run `/feature` and describe the reusable capability.
2. For a Basic Feature, Builder implements the disabled scaffold.
3. Builder runs `feature.validate`, fixes errors, then runs `feature.build`.
4. Builder enables the package only after both operations succeed, when that
   option was selected in the wizard.
5. Use `/tools` to expose a completed Basic Feature in the current session.

For an MCP Bridge, steps 2–4 happen inside the wizard. When activation was
requested and the initial build succeeds, the bridge is also selected for the
current session. If the initial build needs a Builder repair, automatic
selection is not claimed: after the repair, use `/tools` explicitly.

After editing a feature, repeat validate → build. A successful `feature.build`
already reloads the feature runtime. Use `/feature reload` only after external
file changes or when runtime-discovered tools need to be refreshed.

## Enabling vs Exposing

Two separate steps:

- **Enable** (`/feature list` or `/feature enable`) makes a package available to ZenCODE.
- **Expose** (`/tools`) decides whether the model can call its tools in the current session.

Builder's own lifecycle tools (`feature.scaffold`, `feature.build`) are intrinsic to the agent and not selectable through `/tools`.

## MCP Configuration And Secrets

HTTP endpoint URLs must not contain usernames, passwords, tokens, API keys, or
other credentials. The wizard rejects common credential-bearing URL forms.

For stdio MCP servers, the generated bridge inherits the environment of the
`zen` process. Configure sensitive values before launching `zen` or through the
integration's dedicated secure setup; the wizard deliberately does not collect
`KEY=value` pairs, and `feature.scaffold` rejects non-empty `environment`/`env`
values so they cannot be emitted into generated Swift source.

## Editing Existing Features

```text
/feature edit <id|name|#> [requirements]
```

- **Generated feature**: opens the existing package and prepares an implementation prompt.
- **Bundled feature**: creates a local editable copy in `~/.zencode/features/`, then prepares the same prompt.

For `xcode-tools` (bundled multi-target feature), edit the feature-owned implementation under `Sources/Features/XcodeTools/Sources/XcodeToolsFeature`, not shared `ToolCore` or `FeatureMCPBridgeKit`.

Local copies keep the same feature id and shadow the bundled package. `/feature delete` removes the local copy and restores the bundled package.

## Bundled Integrations

Bundled feature packages can include Search, Web, Git, Swift, Xcode, Figma, and Jira. They can be enabled directly or copied for local editing.

Core tools (shell, files, text, memory, sub-agents) are **not** feature packages — manage them through `/tools`, not `/feature`.

Some integrations need extra configuration. For example, Jira runs setup automatically on the first `jira.search` or `jira.read` call when no token is stored; `/feature enable jira-tools` only toggles package state and does not run authentication.
