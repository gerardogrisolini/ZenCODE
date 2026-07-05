# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime included in this repository. It can run as a standalone terminal agent, as an ACP stdio agent for compatible clients, or through `zen --mlx` to use the local MLX runtime directly without HTTP.

Use this guide to set up providers, agent profiles, tools, skills, saved sessions, memory, and day-to-day terminal commands.

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

Standalone `zen` uses providers/models from `~/.zencode/settings.json`. Direct `zen --mlx` uses the local `~/.zencode/mlx/models.json` catalog and the local MLX runtime directly.

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
- `--cwd PATH`: working directory for local tools. Defaults to the current directory, or home when launched from the executable directory.
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
- `/plan <goal>`: delegate planning for an explicit goal to one or more read-only `Planner` sub-agents. With no goal, the command reports the missing goal and does not create sub-agents.
  This command requires the `orchestration` tool group; enable it with `/tools` or switch to a profile that includes it.
- `/review [focus]`: delegate code review to one or more read-only `Reviewer` sub-agents. The command reviews only the tracked file changes made during the current session; an optional focus is applied within those session changes.
  This command requires the `orchestration` tool group; enable it with `/tools` or switch to a profile that includes it.
- Delegated sub-agent status is shown automatically in the chat flow while `/plan`, `/review`, or `agent.*` tool calls create and update sub-agents.
- `/telegram`: show Telegram status for the current TUI session.
- `/telegram on`: turn Telegram on for the current TUI session. This also sends a confirmation message to the linked Telegram chat, so the iOS client is woken up and you do not need to message the bot first to start receiving notifications.
- `/telegram off`: turn Telegram off for the current TUI session.
  This command is available only after Telegram was enabled and paired during `zen --setup`; otherwise it is treated as unknown.
- `/voice`: start recording a voice prompt. Press `Enter` again to stop; the transcript becomes the prompt.
  This command is available only after local voice tools were enabled during `zen --setup`; otherwise it is treated as unknown.
- `/speak`: synthesize and play the last assistant response.
  This command is available only after local voice tools were enabled during `zen --setup`; otherwise it is treated as unknown.
  Long responses are shortened and stripped of code blocks before speech synthesis.
    Audio generation is macOS-only, so this command is hidden on Linux.
- `/exit`: close the session.

Interactive terminals also support `Ctrl+T` to toggle compact/full tool output.

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

## Planner Agent And Planning

The `Planner` profile is a built-in read-only planning profile. It is intended for delegated planning before implementation: planners inspect only the context needed to make a plan concrete, then report likely files or areas to change, implementation phases, risks, open questions, and validation steps.

Use `/plan` from a normal implementation session when you want a planning pass before editing:

```text
/plan add archived-memory filtering to the memory search UI
/plan update docs and tests for the new Planner agent
```

`/plan` requires the goal as an argument; run `/plan <goal>` rather than a bare `/plan`.

`/plan` keeps the current agent profile as the planning director and creates `Planner` sub-agents through the orchestration tools. The delegated planners run with `isolationMode "report"` and a read-only planning tool allowlist, so they can inspect but must not modify the workspace. After the planners finish, the director consolidates their output into one actionable plan for the loop `/plan -> implementation work -> /review`.

See the [Planner agent guide](planner.md) for details.

## Reviewer Agent And Reviews

The `Reviewer` profile is a built-in read-only review profile. It is intended for delegated code review rather than implementation: reviewers inspect source files and the tracked session-change diff, then report concrete findings with severity and `file:line` references.

Use `/review` from a normal implementation session when you want a second pass before editing or committing:

```text
/review
/review Sources/ZenCODECore/ZenCODETUI/Chat
/review check the session restore flow and related tests
```

`/review` keeps the current agent profile as the review director and creates `Reviewer` sub-agents through the orchestration tools. The delegated reviewers run with `isolationMode "report"` and a read-only tool allowlist, so they can inspect but must not modify the workspace. The review scope is the current session's tracked file changes, not git history or memory context. After the reviewers finish, the director consolidates findings and proposes a correction plan; it does not edit files as part of the review turn.

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
control is active, Telegram voice messages use the same transcription pipeline
and receive the final response as audio instead of text when `ZenCODE` is
running on macOS. On Linux, audio generation is not enabled and Telegram receives
the final response as text.

To play the latest assistant response locally:

```text
/speak
```

For faster playback, long responses are converted to a shorter spoken version
before synthesis. The full text remains visible in the TUI.

When used from Telegram on iOS, the audio is still generated by the Mac running
`zen` and uploaded to Telegram as an `.m4a` file.

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

Local MLX sessions save the runtime snapshot. Remote sessions save the local transcript, including tool calls, outputs, and provider replay metadata. ChatGPT subscription sessions persist response continuation metadata so a restored session can resume with a small delta request when the provider still accepts the previous response id. Anthropic subscription sessions replay signed thinking blocks and use one-hour prompt-cache breakpoints so compatible restored prefixes can be read from cache instead of being fully reprocessed. `/sessions compact` rewrites the active runtime context by summarizing older turns into the system prompt and keeping recent messages; provider continuations and runtime caches are regenerated as needed on later prompts.

When `/sessions <name>` saves a session, `ZenCODE` updates one active global resume pointer for that project while leaving pointers for other projects intact. `/sessions save` rewrites that active saved session; if no saved session is active yet, it saves a new session named after your first prompt. `/sessions compact` only updates the active conversation; run `/sessions save` afterwards if you want the compacted state persisted. `/sessions new` resets the conversation and starts a fresh, unsaved session.

## Memory and Project Context

`ZenCODE` separates durable context by responsibility:

- Project `MEMORY.md` in a workspace is the codebase journal. It should contain concise handoff entries with `Timestamp`, `Summary`, `State`, and `Next`.
- Global `~/.zencode/MEMORY.md` is only a lightweight resume index for sessions that do not start inside a clear project.
- Operating rules, team conventions, and preferences belong in `AGENTS.md`, not in memory.

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
- creates a default project `AGENTS.md` if one is missing.

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
- `/feature` unavailable: switch to the Builder agent with `/agents Builder`.
- `/plan` says a goal is required: rerun it as `/plan <goal>` with the activity you want planned.
- `/plan` says orchestration is required: enable the `orchestration` tool group with `/tools`, or switch to an agent profile that includes it.
- `/review` says orchestration is required: enable the `orchestration` tool group with `/tools`, or switch to an agent profile that includes it.
- Xcode tools missing: make sure Xcode is running and MCP bridge tooling can expose tools. For Xcode 27 ACP setup, see [Xcode 27 ACP setup](xcode.md).
- Figma tools missing: make sure the Figma desktop MCP server is enabled.
- Resume picked the wrong project: start from the intended `--cwd` or project directory, then use `/sessions` for explicit snapshots.
