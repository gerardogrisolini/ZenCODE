# Builder Agent Guide

The Builder agent is the `ZenCODE` profile dedicated to creating and managing
reusable Dynamic Swift Features. Use it when the agent needs a durable tool or
integration that should be available in later sessions, not for one-off file
edits or simple shell commands.

Builder can:

- scaffold new Swift feature packages;
- build and validate generated feature packages;
- prepare existing generated packages for editing;
- prepare local editable copies of bundled feature packages;
- enable, disable, reload, or delete feature packages;
- configure bundled feature packages such as Jira;
- expose generated and bundled feature packages to normal sessions through the
  same tool-selection flow used by `/tools`.

## Starting Builder

Start directly with Builder:

```bash
zen --agent Builder
```

Or use the fully local MLX runtime:

```bash
zen --mlx --agent Builder
```

Inside an existing TUI session, switch to Builder with:

```text
/agents Builder
```

Switching agents resets the active conversation so the Builder system prompt and
intrinsic feature-management tools are applied cleanly.

## Feature Commands

Builder exposes one feature command with several subcommands:

```text
/feature
```

`/feature` create, enable, disable, edit, build, validate, reload,
and list feature packages.

`/feature list` opens the checkbox menu for enabling or disabling available
feature packages. `/feature status` prints the same package inventory as text.

After a feature package is enabled, use `/tools` to decide whether its tools are
exposed to the current model session.

## Creating A Feature

Use the wizard:

```text
/feature
```

The wizard asks for a template and basic metadata, then scaffolds a Swift package
under:

```text
~/.zencode/features/<feature-id>/
```

The generated package contains:

```text
feature.json
Package.swift
Sources/<FeatureTarget>/main.swift
```

Generated packages are plain Swift 6.3 packages. They run out of process; the
kernel starts the compiled executable, sends JSON on stdin, and expects a JSON
response on stdout.

The wizard can create:

- a basic Swift feature with one starter tool;
- an MCP bridge feature that forwards tool calls to an HTTP or stdio MCP server.

When the wizard finishes, Builder prepares an implementation prompt. If you
provided requirements, Builder can start implementing immediately; otherwise it
prefills the prompt so you can review or edit it first.

## Managing Features

Use these commands from the Builder agent:

```text
/feature list
/feature status
/feature enable <id|name|#>
/feature disable <id|name|#>
/feature edit <id|name|#> [requirements]
/feature build <id|name|#>
/feature validate <id|name|#>
/feature reload
/feature delete <id|name|#>
```

Typical generated-feature flow:

1. Run `/feature` to scaffold the package.
2. Let Builder implement or edit the generated Swift code.
3. Run `/feature validate <id|name|#>`.
4. Run `/feature build <id|name|#>`.
5. Run `/feature enable <id|name|#>`.
6. Run `/tools` and select the package if you want its tools exposed in the
   current session.

Use `/feature reload` after rebuilding an already enabled feature when the
runtime needs to refresh manifests or runtime-discovered tools.

Use `/feature delete <id|name|#>` only for generated packages or local editable
copies of bundled packages you want to remove. For bundled copies, delete
removes the local copy and the original bundled package becomes visible again.

## Editing Existing Features

Use Builder to edit an existing generated or bundled feature:

```text
/feature edit <id|name|#> [requirements]
```

For a generated feature, `/feature edit` opens the existing package and prepares
an implementation prompt that points Builder at the manifest, package file, and
Swift sources.

For a bundled feature, `/feature edit` first creates a local editable copy in the
generated feature root, then prepares the same edit prompt.

Local copies keep the same feature id as the bundled package. While the local
copy exists, it shadows the bundled package with that id. Removing the local copy
with `/feature delete <id|name|#>` restores the bundled package.

Bundled feature packages can be enabled, disabled, and edited through local
copies when their source is available. Core tools such as shell, file/text tools,
memory, and sub-agents are not feature packages and are managed through `/tools`,
not `/feature`.

After editing any feature:

1. Run `/feature validate <id|name|#>`.
2. Run `/feature build <id|name|#>`.
3. Run `/feature reload` if the feature was already enabled.
4. Run `/tools` if you need to expose or refresh the package in the current
   session.

## Enabling Packages

Use:

```text
/feature list
```

This opens the enable/disable menu with checkboxes. It lists bundled feature
packages and generated packages together. Select with Space, confirm with Enter,
or cancel with Esc/Q.

The menu is intentionally quiet: after a change it prints only the direct
enable/disable result, such as:

```text
Feature 'jira-tools' enabled.
```

Use `/feature status` when you want the textual package list instead of the
interactive menu.

## Exposing Tools To The Model

Enabling a package makes it available to `ZenCODE`; it does not necessarily
expose every tool in the current model session.

Use:

```text
/tools
```

The `/tools` picker lists enabled feature packages alongside core tool groups.
Select the package there when you want the model to call its tools in the
current session.

Builder's own lifecycle tools, such as `feature.scaffold` and `feature.build`,
are intrinsic to the Builder agent. They are not selectable through `/tools` and
are not exposed by normal profiles.

## Bundled Integrations

Bundled feature packages can include Search, Web, Git, Swift, Xcode, Figma, and Jira.
Availability depends on the local environment and on whether a package discovers
tools at runtime.

Bundled packages are optional feature packages. They can be enabled directly, or
copied into `~/.zencode/features/<feature-id>/` when you want a local editable
copy.

Core tools are the intrinsic tool groups exposed through `/tools`, such as shell,
file/text tools, memory, and sub-agents. They are not feature packages and do not
appear in `/feature list`.

Some bundled integrations need extra configuration. For Jira, run:

```text
/feature enable jira-tools
```

That command runs the Jira configuration flow when needed. `/feature list` only
toggles package state and does not run interactive configuration prompts.

After configuring and enabling a bundled package, run `/tools` if you want to
expose it to the current session.

## MCP Bridge Features

Choose the MCP Bridge template when you want a generated feature to wrap an
external MCP service.

The wizard asks for:

- service name;
- stable tool prefix;
- transport type: HTTP or stdio;
- endpoint URL for HTTP, or executable path and arguments for stdio.

The generated bridge uses `--list-tools` to discover MCP tools and
`--invoke <tool>` to forward model calls. Use a stable prefix so the runtime can
route calls before full runtime discovery.

## When To Use Builder

Good Builder tasks:

- wrap a local service or CLI as a reusable tool;
- add a project-specific integration that will be used across sessions;
- package a repeated workflow behind a typed JSON schema;
- create an MCP bridge for an existing MCP service;
- fix, validate, or rebuild an existing generated feature;
- customize a bundled integration through a local editable copy.

Poor Builder tasks:

- one-time shell commands;
- ordinary source edits in the current project;
- simple searches or file reads;
- temporary scripts that do not need to become reusable tools.

For ordinary implementation work, use the normal Feature or Default agent with
the right `/tools` selection.

## Technical Notes

These notes describe the feature package contract. They are not the normal
operating flow for using Builder in the TUI.

### Discovery

Dynamic features are small Swift executables launched by the `ZenCODE`
runtime. They are discovered from:

- bundled feature binaries next to the `zen` executable;
- generated feature packages under `~/.zencode/features`.

Generated packages have precedence over bundled packages with the same id. That
is how local editable copies shadow their bundled source. Generated packages cannot
override intrinsic core tool namespaces such as `local.*`, `text.*`, or
`feature.*`.

The runtime never loads feature code in process. It starts the compiled
executable, sends JSON on stdin, and expects a JSON response on stdout.

### Package Layout

Generated feature packages use this layout:

```text
~/.zencode/features/<feature-id>/
  feature.json
  Package.swift
  Sources/<FeatureTarget>/main.swift
  .build/release/<feature-binary>
```

Every generated `Package.swift` must start with:

```swift
// swift-tools-version: 6.3
```

The executable should use `FeatureKit` and support:

```text
<feature-binary> --list-tools
<feature-binary> --invoke <tool-name> --working-directory <path>
```

`FeatureRunner.run(...)` implements that process protocol for bundled
features. Generated scaffolds may use the same helper or implement the small
protocol directly. The `mcp-bridge` scaffold adds a local package dependency on
`ZenCODE` so it can reuse the Swift MCP client.

### Manifest

`feature.json` is the runtime contract. The current schema is version 1 and is
backward compatible with the original minimal manifest.

```json
{
  "schemaVersion": 1,
  "id": "example-feature",
  "displayName": "Example Feature",
  "description": "Short human-readable summary.",
  "enabled": true,
  "executable": ".build/release/example-feature",
  "discoversToolsAtRuntime": false,
  "toolNamePrefixes": ["example."],
  "toolNameAliases": [],
  "build": {
    "system": "swiftpm",
    "packagePath": ".",
    "product": "example-feature",
    "configuration": "release",
    "executablePath": ".build/release/example-feature"
  },
  "generated": {
    "by": "ZenCODE",
    "prompt": "Original user or agent request.",
    "createdAt": "2026-05-30T12:00:00Z"
  },
  "tools": [
    {
      "name": "example.echo",
      "description": "Echoes text.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "text": { "type": "string" }
        },
        "required": ["text"]
      }
    }
  ]
}
```

Required fields:

- `id`: stable feature identifier.
- `executable`: path to the executable, relative to `feature.json` unless
  absolute.
- `tools`: static tool descriptors. Use an empty array when the feature
  discovers tools dynamically.

Optional fields:

- `schemaVersion`: schema version; omit for legacy manifests.
- `enabled`: whether the runtime should load the feature; defaults to `true`
  when omitted.
- `displayName`, `description`: shown by `feature.list`.
- `discoversToolsAtRuntime`: when true, the runtime calls `--list-tools` only
  when the feature is relevant to selected tools.
- `toolNamePrefixes`: prefixes used to route dynamic tools before the runtime
  has listed them.
- `toolNameAliases`: exact non-prefixed tool names accepted by the feature.
- `build`: SwiftPM build metadata.
- `generated`: provenance metadata from the agent.

### Runtime Rules

- `local.exec`, `local.*` file tools, and `text.*` tools are core tools and must
  not be implemented by a feature.
- Bundled features are enabled or disabled through
  `~/.zencode/feature-state.json`.
- Generated features are enabled or disabled by updating their own
  `feature.json`.
- Bundled feature ids cannot be deleted directly; disable them with
  `/feature list` or `/feature disable <id|name|#>`.
- `feature.edit` returns the editable package context for generated packages; for
  bundled packages it first creates a local editable copy.
- `feature.reload` reloads manifests and clears runtime-discovered tool caches.
- `feature.scaffold` creates SwiftPM packages only under the generated features
  root. Packages prepared elsewhere are installed through `feature.install`.
- `feature.validate` checks manifest shape, reserved tool names, duplicate tool
  names, executable state, and SwiftPM tools version.
- `feature.build` runs `swift build -c release --product <product>` for SwiftPM
  feature packages and reloads the runtime when the executable is produced.
- `feature.install` copies a generated feature package into
  `~/.zencode/features/<feature-id>`, skips transient folders such as
  `.build`, validates it, builds it by default, and enables it by default when
  the build succeeds.
- Generated tool names must stay out of the reserved `feature.*` namespace and
  must never shadow core tools such as `local.exec`, `local.readFile`, or
  `text.wc`.

## Troubleshooting

- `/feature` is unknown: switch to Builder with `/agents Builder`.
- `/feature` starts the creation wizard; `/feature list` opens the
  enable/disable menu.
- A feature is enabled but not callable: run `/tools` and select its package.
- A generated feature is listed but unavailable: run `/feature build <id|name|#>`
  and then `/feature validate <id|name|#>`.
- Runtime-discovered tools are missing after a rebuild: run `/feature reload`.
- Jira says it is not configured: run `/feature enable jira-tools`.
