# Builder Agent Guide

The `Builder` profile creates and manages reusable Dynamic Swift Features. Use it when the agent needs a durable tool or integration available in later sessions — not for one-off file edits.

What makes a profile a builder is its `builder` role, never its ID or name: any profile with that role can use `/feature` and receives the intrinsic feature-management tools. The recommended `Builder` is the system profile with ID `builder`. See [agents.md](agents.md#profile-roles).

You start Builder yourself, as described below, or an agent can do it for you: an agent whose session has the `sub-agents` tool can delegate the construction of a missing tool to a Builder sub-agent and use the result at once, without switching agents. See [Autonomous Feature Development](#autonomous-feature-development).

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
/feature promote <id|name|#> (--linux|--no-linux) [--repository path] [--overwrite]
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

Generated packages are plain Swift 6.4 packages. They run out of process: the kernel starts the executable, sends JSON on stdin, expects JSON on stdout.

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

After editing a generated package and running validate → build, use
`/feature promote <id> --linux --repository /path/to/ZenCODE` to prepare a source
checkout contribution. Promotion requires a non-detached Git branch, runs a
build and `--list-tools` preflight, copies only source/package files into
`Sources/Features/<PascalCaseId>`, writes `feature-distribution.json`, and
updates the catalogs transactionally. `feature.json`, build products, symlinks,
and Git metadata are never copied; `Package.resolved` is preserved so standalone
CI can resolve from an immutable lockfile. The command only changes the
working tree; it never commits, pushes, or creates a pull request. Unrelated
working-tree changes are allowed, but controlled package/catalog paths must be
clean (or explicitly replaced with `--overwrite`).


## Enabling vs Exposing

Two separate steps:

- **Enable** (`/feature list` or `/feature enable`) makes a package available to ZenCODE.
- **Expose** (`/tools`) decides whether the model can call its tools in the current session.

Builder's own lifecycle tools (`feature.scaffold`, `feature.build`) are intrinsic to the agent and not selectable through `/tools`.

There is one exception to the two steps. A generated feature that a Builder sub-agent built for the session that delegated it is exposed to that session automatically, without `/tools`; a `/tools` selection can still revoke it. A bundled or optional feature never takes this path. See [Autonomous Feature Development](#autonomous-feature-development).

## Autonomous Feature Development

The model can have a tool it lacks built without you switching to Builder. When the work needs a reusable tool that none of its tools provides, it delegates the construction to a Builder sub-agent with `agent.create`, waits for it, and calls the new tool in the same turn: no `/agents Builder`, no `/feature`, no `/tools`.

**Conditions.** Both must hold:

- The session has the `sub-agents` tool.
- The project sees a delegatable profile with the `builder` role: one associated with the project (see [Project Agents](agents.md#project-agents)) and listed among the delegatable profiles (see [What The Model Sees](bindings.md#what-the-model-sees)). The role is what counts, never the ID or the name, so a custom profile with the `builder` role qualifies as much as the recommended `Builder`.

When they hold, the coordinator's system prompt ends the roster of delegatable profiles with a *Developing a missing tool* paragraph; a coordinator that delegates by role, such as `Organizer`, gets it at the end of its *Delegation by role* section, where the Builder is `profileRole: "builder"`. The paragraph tells the model to delegate only a durable capability, to state in the prompt the capability, the expected tool name, its inputs and outputs, and every constraint, never to ask for credentials to be embedded, and to do one-off work with the tools it already has.

**Flow.** The Builder sub-agent gets a *Delegated feature development* section in its system prompt. No `/feature` wizard and no operator are at its prompt, so it runs the whole workflow with the `feature.*` tools, and the section takes precedence over any profile instruction that hands a step to the operator or to `/tools`:

1. `feature.list`: when a generated feature already provides the capability, reuse it instead of creating a duplicate: change it with `feature.edit` if needed, then run `feature.validate` and `feature.build` on it anyway and make sure it is enabled, because only a feature the Builder builds in this delegation is exposed. When a bundled or optional feature provides the capability, it rebuilds nothing and reports that you have to select it with `/tools`. `feature.list` marks a catalog feature with a `source` of `bundled` or, once it is installed or copied locally, with an `adoptedFrom` value.
2. `feature.scaffold`, leaving the scaffold disabled and with a tool name in a namespace of its own (see **Namespace** below). For an MCP server it uses the `mcp-bridge` template, which is available on macOS only.
3. Implement the real behavior in the generated package.
4. `feature.validate`, then `feature.build`, fixing every error.
5. `feature.enable`, only after both succeed.
6. A final report with the feature id and, for each tool, its name, its arguments, and an example call. When it cannot finish, it leaves the feature disabled and reports the blocker.

The section is added for every sub-agent whose profile has the `builder` role and whose tool grant includes `feature.scaffold`. The profiles' instructions are unchanged, so an existing `agents.json` needs no edit.

**Namespace.** The coordinator's paragraph asks for a tool name in a namespace that no existing tool uses (`changelog.build`, not `git.changelog`), and the Builder's section lists the namespaces of the core tools and asks for one of its own. The rule is also checked for a delegated Builder, by `feature.scaffold`, `feature.build`, `feature.install`, and `feature.enable`, before they write, build, or enable anything (`feature.enable` checks the manifest on disk). The entries checked are the tool names, the aliases, the tool name prefixes the manifest declares, and the prefix derived from each tool name (up to its last dot). They refuse a feature when an entry:

- starts with the namespace of a core tool: the core tool name up to and including its first dot (`agent.`, `exec.`, `feature.`, `local.`, `memory.`, `search.`, `skills.`, `tasks.`, `text.`, `todo.`), so `local.readFile.pdf` and `skills.list.x` are refused; a prefix is also refused when it covers the name of a core tool;
- collides with another loaded feature: it equals one of its tools or aliases, falls under one of its prefixes, or, for a prefix, covers or extends a tool, an alias, or a prefix of it.

An alias counts as itself and is checked like a tool name, but no prefix is derived from it. The refusal names the entry and what it collides with, and the Builder renames the tool. A Builder you run yourself (`--agent Builder`, `/feature`) is not subject to this check: nothing changes for it.

The check also runs at every reload of the feature bundles, whoever causes it: a registered feature whose loaded bundle no longer passes it loses its exposure, and is exposed again only by a new delegated build that passes it. This is a check on the ordinary path, not a sandbox (see **Security**).

**Exposure.** Only a generated feature is exposed: one whose ID is not a catalog ID. A bundled or optional feature, or the editable local copy of one that keeps its ID, is never exposed this way and stays under `/tools`. A generated feature is exposed to the session that called `agent.create` when all of these hold:

- this sub-agent built it successfully in this delegation (`feature.build`, or a `feature.scaffold` or `feature.install` that built it), and the manifest of the package it built is under the generated features root (`~/.zencode/features/`);
- it is loaded now (enabled, with its executable), and that loaded bundle is a generated feature that runs the executable that build produced. The exposure belongs to the bundle, not to the ID alone: another loaded bundle with the same ID that runs a different executable is not exposed.

A generated feature that already existed is exposed only if the delegated Builder rebuilds it in this delegation. Its tools join the tool list from the model's next round, in the same turn, without `/tools` and without recreating the session. The result of the next `agent.*` call of that session announces them once. The announcement names only the tools the session can actually call, with names made only of the characters `A-Z a-z 0-9 . _ -` (a feature whose ID is not made only of them is not named), at most 20 per feature followed by `and N more`:

```text
Feature tools now available in this session, built by your Builder sub-agent: <feature-id> (<tool names>). Call them directly.
```

A feature the Builder built is exposed as soon as it is enabled (the normal flow builds it and enables it afterwards); it needs no new build. A build whose task was cancelled registers nothing.

**Scope.**

- Only the session that called `agent.create` is given the feature. Other sessions do not see it. A sub-agent created with the coordinator's own profile does, because it reads the exposures of the delegating session by feature ID, not names added to its allowlist: it gets the tools of that feature and no other tool that shares their namespace, and revoking the exposure reaches it at its next call, even if it is already running. A child with a different profile does not see it (see [Tool Authority](agents.md#tool-authority)).
- It never grants a `feature.*` management tool or the name of a core tool, whatever the feature declares.
- Only a call made by a sub-agent with the `builder` role registers an exposure, and the runtime sets that identity when it creates the sub-agent: arguments written by the model cannot select it. Whether a build is registered depends on that identity, on the real outcome of the build, and on the checks on the feature ID, the path, and the executable above; the content of the package is what the Builder wrote. A Builder you run yourself (`--agent Builder`, `/feature`) exposes nothing: it keeps the `/tools` step.

**Lifecycle.** The exposure is transient: it is held in memory and never saved in a session, a snapshot, or a manifest. It ends:

- with the conversation: a reset, a new session, loading a saved session, closing the session, or shutdown. A full reset and the shutdown of a runner end the exposures of the sessions of that runner;
- when the session's agent profile changes;
- at a reload of the feature bundles that finds the loaded routing of the feature in a namespace it does not own (see **Namespace**);
- while the feature is disabled, and for good when it is deleted (`feature.delete` removes it from every session). Enabling a disabled feature again within the same conversation exposes it again.

It survives compaction, a model change, and an update of the session options. Only the exposure is transient: the feature stays built and enabled on disk, so a session with no tool restriction (no allowlist) sees it like any other enabled feature, and after a restart you select it from `/tools` like any other.

**`/tools`.** The menu shows an exposed feature ticked, and the summary of the active tools lists it. A selection you confirm is authoritative: a feature that stays ticked becomes part of the session's tool selection (and goes through the workspace access request like any generated feature you select there), and one you untick is no longer exposed.

**Turning it off.** Remove the Builder profile from the profiles associated with the project with `/agents`, or remove `sub-agents` from the session's tools with `/tools`.

**Security.** A generated tool that the Builder sub-agent wrote or rebuilt becomes callable in the session without the explicit `/tools` step and without a consent request of its own. The operator consent is unchanged: `local.exec` and the destructive tools still ask, and the Builder sub-agent asks for the same approvals as any delegated agent. But the tools of a feature are approved by selecting them, and here the selection is automatic. That skips two things: the `/tools` step and the workspace access request that selecting a generated feature there brings (the host asks to let the tool reach the workspace folder, and a refusal deselects it). The automatic exposure does not ask, so nothing asks before the new tool first runs, and nothing reviews its source. The exposure is transient, the feature is not: it stays built and enabled under `~/.zencode/features/<feature-id>/`, a session with no tool restriction sees it like any other enabled feature, and after a restart you select it from `/tools`, and that selection goes through the workspace access request. The namespace rule does not change this: it is a check on the ordinary path, not a sandbox. The Builder sub-agent has the file tools and can rewrite the files of the package, `feature.json` included, after the build. Nothing prevents a restart or the reload of another session from loading the rewritten manifest, and the feature can then claim another namespace for the sessions that select it or whose tool list makes it relevant, exactly as a Builder you run yourself can. What the code guarantees is narrower: a feature whose loaded routing takes a namespace it does not own does not stay exposed automatically. Read the generated package before relying on it, and turn the capability off if you do not accept this.

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

Bundled feature packages can include Web, Git, Swift, Xcode, Figma, and Jira. They can be enabled directly or copied for local editing.

Core tools (shell, files, text, search, memory, sub-agents) are **not** feature packages — manage them through `/tools`, not `/feature`.

Some integrations need extra configuration. For example, Jira runs setup automatically on the first `jira.search` or `jira.read` call when no token is stored; `/feature enable jira-tools` only toggles package state and does not run authentication. On macOS you configure Jira through the form that opens in the browser; on Linux (no browser setup), set `ZENCODE_JIRA_SITE_URL`, `ZENCODE_JIRA_EMAIL` and `ZENCODE_JIRA_API_TOKEN` in the environment of `zen`. On every platform, macOS included, the token is stored in a `0600` file under `~/.zencode/jira/credentials/` (a `0700` directory; it honors `ZENCODE_SUPPORT_DIRECTORY`) and not in the Keychain, so the Jira tools also work in headless runs such as `/cron` jobs.
