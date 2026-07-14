# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime included in this repository. It can run as a standalone terminal agent, as an ACP stdio agent for compatible clients, with cloud providers or your existing ChatGPT/Claude subscription, or fully on-device through `zen --mlx` to use the local MLX runtime directly without HTTP.

Use this guide to set up providers, subscriptions, agent profiles, tools, skills, saved sessions, memory, and day-to-day terminal commands.

## Modes

`zen` supports three practical launch modes:

1. Standalone chat TUI:

   ```bash
   zen
   ```

2. ACP over stdio for compatible clients:

   ```bash
   zen --acp
   ```

3. Direct local MLX runtime:

   ```bash
   zen --mlx
   ```

Standalone `zen` uses providers/models from `~/.zencode/settings.json`. During setup you can configure cloud API providers (OpenAI-compatible, OpenRouter, local servers), sign in with your **ChatGPT Subscription** or **Claude Subscription** through the browser, or use the local MLX/DS4 runtimes. Direct `zen --mlx` uses the local `~/.zencode/mlx/models.json` catalog and the local MLX runtime directly.

## First Setup

Create standalone support files and configure providers/models:

```bash
zen --setup
```

The first setup creates files under `~/.zencode/`. During setup you can also
enable Telegram remote control, pair the bot once, enable local voice tools, and
store those settings in `settings.json`.

Create or update the local MLX runtime settings and model catalog from the same setup menu:

```bash
zen --setup
```

- `settings.json`: provider/model configuration, selected model, optional Telegram remote control token plus linked chat, and optional local voice tool settings.
- `permissions.json`: persistent runtime approvals such as allowed `local.exec` commands.
- `agents.json`: agent profiles, model overrides, tool selection, symbols, and instructions.
- `AGENTS.md`: global operating guidance for the agent.
- `MEMORY.md`: lightweight global resume index used only when a session does not start in a clear project.
- `sessions/`: saved session snapshots grouped by project.
- `features/`: generated Swift feature packages when the Builder agent creates reusable tools.

## Command Line Options

```text
zen [--setup] [--acp] [--agent NAME] [--model MODEL_ID] [--cwd PATH] [--skills LIST]
```

Important options:

- `--setup`: open setup for providers, models, agents, local MLX runtime/model setup, and reset actions, then exit.
- `--acp`: run ACP JSON-RPC over stdio instead of terminal chat.
- `--agent NAME`: select an agent profile from `agents.json`; defaults to `Default` when omitted.
- `--model MODEL_ID`: override the agent-selected model for this run. Accepted forms include a model id, `remoteapimodel:<uuid>`, or `remoteapi:<uuid>`.
- `--cwd PATH`: working directory for local tools. An explicitly supplied path is used as-is after path normalization. Defaults to the current directory, or home when launched from the executable directory.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt. The default is shown by `zen --help`.
- `--max-output-tokens N`: maximum generated tokens per model call. Default: model default.
- `--verbose`: show status/tool progress on stderr. Default chat output is quiet.

Environment variables mirror the main options:

- `ZENCODE_AGENT_MODE`: `chat`, `acp`, or `auto`; auto resolves to chat.
- `ZENCODE_AGENT_NAME`: agent profile name.
- `ZENCODE_AGENT_MODEL`: model override.
- `ZENCODE_AGENT_CWD`: working directory.
- `ZENCODE_AGENT_SKILLS`: initial skill selection.
- `ZENCODE_AGENT_VERBOSE`: `1` or `true` for verbose progress.
- `ZENCODE_AGENT_BEARER_TOKEN`: fallback bearer token for configured remote providers.

## Agent Profiles

Agent profiles live in `~/.zencode/agents.json` and are managed in the Agents
section of the setup menu:

```bash
zen --setup
```

The setup can create the recommended profiles:

- `Default`: general coding assistant.
- `Builder`: creates, builds, validates, enables, disables, and deletes reusable Swift feature tools.
- `Minimal`: concise assistant with only essential shell/file/text tools.
- `Xcode`: ACP profile for Xcode with Xcode-native tools enabled.
- `Planner`: read-only planner used by `/plan` and sub-agent delegation.
- `Reviewer`: read-only reviewer used by `/review` and sub-agent delegation.

Profiles can define enabled tools, skills, model overrides, symbols, and extra instructions. In the TUI you can switch profiles without restarting:

```text
/agents
/agents list
/agents Xcode
/agents 2
```

Switching profiles resets the active conversation so the new system prompt and tool set are cleanly applied.

## Terminal TUI Commands

Inside chat mode, type a prompt and press return. Commands start with `/`:

- `/help`: show command help.
- `/models`: show configured models and switch the current session model.
- `/agents [list|<agent name>|<number>]`: switch agent profile.
- `/tools [all|none|tool-name|package-name|tool-number]`: select which tool groups are exposed to the model.
- `/make-agents`: ask the current model to inspect the exact current working directory and create or conservatively update its `AGENTS.md`. The command treats the directory as an arbitrary workspace, does not assume a repository, project type, language, or toolchain, and requires the `Files` tool group.
- `/skills`: select installed prompt skills or install a skill from GitHub/local folder.
- `/sessions [session name]`: list/load sessions, or save a named session snapshot for the current project.
- `/sessions save`: refresh the currently active saved session. If no saved session is active yet, it saves a new session named after your first prompt.
- `/sessions compact`: force compaction of the current conversation context without saving a snapshot.
- `/sessions new`: reset the conversation and start a fresh, unsaved session.
- `/sessions delete`: delete a saved session snapshot.
- `/attach <file> [file ...]`: attach image/video files to the next prompt.
- `/attach list`: list pending attachments.
- `/attach delete [all|number]`: remove pending attachments.
- `/open`: list files, URLs, and file-backed attachments referenced in the conversation, newest first, then open the selected item with the system `open` utility. In non-interactive terminals it prints the candidate list instead of opening a menu.
- `/open <file-or-url>`: open a specific file path or URL directly. Relative file paths are resolved from the current working directory.
- `/changes`: show the latest tracked file change summary.
- `/changes diff`: include patches in the change summary.
- `/undo`: revert the most recent tracked file changes created by the agent.
- `/tasks [status|list]`: show the authoritative task graph for the current session, including derived runnable/dependency state and delegated attempts.
- `/tasks show <id>`: show one task with dependencies, attempts, output, errors, and recorded evidence.
- `/tasks retry <id>`: explicitly return a failed or blocked task to `pending` without deleting its attempt history.
- `/tasks cancel <id> [reason]`: cancel the task and its active delegated worker, if any.
- `/tasks clear`: remove all task graphs for the logical session; this is refused while an attempt is active.
- `/plan <goal>`: delegate the complete planning goal to one read-only `Planner` plan author. Its output and structured points become an unapproved plan plus a persistent draft task graph. The current profile may coordinate but cannot rewrite the plan. Use `/plan approve` to activate the graph and start implementation immediately; use `/plan clear` to archive the graph and remove the active plan. With no goal, the command reports the missing goal and does not create a Planner.
  This command requires the `sub-agents` tool group; enable it with `/tools` or switch to a profile that includes it.
- `/plan status`: project the authoritative graph state back into the plan table, including `pending`, `in_progress`, `awaiting_validation`, `completed`, `blocked`, `failed`, and `cancelled` task states. It does not create sub-agents.
- `/review [focus]`: delegate review to read-only `Reviewer` sub-agents. The command reviews tracked session changes and verifies task/approved-plan claims against current files and real validation evidence. A task graph or approved plan enables coverage-only review even when no tracked change summary is available.
  This command requires the `sub-agents` tool group; enable it with `/tools` or switch to a profile that includes it.
- Delegated sub-agent status is shown automatically in the chat flow while `/plan`, `/review`, or `agent.*` tool calls create and update sub-agents. Task-bound agents show their task and attempt number. The overview shows only the most recently created `agent.create` batch; earlier agents remain available to targeted `agent.*` commands and `agent.list`. An `agent.create` call accepts at most eight agents; read-only report agents may run concurrently, while only one implementation agent may be queued or running because implementation agents share the working directory.
- `/telegram`: show Telegram status for the current TUI session.
- `/telegram on`: turn Telegram on for the current TUI session. This also sends a confirmation message to the linked Telegram chat, so the iOS client is woken up and you do not need to message the bot first to start receiving notifications.
- `/telegram off`: turn Telegram off for the current TUI session.
  This command is available only after Telegram was enabled and paired during `zen --setup`; otherwise it is treated as unknown.
- When Telegram remote control is active, tool-start progress notifications report the concrete tool name and kind (e.g. `🔧 local.readFile · read`), followed by the workspace-relative file path when available, or another concise and safe contextual detail (command, pattern, query, URL, branch, revision, feature/task/agent identifier). Sensitive argument fields (file contents, full patches, prompts, old/new text, environment) are never serialized. Allowed contextual values are truncated but not redacted; they may contain operational data visible to the Telegram recipient.
- `/voice`: start recording a voice prompt. Press `Enter` again to stop; the transcript becomes the prompt.
  This command is available only after local voice tools were enabled during `zen --setup`; otherwise it is treated as unknown.
- `/exit`: close the session.

Interactive terminals also support:

- `Ctrl+T` to toggle compact/full tool output.
- `Ctrl+A` to toggle the TUI runner between default and full access.

Full access is temporary and is never written to settings, saved sessions, or
`permissions.json`; a new TUI process always starts in default mode. While full
access is active, only `local.exec` approval checks are bypassed. It does not
expose tools that the current profile or `/tools` selection has disabled, and it
does not bypass operating-system permissions or other tool policies. Because the
mode applies to the whole TUI runner, it can also approve `local.exec` commands
requested by delegated sub-agents or by Telegram prompts routed through that same
session. Switch back to default mode to restore approvals for subsequent
commands; an already-started process is not revoked.

The status bar shows no access indicator in default mode and a red dot only while
full access is active.

`Ctrl+A` uses an unambiguous legacy control code and therefore works in Apple
Terminal as well as terminals with enhanced keyboard protocols. It replaces the
usual `Ctrl+A` move-to-start shortcut in ZenCODE's interactive input panel; the
dedicated Home key remains available. The shortcut requires that panel to be
active. If the panel cannot start, for example in a very small terminal or when
the controlling output is not a TTY, ZenCODE uses the blocking input fallback,
ignores the shortcut, and keeps the runner in its current mode (normally
`default`). The shortcut and access mode are TUI-only and do not change ACP
modes or permission handling.

## Tool Selection

Tools are not just shell access. Depending on profile, mode, and environment, tool groups can include:

- local filesystem reads/writes;
- shell execution;
- text utilities;
- search tools;
- Git tools;
- memory tools;
- sub-agent delegation;
- Xcode tools when Xcode is running and exposed through MCP;
- Figma tools when the local Figma desktop MCP server exposes tools;
- generated Swift feature tools;
- bundled feature tools such as search, web, git, Xcode, Figma, or Jira integrations.

Use `/tools` to inspect and select the tool groups for the current session. ACP clients can pass the enabled tools to the runtime directly.

## Task Orchestration Control Plane

`todo.*` and `tasks.*` have separate responsibilities. `todo.read`/`todo.write` are a lightweight checklist for model-local coordination. `tasks.create`, `tasks.list`, `tasks.get`, `tasks.update`, `tasks.retry`, and `tasks.cancel` operate on the authoritative session task graph owned by `AgentCoreSessionRunner` through `SessionTaskOrchestrator`.

A graph is a validated DAG. Task creation is atomic: duplicate IDs, missing/self dependencies, cycles, depth/size limits, or an invalid batch reject the whole mutation. `tasks.list` derives whether each task is runnable from graph activation, task status, and completed dependencies. Lifecycle transitions are checked, revisions support optimistic fencing, retries preserve previous output/error history, and cancelled or stale attempts cannot later overwrite a newer attempt.

When `tasks.create`, `tasks.list`, and `tasks.update` are enabled, the coordinator should decide before launching multiple sub-agents or beginning work with multiple phases whether it is a coordinated workflow. If it has multiple work units, dependencies, concurrent delegation, durable progress, retry, validation, or review requirements, it first creates one task graph with explicit dependencies, then selects runnable work with `tasks.list` and assigns each delegated task through `agent.create(taskID:)`. Once a graph is active, every delegated agent must carry a task ID, regardless of the currently selected tool subset. Independent tasks may still run in parallel. A single self-contained delegation or short disposable lookup does not require a graph. When the task workflow tools are not enabled, the coordinator can only use the exposed tool surface and the parallel-delegation guard does not require an unavailable graph.

Moving direct coordinator work from `pending` to `in_progress` creates a coordinator attempt automatically. Passing `taskID` to `agent.create` atomically claims a runnable task and creates a sub-agent attempt. A task-bound child can read only its assigned graph, its task, and direct dependencies; it can append progress only to its own active attempt. Report-agent success completes a task, while implementation-agent success moves it to `awaiting_validation`; a separate validation result is required before `completed`.

Task graph checkpoints are written atomically under `~/.zencode/task-graphs/<project>/` (or `ZENCODE_SUPPORT_DIRECTORY`) and restored by session ID for TUI and ACP sessions. Active attempts found during restore become `blocked`/`interrupted` rather than being silently resumed. Saved-session format v3 also embeds the current graph; v2 snapshots remain loadable. A technical backend rebuild preserves the graph, while a logical session reset interrupts its workers and discards the graph/checkpoint.

## Planner Agent And Planning

The `Planner` profile is a built-in read-only planning profile. It is intended to author delegated plans before implementation: the Planner inspects only the context needed to make a plan concrete, then writes the ordered implementation points, likely files or areas to change, risks, open questions, and validation steps.

Use `/plan` from a normal implementation session when you want a planning pass before editing:

```text
/plan add archived-memory filtering to the memory search UI
/plan update docs and tests for the new Planner agent
```

`/plan` requires the goal as an argument; run `/plan <goal>` rather than a bare `/plan`.

`/plan` keeps the current agent profile only as a coordinator and creates exactly one `plan-author` sub-agent with role and profile `Planner`. The Planner runs with `isolationMode "report"` and a read-only planning tool allowlist, so it can inspect but cannot modify the workspace. It receives the complete goal and writes the final actionable plan itself. The coordinator copies the Planner's numbered points and explicit dependencies into stable IDs, validates the resulting DAG, and creates it as a draft graph; it is forbidden from drafting, consolidating, or rewriting the plan. The TUI displays and records the Planner's `latestOutput` directly; if no completed Planner output or valid structured graph exists, the turn fails instead of falling back to a plan from `Default`. `/plan approve` activates that same graph and immediately starts implementation without requiring another user prompt. Use `/plan status` to inspect graph-projected progress during the loop `/plan <goal> -> /plan approve` (automatic implementation) `-> /review`.

See the [Planner agent guide](planner.md) for details.

## Reviewer Agent And Reviews

The `Reviewer` profile is a built-in read-only review profile. It is intended for delegated code review rather than implementation: reviewers inspect source files and the tracked session-change diff, then report concrete findings with severity and `file:line` references.

Use `/review` from a normal implementation session when you want a second pass before editing or committing:

```text
/review
/review Sources/ZenCODECore/ZenCODETUI/Chat
/review check the session restore flow and related tests
```

`/review` keeps the current agent profile as the review director and creates `Reviewer` sub-agents through sub-agent tools. The delegated reviewers run with `isolationMode "report"` and a read-only tool allowlist, so they can inspect but must not modify the workspace. The review scope is the current session's tracked file changes plus the current task graph and any approved plan. Completed statuses, attempt outputs, and stored evidence are treated as claims rather than proof: reviewers verify current files and actual validation results, classify every task (`implemented`, `validated`, `unverified`, `failed`, `deviated`, `cancelled`, or `blocked`), and call out discrepancies. After the reviewers finish, the director consolidates findings and proposes a correction plan; it does not edit files as part of the review turn.

See the [Reviewer agent guide](reviewer.md) for details.

## Skills

Skills are prompt modules that can be selected per session. Use:

```text
/skills
```

The TUI can select installed skills or install a skill from GitHub or a local folder. Start with `--skills LIST` when you want a fixed initial selection for a run:

```bash
zen --skills all
zen --skills none
zen --skills "review,swift"
```

## Attachments

Use attachments for image or video context in models/providers that support it:

```text
/attach screenshot.png demo.mov
/attach list
/attach delete 1
/attach delete all
```

Attachments are applied to the next prompt, then the session continues with the normal conversation history.

In the TUI, run:

```text
/voice
```

Recording starts immediately. Press `Enter` to stop recording; `ZenCODE`
transcribes the audio and sends the transcript as the prompt. If Telegram remote
control is active, Telegram voice messages use the same transcription pipeline;
the transcript becomes the prompt and the final response is delivered as text.

## Saved Sessions

Saved sessions are explicit snapshots under `~/.zencode/sessions/` for the current project.

Save a named session:

```text
/sessions my-feature
```

Refresh the active saved session after more work:

```text
/sessions save
```

Force compaction of the current conversation context without saving a snapshot:

```text
/sessions compact
```

List and load sessions:

```text
/sessions
```

Delete a session:

```text
/sessions delete
```

Start a fresh, unsaved session:

```text
/sessions new
```

Local MLX sessions save the runtime snapshot. Remote sessions save the local transcript, including tool calls, outputs, and provider replay metadata. Version 3 snapshots also embed the current authoritative task graph and active plan; version 2 snapshots remain loadable without a graph. ChatGPT subscription sessions persist response continuation metadata so a restored session can resume with a small delta request when the provider still accepts the previous response id. Anthropic subscription sessions replay signed thinking blocks and use one-hour prompt-cache breakpoints so compatible restored prefixes can be read from cache instead of being fully reprocessed. `/sessions compact` rewrites the active runtime context by summarizing older turns into the system prompt and keeping recent messages; provider continuations and runtime caches are regenerated as needed on later prompts.

When `/sessions <name>` saves a session, `ZenCODE` updates one active global resume pointer for that project while leaving pointers for other projects intact. `/sessions save` rewrites that active saved session; if no saved session is active yet, it saves a new session named after your first prompt. `/sessions compact` only updates the active conversation; run `/sessions save` afterwards if you want the compacted state persisted. `/sessions new` resets the conversation and starts a fresh, unsaved session.

## Memory and Project Context

`ZenCODE` separates durable context by responsibility:

- Project `AGENTS.md` contains durable workspace-specific constraints, important structure, confirmed commands or workflows, and non-obvious caveats. Check it into version control when it is shared guidance.
- Global `~/.zencode/AGENTS.md` contains cross-workspace operating rules and preferences.
- Project `MEMORY.md` in a workspace is the codebase journal. It should contain concise handoff entries with `Timestamp`, `Summary`, `State`, and `Next`.
- Global `~/.zencode/MEMORY.md` is only a lightweight resume index for sessions that do not start inside a clear project.

ZenCODE reads `AGENTS.md` from the current working directory when the file is present. Normal TUI, ACP, MLX, and DS4 startup never creates, audits, or rewrites a project file. In the terminal UI, enable the `Files` tool group and run:

```text
/make-agents
```

`/make-agents` starts a model turn rather than expanding a built-in template. The model first inspects the opened directory, which may be empty or may contain any kind of material, then derives only guidance supported by what it observes. If `AGENTS.md` exists, the model must read it and preserve useful user-authored guidance; otherwise it creates the file. The command targets only `AGENTS.md` in the exact current working directory and does not infer a Git, package, Xcode, or other “project root.” The dedicated turn excludes task, sub-agent, memory-write, shell, and unrelated mutation tools; it retains bounded read-only discovery plus `local.writeFile`, subject to the active profile's normal tool and permission policy. Keep durable team guidance versioned when appropriate.

A good project memory entry records durable state, decisions, blockers, and next steps. It should not record every command, raw output, or facts obvious from the files.

## File Change Tracking

The terminal runtime tracks file edits made by the agent during a turn. Use:

```text
/changes
/changes diff
/undo
```

`/undo` targets the most recent tracked changes made by the agent. It is intended as a safety mechanism for agent edits, not as a general replacement for Git.

## Dynamic Swift Features

Generated features are reusable Swift tool packages managed by the Builder agent. Switch to the Builder profile, then use:

```text
/feature
/feature list
/feature status
/feature enable <id|name|#>
/feature disable <id|name|#>
/feature build <id|name|#>
/feature validate <id|name|#>
/feature reload
/feature delete <id|name|#>
```

`/feature list` opens the enable/disable menu. `/feature status` prints the
known feature packages. Features are discovered from bundled feature binaries and
generated packages under `~/.zencode/features`. Generated packages are plain
Swift 6.3 packages and run out-of-process over a JSON stdin/stdout protocol.

See the [Builder agent guide](builder.md) for Builder usage and technical feature package notes.

## ACP Mode

ACP mode is for clients that manage the UI and communicate with the agent over stdio:

```bash
zen --acp --cwd /path/to/project
```

In ACP mode:

- stdout contains only ACP JSON-RPC messages;
- status or diagnostics should go to stderr when enabled;
- clients provide prompts, sessions, and tool exposure;
- `--agent`, `--model`, `--cwd`, `--skills`, and token environment variables still apply.

## Direct Local Runtime with zen --mlx

For fully local MLX inference without HTTP, run:

```bash
zen --mlx --cwd /path/to/project
```

This mode:

- reads models from `~/.zencode/mlx/models.json`;
- uses `MLXServerRuntime` directly;
- respects local model generation defaults and disk KV cache settings;
- persists the per-session KV cache on session close/shutdown and restores it on
  reconnect, including for stateless ACP clients without a `session_id` (see the
  [Local MLX runtime guide](mlx-runtime.md) for details);
- can run chat TUI or ACP with `--acp`;
- loads an existing `AGENTS.md` from the selected working directory without creating or rewriting one during startup; use `/make-agents` in chat to ask the model to create or update it.

Example with explicit model and profile:

```bash
zen --mlx \
  --cwd /path/to/project \
  --model qwen3-mlx \
  --agent Feature \
  --max-output-tokens 4096 \
  --verbose
```

## Recommended Workflow

1. Run setup once:

      ```bash
   zen --setup
   ```

2. Start in the target project:

   ```bash
   cd /path/to/project
   zen --agent Default
   ```

3. Select tools and skills:

   ```text
   /tools
   /skills
   ```

4. Run `/plan <goal>` when the work benefits from a delegated planning pass before editing.
5. Implement the plan with the active implementation profile.
6. Review changes with `/changes diff` and Git.
7. Run `/review` for a read-only Reviewer pass when the change is broad, risky, or ready for a pre-commit check.
8. Save meaningful checkpoints with `/sessions name`, then refresh the active checkpoint with `/sessions save`.
9. Keep durable project status in project `MEMORY.md` when a session reaches a useful handoff point.

## Troubleshooting

- Setup starts automatically: required `~/.zencode` files are missing; complete `--setup`.
- Model not found: run `/models` or check `~/.zencode/settings.json`; in `zen --mlx` mode check `~/.zencode/mlx/models.json`.
- No tools available: use `/tools`, switch to a profile that permits tools, or check ACP client tool exposure.
- `/make-agents` says the Files tool group is required: enable `Files` with `/tools`, or switch to an agent profile that includes it.
- `/feature` unavailable: switch to the Builder agent with `/agents Builder`.
- `/plan` says a goal is required: rerun it as `/plan <goal>` with the activity you want planned.
- `/plan` says sub-agents are required: enable the `sub-agents` tool group with `/tools`, or switch to an agent profile that includes it.
- `/review` says sub-agents are required: enable the `sub-agents` tool group with `/tools`, or switch to an agent profile that includes it.
- Xcode tools missing: make sure Xcode is running and MCP bridge tooling can expose tools. For Xcode 27 ACP setup, see [Xcode 27 ACP setup](xcode.md).
- Figma tools missing: make sure the Figma desktop MCP server is enabled.
- Resume picked the wrong project: start from the intended `--cwd` or project directory, then use `/sessions` for explicit snapshots.
