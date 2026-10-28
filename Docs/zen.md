# ZenCODE Guide

`ZenCODE` is the autonomous coding agent runtime in this repository. It runs as a standalone terminal agent, as an ACP stdio agent, with cloud providers or your ChatGPT/Claude subscription.

## Modes

```bash
zen                              # standalone chat TUI
zen -p "Summarize the changes"   # one headless turn; final text on stdout
zen --jsonl -p "Summarize"       # one headless turn; JSON Lines events on stdout
zen -f /path/to/prompt.md        # one headless turn; prompt read from a file
zen --acp                        # ACP over stdio for compatible clients
```

Standalone `zen` uses providers/models from `~/.zencode/settings.json`.
Headless JSONL mode is documented in the dedicated
[protocol guide](jsonl.md).

## Session File Artifacts

During the active terminal session, ZenCODE keeps an in-memory history
of effective file mutations, grouped by turn. Use `/artifacts` without arguments
to show the complete history, including text evidence, patches, and explicit
fallbacks for binary, uncertain, or over-budget evidence (64 KiB per text and
256 KiB per turn). When the workspace checkpoint's evidence for an added,
deleted or modified text file exceeds that limit, the artifact shows the first
whole diff lines that fit, with a truncation note; `/undo` still uses the full
patch. Normal tool blocks remain compact without code or diffs.
The history is scoped to the active
session and is cleared by `/sessions new`, loading/restoring a session, and
`/setup`; it is never written to saved snapshots, checkpoints, transcripts, or
ACP wire messages. `/changes`, `/changes diff`, `/undo`, the final `Summary`,
and the ACP standard `locations`/`diff` updates keep their existing contracts.
TUI and ACP use the same path normalization and evidence mapper; only their
presentation renderer differs.

## Recovering Incomplete Tasks at Startup

When standalone `zen` starts in an interactive terminal, it scans the current
project for task-graph checkpoints left incomplete by earlier sessions. If any
are found, an orange, scrollable picker opens before the model session is
created. Use `↑`/`↓` to move and `Enter` to select the graph marked with `(x)`.
You can also choose **Start fresh** to leave every checkpoint unchanged.
The startup scan and picker are disabled when `zen` runs in `--acp` mode.

Selecting **Delete old tasks…** opens a multi-selection list. Use `Space` to
mark obsolete graphs with `[x]`, `A` to select all, `N` to select none, and
`Enter` to delete the selected graphs. Deletion is graph-specific: other graphs
stored in the same previous session are preserved.

> **Exact-graph recovery guarantee:** a recovery choice identifies both the
> previous logical session and the selected graph. ZenCODE restores the
> checkpoint, makes that exact graph active and current, persists the new
> `currentGraphID`, and only then creates the model/backend session. It never
> substitutes another graph merely because that graph was current when the old
> checkpoint was written. Any active execution attempt found in the checkpoint
> is marked `interrupted`, and its task becomes `blocked`; external work is not
> assumed to still be running after a process restart.

This startup recovery concerns the authoritative task graph. It is separate
from `/sessions restore`, which navigates the saved conversation checkpoint
tree and creates a new conversational branch.

## First Setup

```bash
zen
```

When required configuration is missing or invalid (`settings.json` or
`agents.json`), or when no model is configured, `zen` opens setup automatically before starting the chat. Use `/setup` later to
reconfigure ZenCODE; the TUI saves the current session, rebuilds the runtime,
and restores the conversation without closing the app.

In ACP mode (`--acp` or `ZENCODE_AGENT_MODE=acp`), setup never starts inside
the ACP stream. See [ACP Mode](#acp-mode) for the authentication methods and
the behavior before ZenCODE is configured.

Creates files under `~/.zencode/`:

- `settings.json` — provider/model configuration, selected model, optional Telegram, voice (Telegram voice-message transcription and the macOS voice mode reading voice), and memory-embedding settings (endpoint, optional model).
- `permissions.json` — persistent runtime approvals.
- `agents.json` — agent profiles, authorized model bindings, tools, and instructions.
- `AGENTS.md` — global operating guidance shared across workspaces. This is
  separate from an optional project `AGENTS.md` in the working directory.
- `memory/` — project memory graphs: one `memory.graph.json` per project with its binary vectors file `memory.graph.json.vectors`, under the project key (see below), plus `global/` for the global graph used by `organizer` sessions.
- `projects/` — per-project agent associations (`agents.json`, see `/agents`), under the project key.
- `sessions/` — saved session snapshots grouped by project key.
- `task-graphs/` — atomic project/session task checkpoints, including explicitly saved plans, grouped by project key.
- `features/` — generated Builder packages and installed optional feature packages.
- `source/` — persistent ZenCODE checkout retained by the platform installer for later optional-feature builds.
- `voice/` — Linux only: the speech programs and models downloaded from `/setup` > **Voice mode** for voice mode and Telegram voice messages. They can be downloaded again at any time and are not part of backups. See [voice.md](voice.md).

## Project Key

Project memory (`memory/`), the project agents chosen with `/agents`
(`projects/`), saved sessions (`sessions/`), and task graphs and saved plans
(`task-graphs/`) are stored per project under a **project key** derived from the
project name — the name of the working directory folder, trimmed and compared
case-sensitively — not from its full path:

```text
~/.zencode/memory/App-Ist-3.0-IOS-<first 24 hex of SHA-256 of the name>/memory.graph.json
```

- **Moving a project folder** keeps all of it: open `zen` in the new location
  and the memory, the associated profiles, the sessions, and the plans are
  there.
- **Two folders with the same name are the same project**: they share one
  memory graph, one set of associated profiles, one session list, and one plan
  library. Rename one of them to keep them apart.

The macOS workspace tool consent ("Trust this folder?") is not keyed by project:
it stays tied to the resolved folder path, so it is asked again after a move.

## Data Management (Backup Export/Import)

The **Data management** entry of `/setup` (also available from first-run
setup, with no models configured yet) moves the whole `~/.zencode/`
directory between machines in one step:

- **Export backup** writes a single compressed `.tar.gz` archive containing
  every file under the support directory — including hidden files and
  nested directories such as `memory/`, `sessions/`, and `features/`.
  Temporary coordination artifacts of the export itself are excluded, and
  the archive is never added to itself when saved inside `~/.zencode/`.
  The Linux `voice/` directory is excluded as well: its programs and models
  are large and can be downloaded again from `/setup` > **Voice mode**.
  The export runs under the support directory's coordination lock, so the
  archive is a coherent snapshot of one moment in time rather than a mix
  of states captured while settings were being written. If the support
  directory contains a symbolic link, the export fails with an explicit
  error instead of silently skipping it — a backup that silently drops a
  link is worse than one that refuses to lie. Overwriting an existing
  archive keeps the old one until the new export is complete; a failure
  during the replacement restores the previous archive.
- **Import backup** validates the archive completely *before* touching any
  data — structure, version, per-file size and SHA-256 checksum, path
  traversal and symbolic-link rejection, and entry-count/size limits — and
  only then replaces the support directory in one atomic rename. The
  current data is moved aside and restored automatically if anything fails,
  so a failed or rejected import never leaves a half-replaced directory.
  The replacement also preserves the coordination lock file's inode, so
  concurrent processes keep a single shared exclusion boundary before,
  during, and after the swap. Because the whole directory is replaced, the
  Linux voice mode files are removed: download them again afterwards.
- **Clean memory** lists the memory graphs under `~/.zencode/memory/` (the
  current project, the global graph, and the other projects, with size and
  modification date), then lets you choose the rules to apply to one of them:
  remove archived entries unchanged for N days (default 30), archive entries
  that were never recalled and have not changed for N days (default 180, scaled
  per category), and graph hygiene (superseded entries, dangling links, links
  beyond 12 per entry, unused tags and clusters, unusable embedding vectors).
  The days are asked each time
  and never saved. A preview shows the counts and the titles that would be
  affected; nothing changes until you confirm (default No). The current graph is
  then copied to `memory.graph.json.bak` and its vectors to
  `memory.graph.json.vectors.bak` next to it, replacing any previous copy, and
  the cleanup is applied as one atomic transaction. The copy is never loaded by
  `zen`: to undo, close `zen` and copy the two files over `memory.graph.json`
  and `memory.graph.json.vectors`. See
  [Docs/memory.md](memory.md#memory-cleanup).
- **Delete project memory folder**, offered by **Clean memory** for the graph of
  another project only (not the current project and not the global graph),
  removes that project's whole memory directory after a confirmation that shows
  the exact path. No copy is kept: export a backup first if you may need it.
- **Rebuild memory embeddings** gives a vector from the configured embedding
  model to every active entry that lacks one, in every memory graph under
  `~/.zencode/memory/`, and deletes the vectors of archived entries. It uses
  the settings saved on disk; without an embedding endpoint it says so and
  does nothing. A list shows, per graph, the entries to embed and the archived
  vectors to delete, and the model; the content of each entry is sent to the
  endpoint, so nothing starts until you confirm (default Yes). Vectors are
  saved every 16 entries, busy endpoints (HTTP 429) are retried after a growing
  wait, and Esc stops after the requests in flight, keeping what was saved:
  run it again to resume. Setup offers the same run right after "save and
  exit" when the embedding configuration changed. See
  [Docs/memory.md](memory.md#memory-re-embedding).
- **Reset remote configuration** is the same reset previously found in the
  main setup menu, now grouped here with the other data operations.
- **Back** returns to the main setup menu. Cancelling any prompt leaves
  the data untouched.

Backups are **not encrypted**: they contain provider API keys, OAuth
tokens, and permissions in plain text, exactly as stored on disk. Keep the
archive private, and prefer a secure channel when moving it to another
machine. After a successful import, setup restarts so the imported
configuration is read from scratch.

The support directory actually used — including any `ZENCODE_SUPPORT_DIRECTORY`
override — is the one exported and imported, and every prompt prints the
exact paths involved.

## Command Line Options

```text
zen [-p PROMPT] [-f PATH] [--jsonl] [--version] [--doctor] [--install-features [id,id,...]] [--no-features] [--zen-package-path DIR] [--acp] [--agent NAME] [--model MODEL_ID] [--working-directory PATH] [--skills LIST] [--max-tool-rounds N] [--max-output-tokens N]
```

- `-p, --prompt PROMPT`: run one non-interactive turn. Redirected stdin, when
  present, is appended as additional context. Without `--jsonl`, stdout contains
  only the final assistant text.
- `-f PATH`: run one non-interactive turn whose prompt is read from the file at
  `PATH`, which must be an absolute path; relative paths, `~`, and `-` are
  rejected. The file is read when the run starts, as UTF-8 text, and trimmed.
  A missing, unreadable, empty, or non-UTF-8 file makes the run fail with exit
  status `1`. With `-p`, the file is appended as context, labelled
  `Additional context from file:`, whichever option comes first. Redirected
  stdin is still appended. `-f` cannot be repeated or combined with `--acp`.
- `--jsonl`: with `-p`/`--prompt` or `-f`, emit the versioned headless lifecycle
  and final response as JSON Lines. See the [JSONL protocol guide](jsonl.md).
- `--version`: print the ZenCODE version and exit.
- `--doctor`: print a redacted, read-only diagnostic report and exit. It never
  starts setup, accesses a provider, creates configuration, or writes a log.
- `--acp`: run ACP JSON-RPC over stdio.
- `--install-features [id,id,...]`: copy the requested optional feature package(s), build their release products, and enable them. With no IDs in an interactive terminal, opens the optional-feature picker.
- `--no-features`: skip optional-feature installation when used with `--install-features`.
- `--zen-package-path DIR`: use this ZenCODE checkout as the feature source and rewritten local package dependency. This is useful after a manual installation; platform installers preserve their checkout under `~/.zencode/source/` automatically.
- `--agent NAME`: select an agent profile (default: the project's default developer, normally `Developer`; see [agents.md](agents.md#profile-roles)).
- `--model MODEL_ID`: request a model override for the direct session; delegated sub-agents remain restricted to the selected profile's authorized bindings.
- `--working-directory PATH`: working directory for local tools.
- `--skills LIST`: initial skill selection by name/number, `all`, or `none`.
- `--max-tool-rounds N`: maximum model/tool loop rounds per prompt.
- `--max-output-tokens N`: maximum generated tokens per model call.

Environment variables mirror these: `ZENCODE_AGENT_MODE`, `ZENCODE_AGENT_NAME`, `ZENCODE_AGENT_MODEL`, `ZENCODE_AGENT_CWD`, `ZENCODE_AGENT_SKILLS`, `ZENCODE_AGENT_MAX_TOOL_ROUNDS`, and `ZENCODE_AGENT_MAX_OUTPUT_TOKENS`.

## Optional Feature Packages

Web, browser, Git, Swift, Jira, Figma, Xcode, and desktop integrations
are catalogued optional SwiftPM packages. They are **not** executable files
shipped next to `zen`, and the root `swift build` does not build them. Install
only the ones you need:

```bash
zen --install-features git-tools,swift-tools
zen --install-features                    # interactive picker
zen --install-features --no-features      # explicitly skip the picker/install
zen --install-features web-tools --zen-package-path /path/to/ZenCODE
```

The command copies each package into `~/.zencode/features/<id>/`, rewrites its
marked dependency on the ZenCODE checkout, creates the normal Builder-compatible
`feature.json`, builds its release product, then enables it. Consequently an
uninstalled feature remains visible as installable but contributes no available
tools to a profile or `/tools` selection. After installation, its package can be
selected and managed exactly like a local Builder feature. The Web feature
(`web.search`, `web.fetch`) is described in [web.md](web.md).

The **Features** step of `/setup` covers the same lifecycle. Its rows are
grouped as `Bundled`/`Generated` (check to enable, uncheck to disable),
`Installable` (not installed yet), and, only when source changes are available,
`Update installed`. That last group is hidden when every installed package
already matches the current ZenCODE source. Checking an `Update installed` row
reinstalls that package and rebuilds it; the reinstall also applies the enabled
state expressed by that feature's own row.

The macOS/Linux installers do not offer a feature picker: they install `zen`
only. They remove the legacy `zen-features/`
directory and, when bootstrapped from a temporary URL checkout, keep a
source-only copy at `~/.zencode/source/` so future installs still work after
that temporary checkout is removed. An installer launched from a local checkout
uses that checkout directly. Set `ZENCODE_SUPPORT_DIRECTORY` to relocate both
`features/` and the persisted `source/` copy.

`xcode-tools` and `desktop-tools` are macOS-only and are never offered on Linux.
`desktop-tools` (`desktop.run`) drives the real desktop — pointer, keyboard,
clipboard, windows, app lifecycle, and PNG screenshots that are attached to the
model's multimodal context — so macOS asks for Screen Recording and
Accessibility consent on first use. Call `action=permissions` before anything
else, and enable it only for a profile that is meant to control the machine.
macOS attributes those permissions to the app that launched zen (for example
Terminal), so that is the app to allow in System Settings. Screenshots are
delivered at point scale: one image pixel is one desktop point, and the
artifact's `desktop_bounds` and `points_per_pixel` convert image pixels into
click coordinates. `zoom` captures a region at native resolution (long edge at
most 2000 px) to read small details. Actions that can run code or end
processes ask for approval like `local.exec`; see the authorization notes in
[Terminal TUI Commands](#terminal-tui-commands).

## Diagnostics

Run `zen --doctor` when setup, permissions, or provider configuration looks
wrong. It reports environment, configuration state, sensitive-file privacy, and
the diagnostic-log status without printing API keys, OAuth tokens, or Telegram
credentials. A missing setup is a warning, so the command remains convenient in
scripts and clean installations.

The `Scheduled prompts` section reports on the tools behind
[scheduled prompts](#scheduled-prompts-crontab): it warns about a missing
`crontab` or `sendmail` and, on WSL, about the cron service. These are warnings
only; the exit code stays 0.

Local diagnostics are off by default and never use remote telemetry. Enable a
redacted system log explicitly when investigating an issue:

```bash
ZENCODE_LOG=debug zen
```

Diagnostics are emitted to the platform system log — Unified Logging on macOS
(subsystem `com.zencode.zen`, categories `diagnostics-*`) and syslog/journal on
Linux/WSL — with `ZENCODE_LOG` selecting the threshold (for example, `debug`,
`info`, `warning`, or `error`). They never write
to stdout, stderr, or an application-owned file, so ACP JSON-RPC output remains
clean. The legacy `ZENCODE_LOG_FILE` and `ZENCODE_LOG=stderr` destinations have
been removed and are reported as invalid by `zen --doctor`. Use `/tools logs`
to open the native system log viewer (Console.app on macOS). See
[security.md](security.md) for the protection model.

## Agent Profiles

Agent profiles live in `~/.zencode/agents.json` and are managed in setup. The
recommended profiles are `Developer`, `Builder`, `Minimal`, `Planner`,
`Reviewer`, and `Reporter`. Each defines a required `role` (`developer`,
`builder`, `minimal`, `planner`, `reviewer`, `reporter`, `organizer`, or
`promoter`), tools, an optional enforced `readOnly` core-tool policy, skills,
instructions, and model bindings. The role alone determines the kind of agent:
it decides the default agent and which profiles `/plan`, `/review`, and
`/feature` use, while the ID and the name carry no meaning. The recommended
profiles are the system profiles and have their role as ID (`developer`,
`planner`, …). An `agents.json` with a profile without `role` is invalid and
`/setup` offers to rewrite it. See [agents.md](agents.md#profile-roles).

Switch profiles in the TUI without restarting:

```text
/agents                 # menu: active agent and project profiles
/agents Builder         # by name
/agents 2               # by number
```

The `/agents` menu is a single multiple-selection list with `[x]` marks. The
active agent carries a ` *` and the cursor starts on it:

```text
> [x] Developer * - General software development; the default agent
  [x] Reviewer - /review delegates to it
  [ ] Pippo - /review delegates to it
```

- `Space` or `X` ticks or unticks the highlighted profile for the current
  project, `A` ticks all and `N` none.
- `Enter` saves the ticks and makes the highlighted profile the active agent.
  Confirming without moving the cursor keeps the current agent.
- `Esc` or `Q` cancels: nothing is saved and nothing changes.

The ticked profiles are the ones associated with the project, and they are the
only profiles the `sub-agents` tool can delegate to: the roster in the system
prompt lists just those and `agent.create` rejects any other profile. The
association is stored outside the repository in
`~/.zencode/projects/<project key>/agents.json`, keyed like the workspace
memory by the project name, so it follows a moved project folder (see
[Project key](#project-key)). A project with no saved
file sees only the system profiles (the recommended profiles, whose ID is their
role): only those are delegatable and the menu shows just those ticked; the
ticks apply from the first save. A saved selection is literal: an empty one
leaves no profile delegatable (the prompt then tells the model not to call
`agent.create`), and profiles created later are not added to it automatically.
Picking the active agent always offers every profile, regardless of the project
association. `/plan`, `/review`, and `/goal` delegate through the same tool:
`/plan` and `/review` use the profiles with the `planner` or `reviewer` role
that are visible to the project, letting the model choose when there are
several. When none is visible they always stop with an error, with or without a
saved selection (tick one with `/agents`). See
[agents.md](agents.md#project-agents).

Choosing a different agent resets the conversation so the new system prompt and
tools apply cleanly. If the selected profile has bindings, its default is used
when no model has been selected explicitly; `/models` always presents every
configured model and a manual selection overrides that default for the active
session. Changing only the project association keeps the conversation and
refreshes the roster in the system prompt in place.

Use `/setup` to inspect and configure the model bindings of every profile — see
[bindings.md](bindings.md) for how bindings, capability, and task complexity
drive delegation, and [agents.md](agents.md) for profile and sub-agent concepts.

## Terminal Prompt Editing

The live prompt supports cursor and word movement, history, multi-line drafts,
paste, command completion, and the shortcuts shown in its help row.

In the live terminal prompt, holding one of `a e i o u c n s y z` (or its
uppercase form) opens an inline picker for common accented variants. The original
letter stays in the draft while the hold is detected. Choose a numbered variant with
`1`–`8`, move the selection with `←`/`→` or `↑`/`↓`, confirm it with `Enter`, or
keep the original letter with `Esc`. While this picker is open, `Enter` chooses
the accent instead of sending the prompt and `Esc` dismisses the picker instead
of clearing the draft or stopping generation. Any other editing key dismisses
the picker and then performs its usual action.

This is a conservative fallback for terminal key streams that expose repeated
characters but no key-release event. It is enabled in every live terminal panel;
setup prompts and non-panel key reads are unchanged. ZenCODE does not change
operating-system keyboard preferences. Because timed manual repeats and automatic repeats
are indistinguishable, unusual typing rhythms can still produce a false positive,
and input or rendering delays can prevent a hold from being recognized. Repeated
letters may be briefly visible before detection is confirmed. If key repeat is
disabled, the stream contains too little information to open the picker. Network
latency in SSH or tmux sessions can also prevent the timing pattern from matching.

## Terminal TUI Commands

Commands start with `/`:

**Setup and navigation:**
- `/help` — show command help.
- `/setup` — save the current session, open setup, rebuild the runtime from the updated configuration, and restore the conversation.
- `/models` — show every configured model and choose the model for the current session.
- `/think` — open a menu to select the thinking level of the current model.
- `/ds4 status|power <1-100>|steer <scale>|hints on|off` — inspect and tune the in-process DS4 engine; available only when the current model has a DS4 runtime. Values are not persisted. See [DS4 local runtime](ds4.md).
- `/agents [list|<name>|<number>]` — open the agent menu: `Enter` switches the active agent, `Space`/`X` associates profiles with the current project (the only ones the sub-agents tool can delegate to); `list`, `<name>`, and `<number>` select directly. See [Agent Profiles](#agent-profiles).
- `/tools [all|none|tool-name|package-name|number]` — select exposed tool groups; `/tools logs` opens the platform system log viewer (Console.app on macOS).
- `/skills` — select or install prompt skills; `/skills uninstall` opens a multi-selection menu for removing app-installed skills.
- `/exit` — close the session.

**Sessions and memory:**
- `/sessions` — list and select saved sessions.
- `/sessions <name>` — save or overwrite a named snapshot. With a DS4 model it also writes the DS4 KV checkpoint (`<name>.ds4kv`) next to the snapshot.
- `/sessions save` — save the current session (derives a name from the first prompt if none is active); with a DS4 model it also writes the DS4 KV checkpoint.
- `/sessions compact` — force context compaction without saving.
- `/sessions new` — reset to a fresh, unsaved session.
- `/sessions delete` — delete a saved snapshot.
- `/sessions restore [entry-id]` — restore in-place from a checkpoint, branching from that point; without an argument an interactive picker over the checkpoint entries opens.

**Attachments:**
- `/attach` — open the terminal picker at the user's home directory to navigate and attach one image/video file to the next prompt. Press Esc or Q to cancel without changing pending attachments.
- `/attach <file> [file ...]` — attach image/video files from paths to the next prompt.
- `/attach list` / `/attach delete [all|number]`.

**Files and changes:**
- `/open [file-or-url]` — list and open referenced files/URLs, or open one directly.
- `/artifacts` — show the current session's file artifacts, grouped by turn; it accepts no arguments. See [Session File Artifacts](#session-file-artifacts).
- `/changes` — show tracked file change summary.
- `/changes diff` — include patches.
- `/undo` — revert the most recent agent-tracked changes.

**Voice:**
- `/voice on` / `/voice off` — start or stop voice mode in the interactive terminal, with any agent: each utterance becomes a prompt after a pause of about 5 seconds, or when it ends with a word you choose, and every final answer is read aloud in full, while the model is asked for short sentences; `Esc` stops the reading. The send mode and the pause are chosen in `/setup` > **Voice mode**. On Linux, download the speech files from `/setup` > **Voice mode** first.
- `/voice pause` / `/voice resume` — stop or restart both listening and reading aloud; a bare `/voice` toggles between them. Available while a prompt runs. See [voice.md](voice.md).

**Scheduling:**
- `/cron` / `/cron list` — show the `MAILTO` recipient and the scheduled prompts, each with its number, schedule, agent, working directory, output kind (`text` or `JSONL`), and prompt. See [Scheduled Prompts (crontab)](#scheduled-prompts-crontab).
- `/cron add [-json] [-agent <name>] <schedule> [-f <path>] <prompt>` — schedule a prompt for the working directory of the session. With `-agent <name>`, the job runs with that agent profile; without it, with the default developer of the project (normally `Developer`), whatever agent is selected in the session. With `-f <path>`, the prompt is read from that absolute file at every run, and the prompt may be omitted (see [Schedules](#schedules)). By default the mail holds the final answer text; with the `-json` option right after `add`, the job runs with `--jsonl` and the mail holds the JSONL records of the run (see [Results and mail](#results-and-mail)). The schedule is five numeric cron fields — minute 0-59, hour 0-23, day-of-month 1-31, month 1-12, and day-of-week 0-7 (0 and 7 = Sunday), each `*`, `*/step`, or a list of `n`, `a-b`, and `a-b/step` — with no month or day names, or one of `@reboot`, `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`. The prompt must fit on one line. `zen` must be installed in `/usr/local/bin` or another directory of the `PATH` of the ZenCODE crontab block, or the command is refused.
- `/cron remove <n>` — remove scheduled prompt `<n>`; the entries after it are renumbered.
- `/cron run <n>` — run scheduled prompt `<n>` now, the way cron runs it, in the background, and show the result in the terminal instead of mailing it.
- `/cron mailto [address|none|default]` — without an argument, show the address that receives scheduled-prompt results; with one, set it. `none` sends no mail; `default` removes the override and uses the local mailbox of the crontab owner.

**Task graph:**
- `/tasks [status|list]` — show the session task graph.
- `/tasks show <id>` — show one task with dependencies and attempts.
- `/tasks retry <id>` — return a failed/blocked task to `pending`.
- `/tasks cancel <id> [reason]` — cancel task and active worker.
- `/tasks clear` — remove all task graphs for the logical session.

**Agentic workflow:**
- `/plan <goal>` — delegate planning to a sub-agent using a profile with the `planner` role (the built-in `Planner` by default). It may ask numbered clarification blocks over multiple turns; normal replies continue that runtime-only discussion with the same Planner, while a new goal closes and replaces it. The same command family is routed by the linked Telegram chat and ACP. See [planner.md](planner.md).
- `/plan save` — save the active plan, or the latest non-empty assistant response, as a reusable unapproved draft in the current project's plan library.
- `/plan load` — when no plan is active, load the latest saved project plan into the current context as unapproved and pending. Use `/plan clear` first to replace an active plan; loading never resumes old execution attempts.
- `/plan status` — show plan progress from the graph state.
- `/plan approve` — activate the plan and start implementation.
- `/plan clear` — archive the graph and remove the active plan.
- `/goal <goal>` — autonomously inspect the workspace and context to turn the request into a concrete objective with testable acceptance criteria, then work until completion or a genuine blocker, executing directly or delegating when useful. It creates an active persistent workflow graph up front and keeps the DAG even for entirely direct work; sub-agent tools are optional. A normal model `end_turn` does not stop the command while that graph remains open and its workflow is `running`: ZenCODE automatically continues coordinating, executing directly or delegating, retrying, and validating until the graph is completed, the user explicitly cancels it, or the coordinator records `awaiting_user` (a material ambiguity) or `blocked` (a genuine unresolved blocker) through structured `tasks.update` workflow control. The text only explains the pause; no `Workflow question` heading is required. Paused workflows do not auto-retry. Your next message resumes the same graph. The original goal and workflow state are retained separately from tasks in the checkpoint and reinserted on continuation/resume, including workflows paused before task creation or after the last currently defined task completes. Completing tasks does not close `/goal`: after verifying the entire objective, the coordinator explicitly finalizes with `tasks.update`, `graphID`, the current `expectedRevision`, and `workflow: {state: "completed"}`. Legacy checkpoints remain readable with an explicit unavailable-objective fallback; only metadata-free legacy graphs retain the old heading protocol until adopted. It refuses to start while an active `/plan` exists; finish that plan or use `/plan clear` first. The current agent executes or coordinates the work and validates results, retaining its normal tool grant; `/goal` does not implicitly enable delegation or mutation tools. No separate Planner sub-agent, routine objective-confirmation step, or approval step. Use `/tasks` to monitor progress.
- `/review [focus]` — delegate review to sub-agents using the profiles with the `reviewer` role (the built-in `Reviewer` by default). See [reviewer.md](reviewer.md).
- `/feature` — manage Swift feature packages (profiles with the `builder` role, such as `Builder`, only). See [builder.md](builder.md).

**`/plan` vs `/goal`:**

| | `/plan` | `/goal` |
|---|---|---|
| **Planning** | Delegated to a sub-agent using the configured Planner profile | Done autonomously by the current agent after inspecting the request, workspace, context, and project conventions |
| **Approval step** | Yes — `/plan approve` activates the graph | No — starts immediately and continues automatically while its graph is open |
| **Task implementation** | The current agent works freely: directly or by delegating, as it sees fit | Direct or delegated work is recorded in the persistent DAG; the normal tool grant is unchanged |
| **Sub-agent selection** | The model decides per task if and when to delegate | Optional; select a compatible profile when delegation is useful |
| **Role of current agent** | Implementer (can delegate when useful) | Implementer, coordinator, and final reviewer |
| **Monitor progress** | `/plan status` or `/tasks` | `/tasks` |

### Live Agent Chat

While sub-agents are active, the coordinator and the agent instances share a
live, transient chat room. From the terminal **or linked Telegram chat**, address
it with a leading mention: `@coordinator` to message the live coordinator, `@all`
to reach the coordinator and every active agent, or a readable `@agent-name`
handle (derived from each instance's display name) to message it directly.
Autocomplete in the terminal lists every active agent by its readable handle;
routing always resolves back to the stable agent id behind the alias. Telegram
uses the same live-room routing for its linked session, including its native
replies to forwarded chat cards. The LLM side uses the `agent.message` tool with
the same destinations (`direct`, `operator`, `coordinator`, `peers`, `all`);
`operator` addresses only the human terminal operator. Every message is
available in the terminal's transient `Chat` reader; it is not rendered as a
message box in the main transcript. A coordinator or delegated agent already
working receives the message in the model-facing result of its next tool call,
replies immediately, and resumes its current work. If no further tool call
occurs, a synthetic coordinator turn or queued agent prompt is the fallback. A
direct turn started by the human operator normally replies with
`agent.message(to: "operator")`; if a provider instead completes with ordinary
final output, the runtime delivers that output to `operator` without involving
the coordinator or duplicating an explicit chat reply. The chat is in-memory and
never persisted; a session reset drops it. See the [Chat reader
states](#chat-reader-states) below and [agents.md](agents.md#messages).

#### Chat reader states

The terminal opens the reader with `Ctrl+Y` (`Ctrl+O` also works where the
terminal does not intercept it). The reader is a status-bar panel, separate
from the scrolling conversation transcript:

- **Closed with no messages:** the `Chat` panel is invisible and consumes no
  reserved rows.
- **Closed with messages:** the panel stays compact and shows the retained
  total plus the unread count, for example `Chat · 2 messages · 2 unread`.
- **Opened with no messages:** the panel remains compact, showing
  `Chat · 0 messages · Ctrl+Y close`; it does not create an empty body or
  footer.
- **Opened with messages:** the panel expands to show the selected message,
  unread count, and navigation hints. `Ctrl+Y` closes it back to the compact
  state.

Messages in every state remain out of the main transcript: the reader is the
only terminal rendering surface for these live chat entries.

### Saving and Loading Plans

`/plan save` stores a reusable copy for the current working directory. It uses
the active plan when one exists; otherwise it can promote the latest non-empty
assistant response into a plan. If that response is in the strict Planner format
(`Specifiche concordate`, a numbered `Implementation plan`, and a `Dependencies:`
line on its own line for every point), the plan is saved with its structured
tasks and dependencies; any other response is saved as a text-only plan. The
saved copy is reset to an unapproved draft with pending task statuses, while the
currently active plan is left unchanged.

To hand a plan to another session, start a new session with `/sessions new` (or
use any session for the same working directory with no active plan), then run
`/plan load`. The command selects the newest saved plan, displays it, and adds a
handoff message to the model context. It refuses to replace an active plan, so
run `/plan clear` first when necessary. Loading does not restore the source
session, its active attempts, or its execution progress; review or revise the
draft, then run `/plan approve` to begin implementation.

Approval creates and activates the plan's task graph in the receiving session.
A plan saved with structured tasks keeps them. For a saved text-only plan with
no structured items, ZenCODE creates one stable implementation task rather than
guessing a task breakdown from prose.

**Optional integrations:**
- `/telegram` / `/telegram on` / `/telegram off` — remote control (requires setup). Available even while a prompt is running.

Telegram pairs exactly one global owner through a private chat. That owner may route
multiple terminal sessions through a default private route or distinct private
`message_thread_id` topics; every route retains lifecycle, generation, lease and
wire-fence checks, including authorization prompts, voice notes and attachments.
Groups, shared members and per-route ACLs are not supported. Persisted routing uses
`routingVersion: 2`. Schema-1, ownerless or incoherent configurations remain
inactive and require a new pairing.

Voice notes sent to the paired chat are transcribed on the machine — on macOS
with Apple speech recognition, on Linux with the `/setup` > **Voice mode** files
plus `opusdec` or `ffmpeg` — and run as ordinary prompts. See
[voice.md](voice.md#telegram-voice-messages).

**Tool execution logs:** every direct tool call emits a secret-redacted structured
record through the platform system logger. Records include agent ID/name, model,
session, tool arguments, status, optional execution duration, and detailed typed
error causes; delegated agents are logged with the child's identity. On macOS the
records use Unified Logging subsystem `com.zencode.zen` and category
`tool-execution`. Use the exact command `/tools logs` to open Console.app. Console
does not accept a preconfigured filter when ZenCODE opens it, so paste
`c:tool-execution` into Console's search field and press Return. Then click
**Save**, give the search a name such as **ZenCODE**, and reuse it from Console's
Favorites whenever needed. Launcher failures are reported in the terminal and
never written to ACP stdout.

**Interactive shortcuts:**
- `Ctrl+G` — toggle default/full access mode (temporary, never persisted).

**Prompt editing shortcuts:**

These bindings follow the Emacs/readline conventions, so they work on every terminal, including laptop keyboards without `Home`/`End` keys. Terminals never receive `Command` shortcuts, so the macOS `Cmd+←`/`Cmd+→` motions are not available.

| Motion | Keys |
| --- | --- |
| Character left/right | `←`/`→`, `Ctrl+B`/`Ctrl+F` |
| Word left/right | `Alt+←`/`Alt+→`, `Ctrl+←`/`Ctrl+→`, `ESC b`/`ESC f` |
| Line start/end | `Ctrl+A`/`Ctrl+E`, `Home`/`End` |
| Draft start/end | `Alt+<`/`Alt+>`, `Ctrl+Home`/`Ctrl+End` |
| Previous/next line or history entry | `↑`/`↓`, `Ctrl+P`/`Ctrl+N` |
| Delete word before/after | `Ctrl+W` / `Alt+D` |
| Clear before/after cursor | `Ctrl+U`/`Ctrl+K` |
| Clear the whole draft | `Alt+Backspace` (macOS `Option+Delete`) |
| Newline without sending | `Shift+Enter` or `Option+Enter` |

On macOS, `Option+←/→` only reaches the prompt when the terminal sends the `Option` key as `Meta`: in Terminal.app enable *Settings → Profiles → Keyboard → Use Option as Meta key*, and in iTerm2 set *Settings → Profiles → Keys → Left Option key → Esc+*. `Ctrl+←/→` is captured by macOS Mission Control unless that system shortcut is disabled. `Ctrl+A`/`Ctrl+E` and `Alt+<`/`Alt+>` need no terminal configuration.

Full access bypasses the `local.exec` and destructive-tool approval checks, including `desktop.run` consent. It does not expose disabled tools or bypass OS permissions. The status bar shows a red dot while active.

`local.exec` authorization filters shell noise so that only significant commands trigger approval. Comments, decorative `echo`/`printf` (without output redirections), harmless built-ins (`true`, `false`, `cd`, `pwd`, …), environment assignments, wrappers (`env`, `command`, …), and control-flow keywords are stripped or skipped. Nested commands inside shell `-c` payloads, `$(...)`/backtick command substitutions, process substitutions `<(...)`/`>(...)`, and unquoted heredoc bodies are recursively inventoried, while `$((...))` arithmetic expansion and quoted heredoc bodies are treated as literal. Extended `[[ ... ]]` expressions, arithmetic `(( ... ))` commands, and `case` pattern alternatives remain opaque during pipeline segmentation, so regex, bitwise, and pattern `|` characters are not mistaken for shell pipes. Wrapper options that consume an operand (`env -u NAME`, `env -C DIR`, `time -o FILE`) are handled so the real executable surfaces, and introspection-only forms (`command -v`) are not authorized as executions. When parsing hits its recursion or candidate limits it fails closed by emitting a conservative fallback candidate. Each `local.exec` tool call presents one authorization request containing the full command; all parsed executable identities still participate in cache and persistence checks.

The terminal consent prompt makes the scope of **Always** explicit: for
`local.exec`, it remembers every parsed executable identity in the request across sessions; for
destructive direct tools it grants only the current process/session and is not
persisted. Use **Run once** when the broader executable-level approval is not
intended.

`desktop.run` uses the same destructive-tool consent, but only for actions
that can run code or end processes: `open` of anything other than a plain
http/https URL (local files, `file:` URLs, other schemes, or an app given by
path), `launch_app` and `activate_app` from an app path, and every
`terminate_app`. The prompt shows the equivalent command, for example
`open /path/run.command`, `open -a /tmp/Tool.app https://example.com`, or
`terminate_app --force --pid 4242 # loginwindow` (a pid is shown with its
process name). Screenshots, input, window actions, and plain web URLs run
without a prompt.

Delegated sub-agents ask for the same approvals as the coordinator. Their requests are routed on a runtime-minted delegation identity (the agent instance plus the operator session that owns its delegation tree) instead of the turn that spawned them, because delegated work keeps running after that turn returns. The prompt names the requesting agent, and a request whose root session is unknown to the runner is refused without asking. Full access bypasses these requests exactly as it does the coordinator's.

## Scheduled Prompts (crontab)

`/cron` runs prompts at set times, even when no ZenCODE session is open. Each
scheduled prompt is an entry in the crontab of the system user who runs
ZenCODE: when the entry is due, cron starts a headless `zen -p` or `zen -f`
turn and its output is mailed (see [Results and mail](#results-and-mail));
with the `-json` option the turn also gets `--jsonl`, and the mail holds the
JSONL records of the run. There is no daemon,
no launchd or systemd unit, and no lock against overlapping runs: cron starts
each entry when it is due, so if one run is still going when the next one is
due, the next run starts anyway, as with any cron job.

`/cron` is a command of the interactive terminal; its subcommands are listed
under [Terminal TUI Commands](#terminal-tui-commands). It is the only surface:
Telegram and ACP do not offer it, there is no `zen` subcommand for scheduling,
and the model has no tool to create or change scheduled prompts.

### Quick start

```text
/cron add 0 9 * * 1-5 Summarize the open pull requests
/cron add -agent Organizer 30 7 * * 1-5 Prepare my daily briefing
/cron add -json @daily Summarize the open pull requests
/cron add @daily -f /Users/me/prompts/report.md
/cron list
/cron run 1
/cron mailto me@example.com
/cron remove 1
```

`/cron add` needs `crontab` and a `zen` that cron can find, normally the one
that `Scripts/install.sh` and `Scripts/install-linux.sh` install in
`/usr/local/bin` (see [The `zen` that cron runs](#the-zen-that-cron-runs)).
Results arrive by mail: through `sendmail`, or through Mail.app on macOS when
`/cron mailto` holds an email address (see
[Results and mail](#results-and-mail)). `zen --doctor` reports a missing
`crontab` or `sendmail`.

`/cron add` replies with the line it wrote, the working directory the job runs
in (always the one of the session where you typed the command), and the `zen`
that cron will run:

```text
Scheduled prompt #1 added:
  0 9 * * 1-5 zen --working-directory '/Users/me/Projects/app' -p 'Summarize the open pull requests'
  dir: /Users/me/Projects/app (working directory of this session)
  zen: /usr/local/bin/zen (PATH=/usr/local/bin:/usr/bin:/bin)
```

`/cron list`, or `/cron` alone, shows the mail recipient and one numbered row
per scheduled prompt, including whether it mails the answer text (`output: text`)
or the JSONL records (`output: JSONL`). An entry that reads its prompt from a
file shows `file: <path>` after the output kind; `prompt: …` appears only when
the entry has a prompt:

```text
Scheduled prompts — MAILTO: not set (cron default: local mailbox of the crontab owner)
  1. 0 9 * * 1-5 · agent: default · dir: /Users/me/Projects/app · output: text · prompt: Summarize the open pull requests
Results are mailed by cron; set the recipient with /cron mailto <address>.
```

`/cron run <n>` and `/cron remove <n>` take the number shown by `/cron list`.
The number is the position of the entry in the crontab, so after a removal the
following entries move up by one: list again before using a number. Entries are
never edited in place; to change one, run `/cron remove` and then `/cron add`.

Subcommands and the `none` and `default` keywords are case-insensitive; the
options `-json`, `-agent`, and `-f` are exact and case-sensitive, so `-JSON`,
`JSON`, and `json` are not the `-json` option. Completion continues after the
subcommand: `/cron add ` offers the schedule aliases, example schedules,
`-json`, and `-agent`, and the other slots (agent name, cron fields, prompt,
`<n>`, `mailto`) show a one-line guide that is never inserted.

### Schedules

In `/cron add [-json] [-agent <name>] <schedule> [-f <path>] <prompt>`, an
optional leading `-json` option selects JSONL output (see
[Results and mail](#results-and-mail)); only the word right after `add` is the
option, so `/cron add @daily -json report` schedules a text job whose prompt is
`-json report`. Then `-agent` followed by a name selects the agent profile of
the job (see [What a scheduled run does](#what-a-scheduled-run-does)). Then a
first word that starts with `@` is the whole schedule; otherwise the first five
words are the schedule. The rest of the line is the prompt. If it starts with
`-f`, the next word, or the quoted text, is the path of a prompt file, and what
follows is the optional prompt.

`-agent` is recognized only right after `add`, or right after `-json`, and only
in lower case. `--agent` is the flag of the `zen` command line, not an option of
`/cron add`: typed after `add`, it is schedule or prompt text. The name is
quoted like the path of `-f`: wrap it in single or double quotes to include
spaces. After `-agent`, completion shows an `<agent>` guide and then completes
the schedule.

`-f` is recognized only as the first word right after the schedule, and only in
lower case. The path must be absolute, starting with `/`. Wrap it in single
(`'…'`) or double (`"…"`) quotes to include spaces; there are no escapes
inside the quotes. With a prompt, the prompt is the instruction and the file is
the context, as with `zen -p … -f …`; without one, the file is the whole
prompt. After the schedule, completion offers `-f` next to the `<prompt>` guide;
after `-f`, it shows a `<path>` guide and then an optional `<prompt>` guide.

| Alias | Runs |
| --- | --- |
| `@hourly` | every hour, at minute 0 |
| `@daily`, `@midnight` | every day at midnight |
| `@weekly` | every Sunday at midnight |
| `@monthly` | on the 1st of each month at midnight |
| `@yearly`, `@annually` | every 1 January at midnight |
| `@reboot` | when cron starts, normally at system startup |

Aliases are case-insensitive. The five fields are, in order:

| Field | Values |
| --- | --- |
| minute | 0-59 |
| hour | 0-23 |
| day of month | 1-31 |
| month | 1-12 |
| day of week | 0-7 (0 and 7 = Sunday) |

Each field is `*`, `*/<step>`, or a comma-separated list of `<n>`, `<a>-<b>`,
and `<a>-<b>/<step>`. Only numbers are accepted: month and day names such as
`jan` or `mon` are rejected, and so are extensions such as `L`, `W`, `?`, and
`#`. A step needs `*` or a range: write `*/10` or `5-59/10`, not `5/10`.

| Schedule | Runs |
| --- | --- |
| `0 9 * * 1-5` | weekdays at 09:00 |
| `*/15 * * * *` | every 15 minutes |
| `30 18 * * *` | every day at 18:30 |
| `0 8-18/2 * * 1-5` | every two hours from 08:00 to 18:00 on weekdays |
| `0 7 1,15 * *` | at 07:00 on the 1st and the 15th of each month |

Cron reads these times in the time zone of the system.

The prompt is trimmed and must fit on one line; without `-f`, it must also not
be empty. Quotes and `%` are allowed, because ZenCODE quotes and escapes the
prompt for cron. With `-f`, the file must exist and be readable, be UTF-8 text,
and not be empty; its path must not contain a line break. With `-agent`, the
name must match the ID or the name of an existing agent profile, ignoring case
and diacritics as `zen --agent` does; otherwise `/cron add` is refused with the
list of available agents. The schedule, the prompt, the file, and the agent are
checked before the crontab is read, so a rejected `/cron add` changes nothing.

### What a scheduled run does

Each entry runs ZenCODE in headless mode:

```text
[ZENCODE_SUPPORT_DIRECTORY='<value>' ]zen [--agent '<name>'] --working-directory '<TUI session working directory>' [--jsonl] [-f '<path>'] [-p '<prompt>']
```

At least one of `-f` and `-p` is present, and `-f` comes first when both are.
`--jsonl` is present for entries added with `-json` and for entries written by
earlier versions of ZenCODE, which always used it. The file of an `-f` entry is
read again each time the entry runs, so later edits apply to the next runs; its
content is never copied into the crontab. If the file is missing or invalid when
a run starts, that run fails, and its error is mailed as described in
[Results and mail](#results-and-mail).

`--agent` is present in the line only for entries added with `-agent`, with the
name as you typed it. An entry without `-agent` is listed as `agent: default`
and runs with the default developer of its working directory's project
(normally `Developer`), as `zen -p` does; the agent selected in
the session where you type `/cron add` is never used.

`/cron add` takes two things from the session where you type it:

- the working directory of the session;
- `ZENCODE_SUPPORT_DIRECTORY`, only when it is set in the environment of that
  session.

Nothing else carries over. Each run is a new headless turn without the
conversation, and the choices made with `/agents`, `/models`, `/tools`, or
`/skills` do not apply: the model and skills come from the agent profile when
the entry runs, so later changes to the profile also change later runs. If the
profile is renamed or deleted, every run fails with an error; remove the entry
and add it again with an existing profile.

Arguments use single-quote shell quoting, and each `%` is escaped as `\%`,
because cron turns an unescaped `%` in a command into a newline.

The non-interactive policy of `zen -p` and `zen -f` applies unchanged. A tool
that would ask for approval is denied, except for approvals already saved with
"always allow". With `-json`, a denied tool appears in the output as a
`tool.completed` record with status `permissionDenied`. In both modes the agent
continues without it.

### The crontab block

The crontab is the only source of truth: no file is added under `~/.zencode`.
ZenCODE reads and replaces the whole crontab with the standard `crontab -l` and
`crontab -` commands, and runs `crontab -r` when nothing is left. It owns one
block delimited by `# >>> ZenCODE cron >>>` and `# <<< ZenCODE cron <<<`. The
block starts with a `PATH=` line and, when set, a `MAILTO=` line. Each
scheduled prompt is two lines after them: a marker line,
`# zencode-cron id=<UUID> created=<ISO8601 UTC>`, followed by the cron line.

```text
# >>> ZenCODE cron >>>
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=me@example.com
# zencode-cron id=3F2C9A7E-5B1D-4C8E-9A61-0D2E7B4F8C15 created=2026-10-25T07:30:00Z
30 7 * * 1-5 zen --agent 'Organizer' --working-directory '/Users/me/Projects/app' -p 'Summarize the open issues and unread mail'
@daily zen --working-directory '/Users/me/Projects/app' --jsonl -p 'Summarize the open pull requests'
# <<< ZenCODE cron <<<
```

Lines outside the block stay byte-identical and in their original order. The
block is always written at the end of the crontab, after a blank line; lines
found after it, for example after a manual edit, are moved above it. Variable
assignments that come before the block, such as `SHELL=` or your own
`MAILTO=`, also apply to ZenCODE entries, except `PATH`, which the block sets,
and `MAILTO` once the block has its own.

The crontab can also be edited by hand:

- An entry is a marker line followed by a cron line. When that cron line runs
  a command that ZenCODE did not write, `/cron list` shows it as
  `command: …`, and it can still be run and removed. A line edited to run
  `zen` by a quoted absolute path, such as `'/opt/zen/bin/zen'`, is still read
  as a ZenCODE entry.
- Any other line inside the block is listed as `(unrecognized)`. It has a
  number and can be removed, but not run.
- A begin marker without its end marker, or a second block, makes every `/cron`
  command stop with `The ZenCODE block in your crontab is malformed` before it
  writes anything. Fix the crontab with `crontab -e`, keeping one pair of
  markers.
- A crontab that is not valid UTF-8 is never rewritten; convert it to UTF-8
  with `crontab -e` first.

### The `zen` that cron runs

Each cron line starts `zen`, without a path. Cron gives its jobs only
`PATH=/usr/bin:/bin`, which does not include `/usr/local/bin`, where
`Scripts/install.sh` and `Scripts/install-linux.sh` install `zen` by default. So
the block starts with `PATH=/usr/local/bin:/usr/bin:/bin`. The block is always the
last part of the crontab and cron applies a variable assignment only to the lines
after it, so this `PATH` affects the ZenCODE entries and nothing else. The
commands that the agent runs during a scheduled prompt see `/usr/local/bin` in
their `PATH` as well.

`zen` must therefore be installed in `/usr/local/bin` or in another directory of
the block's `PATH`. `/cron add` looks for an executable `zen` in that `PATH` and,
when there is none, refuses to schedule and writes nothing to the crontab. When it
succeeds, its confirmation names the binary cron will run, for example
`zen: /usr/local/bin/zen (PATH=/usr/local/bin:/usr/bin:/bin)`.

The `PATH=` line can be edited by hand, for example to add `/opt/homebrew/bin` or
the directory where you keep a private build; use absolute directories, because
cron does not expand `~` or `$HOME`. ZenCODE keeps a customized `PATH=` line when
it rewrites the block, and `/cron add` and `/cron run` use it. A block without a
`PATH=` line, such as one written by hand, gets the default line the next time
ZenCODE writes the crontab; entries that run `zen` by an absolute path keep
working. A block with no entry and no `MAILTO=` line, for example after the last
entry is removed, is deleted whole, customized `PATH=` included.

### Results and mail

Cron mails what each run prints, through the system `sendmail`, in the body of
the mail; cron itself never attaches files. On macOS, `zen` can deliver the mail
through Mail.app instead, and then it attaches the answer as a Markdown file
(see [Delivery through Mail.app (macOS)](#delivery-through-mailapp-macos)). By
default (`/cron add <schedule> <prompt>`) standard output holds only the final
answer text, which is the mail body. When
the run fails, `zen` writes `ZenCODE: <message>` and a troubleshooting hint to
standard error and exits with status 1, and cron mails that too.

With the `-json` option (`/cron add -json <schedule> <prompt>`), standard output
holds the [JSONL records](jsonl.md) of the run: `run.started`, the tool
records, the final answer in `message.completed`, and `run.completed`, or an
`error` record when the run fails. They land in the mail body as they are. In
JSONL mode `zen` writes nothing to standard error, so standard error only
carries messages from the shell, for example when it cannot find `zen`. Entries
written earlier, with `--jsonl` in their line, keep their JSONL output.

Cron sends a mail whenever a run prints anything, which is every run in
practice, unless mail is disabled.

By default the mail goes to the local Unix mailbox of the crontab owner, which
you read with the `mail` command. On macOS this works without configuration,
because Postfix starts on demand.

`/cron mailto` without an argument shows the recipient. `/cron mailto <address>`
writes `MAILTO=<address>` in the ZenCODE block, right after its `PATH=` line, so
it applies only to ZenCODE entries. The address must be one word without spaces
or double quotes; ZenCODE does not check it further. `/cron mailto none` writes
`MAILTO=""`, and cron sends no mail. `/cron mailto default` removes the
`MAILTO` line and restores the local mailbox, or the `MAILTO=` set earlier in
your crontab.

To send mail through `sendmail` to an external address such as a Gmail account,
the system MTA must relay through an SMTP server. Configure Postfix with
`relayhost` and SASL credentials in `/etc/postfix/main.cf`; ZenCODE does not
configure this. On Linux, install an MTA that provides `sendmail`, such as
postfix, exim, or msmtp; otherwise cron's output is discarded.

#### Delivery through Mail.app (macOS)

Many networks block outbound port 25, so a message that cron hands to the local
`sendmail` never leaves the Mac. On macOS, when `zen` runs headless with
standard output not connected to a terminal and `MAILTO` holds an address with
`@` (which is how cron starts a job of the ZenCODE block after
`/cron mailto <address>`), `zen` does not leave the mail to cron. It captures
what it would have printed and sends it as one message from the default account
of Mail.app, through the `macos.mail` tool of the `macOS` feature, which must be
installed (`zen --install-features macOS`) and enabled (`/tools`). Then it
prints nothing, so cron sends no second message. The exit status stays that of
the run. Without `MAILTO`, with a bare user name, or after `/cron mailto none`,
nothing changes and cron handles the output as described above.

The subject is `ZenCODE cron: <label> – <yyyy-MM-dd>`, or
`ZenCODE cron failed: <label> – <yyyy-MM-dd>` when the run failed. The label is
the name of the prompt file or, without one, the inline prompt on one line,
shortened to 60 characters with `…`; with no label, `: <label>` is left out.

For a text job, the body is the final answer converted from Markdown to plain
text, because Mail.app driven by a script sends only plain text:

- Headings lose their `#` and stand on a line of their own. Bold, italic,
  strikethrough, and inline code lose their symbols.
- Lists use `•` (nested levels are indented and use `◦`) and `1.`; task items
  show `[x]` and `[ ]`.
- Links become `text (url)`, or only the URL when both are the same. Images
  become `alt (url)`.
- Code blocks are indented by four spaces, without the backticks.
- Quotes start with `│ ` instead of `>`, which mail clients hide as quoted
  text.
- Horizontal rules become a line of `─`.
- Every row of a table becomes a block of `Header: value` lines.

The answer, as written, is attached as `<name>-<yyyy-MM-dd>.md`, where `<name>`
is the prompt file name without its extension or, without one, the inline
prompt; for example `report-2026-10-28.md`. There is no attachment when the
answer is empty. The file is written to the `zencode-cron-mail` folder of the
per-user temporary directory, and a later delivery removes it once it is at
least one hour old.

If the attachment cannot be written, or Mail.app cannot send the message with
it, `zen` sends the message again without the attachment, ending with the line
`ZenCODE: the Markdown file could not be attached: <reason>`. Only if that send
fails too does the fallback below apply.

If Mail.app cannot send the message at all, for example because the `macOS`
feature is not installed or enabled, `zen` prints exactly what it would have
printed without Mail.app, with the Markdown of the answer as written, plus one
line on standard error:
`ZenCODE: Mail.app delivery to <address> failed: <reason>`. Cron then mails that
output through its own `sendmail`, which on many networks does not leave the
Mac.

`-json` jobs are not converted and have no attachment: the body holds the
JSONL records as they are. Error messages on standard error are mailed as they
are. `/cron run` never uses this delivery, because its minimal environment has
no `MAILTO`, so its result stays in the chat. Runs from a terminal are not
mailed either. On Linux there is no delivery through Mail.app: the mail always
goes through cron's `sendmail`.

### Running an entry now

`/cron run <n>` runs entry `<n>` at once, the way cron would: with `/bin/sh -c`,
a minimal environment (`HOME`, `LOGNAME`, `USER`, `SHELL=/bin/sh`, and `PATH`),
the working directory set to `HOME`, and empty stdin. `PATH` is the one of the
ZenCODE block (`/usr/local/bin:/usr/bin:/bin` unless you edited it), so `zen` is
found exactly as under cron. Other variable assignments elsewhere in the crontab
are not applied. The run happens in the background, so the TUI stays responsive.
At most one `/cron run` can be in progress per session; a second request is
refused until the first one finishes.

Unlike cron, `/cron run` sends no mail: ZenCODE reads the output itself and
keeps up to 1 MiB of standard output and 64 KiB of standard error. It refuses
an `(unrecognized)` line; an entry with a command that ZenCODE did not write
runs as written.

When the run ends, the terminal shows a report:

```text
Scheduled prompt #1 finished in 12.3s with exit status 0.
Result:
Two pull requests are open; both pass CI.
```

The first line gives the duration and the exit status: `0` for success, `1`
when the run failed, `127` when the shell found no `zen`, and 128 plus the
signal number when a signal stopped it. Then comes the result. For a text entry
it is the text that the run printed on standard output, trimmed, or
`No output on stdout.` when there is none. For a JSONL entry, and for an entry
with a command that ZenCODE did not write, it is the text of the last
`message.completed` record; without one, `Error (<category>): <message>` from
the last `error` record, or `No JSONL result on stdout.`. The last 20 lines of
standard error follow, when there are any. Use it to check that `zen` is found
and that the working directory and the approvals work in the cron environment.
The report is shown only in the terminal; it is not forwarded to Telegram.

Leaving the chat with `/exit`, `/setup`, or the end of input stops a run in
progress: ZenCODE sends it SIGTERM, then SIGKILL after 3 seconds, and prints no
report.

### Platform notes

- macOS and Linux are fully supported.
- macOS protects Documents, Desktop, and Downloads. When the working directory,
  or a prompt file added with `-f`, is in one of them, grant Full Disk Access to
  `/usr/sbin/cron` in System Settings > Privacy & Security > Full Disk Access.
- WSL does not start the cron service by itself. Start it with
  `sudo service cron start`, or enable systemd in `/etc/wsl.conf`.

Run `zen --doctor` to check the system tools. Its `Scheduled prompts` section
reports a missing `crontab`, looked for in `/usr/bin` and `/bin`, or a missing
`sendmail`, looked for in `/usr/sbin` and `/usr/lib`; `/cron` uses the same
locations and does not search `PATH`. On WSL it always reminds you to start
the cron service. These are warnings only; the exit code stays 0. See
[Diagnostics](#diagnostics). The doctor does not check that `zen` is on the
block's `PATH`, which `/cron add` does, or Full Disk Access on macOS.

### Errors and fixes

| Message | Cause and fix |
| --- | --- |
| `crontab is not installed; see zen --doctor` | No executable `crontab` in `/usr/bin` or `/bin`. Install cron. |
| `crontab failed with exit status …` | `crontab` refused the operation; the rest of the message is its error. A common cause is a user who is not allowed to use cron (`cron.allow`, `cron.deny`). |
| `The ZenCODE block in your crontab is malformed: …` | The block has no end marker, or there are two blocks. Fix it with `crontab -e`. |
| ``cron runs `zen` with PATH=…, but no executable zen was found there. …`` | Install `zen` in `/usr/local/bin`, or add its directory to the block's `PATH=` line. Nothing was written. |
| `Invalid cron schedule (<field>): …` | See [Schedules](#schedules). Nothing was written. |
| `The prompt cannot be scheduled: …` | The prompt is empty or has a line break. Nothing was written. |
| `Invalid MAILTO value '…'. …` | The address has a space or a double quote. To disable mail, use `/cron mailto none`, as the message says. |
| `No scheduled prompt #<n>. Use /cron list.` | No entry has that number. |
| `Scheduled prompt #<n> is not a recognized ZenCODE entry.` | `/cron run` on an `(unrecognized)` line. |
| `A /cron run is already in progress (#<n>). Wait for its report.` | Only one `/cron run` at a time per session. |
| `Usage: /cron …` | Unknown subcommand, or a missing or extra argument. |

When a scheduled prompt seems never to run, or its mail never arrives:

- run it with `/cron run <n>` and read the report;
- read the local mailbox with `mail`, and check with `/cron mailto` that mail
  is not disabled;
- on Linux, check that an MTA provides `sendmail`; without one, cron discards
  the output;
- on WSL, check that the cron service is running;
- on macOS, a working directory in Documents, Desktop, or Downloads needs Full
  Disk Access for `/usr/sbin/cron`.

## Tool Selection

Core tool groups are filesystem, shell, text, search, memory, and sub-agents; Git, generated Swift features, and installed optional feature packages such as XcodeTools on macOS or FigmaTools come in addition. Use `/tools` to select per session. ACP clients pass enabled tools directly.

### Search tools moved into the core

`search.glob`, `search.grep`, and `search.locate` were the optional
`search-tools` feature package. They are now core tools of `zen`: their names
and arguments are unchanged, they run inside `zen` like the `files` and `text`
tools, they work on macOS and Linux, and they need no installation. `/tools`
lists them as the **Search** group, whose key is `search`, and the recommended
Developer, Builder, Reviewer, Reporter, and Planner profiles select it. They
only read, so a `readOnly` profile such as Reviewer or Planner keeps them.

What this means for an existing setup:

- **Profiles and selections keep working.** `feature:search-tools` and
  `search-tools` are still accepted as aliases of `search` in `agents.json`, in
  tool selections, and in saved sessions. Nothing is rewritten when `zen`
  starts: the key becomes `search` the next time ZenCODE saves your profiles.
- **An installed copy is ignored.** A package installed in
  `~/.zencode/features/search-tools/` (or under `ZENCODE_SUPPORT_DIRECTORY`) is
  neither loaded nor listed. ZenCODE does not delete it; remove the folder
  yourself when you no longer want it.
- **It can no longer be installed.** `zen --install-features search-tools` now
  fails with `Unknown optional Swift feature: search-tools.`: the package is no
  longer in the optional-feature catalog, so the picker does not offer it.
- **`search.` is a reserved core prefix**, like `local.` and `text.`: an MCP
  bridge feature cannot use it as its `toolPrefix`.

No persisted file format changes.

### Local file editing

`local.editFile`, `local.multiEdit`, and `local.replace` accept only the canonical `old`/`new` payload fields; the legacy aliases `oldString`, `old_string`, `newString`, and `new_string` are not supported. Empty or ambiguous matches are rejected, existing line endings are preserved, and `local.multiEdit` applies its edits atomically. Successful `local.editFile` and `local.multiEdit` responses are compact confirmations containing only the path and replacement/edit count; they do not return post-edit context or diffs.

## Task Orchestration

`todo.*` is a lightweight checklist for model-local coordination. `tasks.*` operates on the authoritative session task graph owned by `SessionTaskOrchestrator` — a validated DAG with atomic creation, dependency gating, optimistic fencing, and attempt history.

When work has multiple units, dependencies, or concurrent delegation, the coordinator creates a task graph first, then selects runnable work with `tasks.list` and assigns delegated tasks through `agent.create(taskID:)`. Each task carries a `complexity` (1–10) that is matched against the capability of the chosen profile's model binding — see [bindings.md](bindings.md). Report-agent success completes a task; implementation-agent success moves it to `awaiting_validation` until independently validated. Record a successful validation as completion. For negative validation, record `failed` with `tasks.update`, call `tasks.retry` to return the task to `pending`, then use a **new** `agent.create(taskID:)` to claim the new attempt. Do not use `agent.message` to reopen the already completed agent.

`/goal` uses a distinct graph source to preserve automatic continuation and prevent replacement of an unfinished workflow. Direct tasks declare `execution.executor: coordinator` and use `tasks.update` from `pending` to `in_progress` (creating an attempt), then `completed` after validation. Delegated tasks declare `execution.executor: sub_agent` and are claimed through a canonical `agent.create` `agents` item containing `taskID`. Successful delegated attempts still enter `awaiting_validation`, even if their task was originally declared for direct execution; negative validation remains `failed` and requires `tasks.retry` plus a new attempt. Direct work follows ordinary coordinator transitions, including `blocked` and retry. The workflow remains open even when every current task is completed, so the coordinator can add newly discovered work or pause for clarification on the same graph. Only an explicit root-coordinator `tasks.update` with `workflow: {state: "completed"}` finalizes it, using the current graph revision from `tasks.list`; the graph must be nonempty and all tasks completed and validated. Manual and plan graphs still complete automatically. These lifecycle checks do not automatically verify semantic goal completion and do not expand any tool grant.

Checkpoints are written atomically under `~/.zencode/task-graphs/<project key>/` (see [Project key](#project-key)).
`/plan save` reuses this checkpoint directory rather than creating a separate
plan store. It writes a draft copy of the active plan, or the latest non-empty
assistant response, to a stable project plan-library logical session, so
`/sessions new` may delete the live chat checkpoint without deleting explicitly
saved plans. Todo-derived items remain graph tasks, while optional metadata
carries the full goal and plan text needed by `/plan load`. `/plan load` selects
the newest saved draft only when no plan is active, adds its handoff to the
current model context, and does not activate its source session or resume old
execution state. Saved drafts are excluded from the interrupted-work startup
picker.
At interactive startup, ZenCODE enumerates every incomplete graph for the
current project and lets the operator resume one or delete obsolete graphs. A
selection is keyed by `sessionID + graphID`: the orchestrator restores the
owning session, makes the selected graph current, and persists that choice
before the backend session starts. Other active graphs from the same checkpoint
are archived when the selected graph takes ownership. Active attempts found
during restore are marked `interrupted` and their tasks become `blocked` rather
than being silently resumed. See
[Recovering Incomplete Tasks at Startup](#recovering-incomplete-tasks-at-startup).

## Skills

```text
/tools logs                       # open the platform system log viewer
/skills                          # select or install skills
/skills uninstall                # remove app-installed skills
zen --skills all                 # initial selection at launch
zen --skills "review,swift"
```

## Saved Sessions

```text
/sessions my-feature             # save named snapshot
/sessions save                   # refresh active snapshot
/sessions compact                # force context compaction
/sessions                        # list and load
/sessions delete
/sessions new                    # fresh, unsaved session
```

### Checkpoint Trees

Every saved session stores its conversation as a **tree of entries** alongside the flat message history. The initial history is a linear tree: every message is an entry. Entries are linked to their parent via an entry ID, so you can branch from any point and explore alternatives without losing the original path.

```text
/sessions save                   # persist the checkpoint tree to disk
/sessions restore                # restore via interactive entry picker
/sessions restore a1b2c3d4       # restore in-place by entry ID (branches)
```

**In-place branching** with `/sessions restore` navigates the active session to an earlier entry. It does not require a manually labelled checkpoint: `/sessions restore` without an argument opens an interactive picker containing all entries in the saved session, including ordinary message entries. Messages you send after restoring form a new branch in the tree. The original path is preserved; selecting the current active entry simply leaves the conversation at its current position.

Restore changes the active runtime session, but it does **not** immediately overwrite the saved session on disk. After inspecting or continuing from the restored point, run `/sessions save` to persist the new active position and branch. Until then, the previously saved snapshot remains unchanged. Restore reloads the saved snapshot associated with the active session, so save first if the current conversation contains messages or other state that must not be discarded:

```text
/sessions save                   # preserve the current state first
/sessions restore                # choose a previous entry and branch
```

To split a conversation into a separate file, restore to the desired point and then `/sessions <new-name>`: the new snapshot keeps the full checkpoint tree while the original session file stays unchanged.

### Session Format

Version 4 snapshots embed the checkpoint tree alongside the task graph and active plan. Sessions saved before v4 are not loadable. Remote sessions save the local transcript with replay metadata. Subscription sessions persist continuation metadata for efficient resume.

## Memory and Project Context

Durable context is separated by responsibility:

- Optional project `AGENTS.md` — workspace-specific constraints and workflows.
  Create and edit it manually in the working directory, and check it into
  version control when appropriate. When present, ZenCODE reads it and adds it
  to the agent context; it never creates or rewrites the project file
  automatically.
- Global `~/.zencode/AGENTS.md` — cross-workspace operating rules. This file is
  separate from the project file and applies across working directories.
- Project memory — a per-workspace graph of durable project facts stored outside the working tree at `~/.zencode/memory/<project key>/memory.graph.json` (honouring `ZENCODE_SUPPORT_DIRECTORY`; see [Project key](#project-key)). Opening loads that JSON graph, with its `memory.graph.json.vectors` from graph version 4, or starts empty when it is absent; a cold search/read never writes. Existing `MEMORY.md` files are completely ignored, even when malformed, and are never imported, embedded, rewritten or deleted. Facts already persisted in JSON remain available. A separate global graph at `~/.zencode/memory/global/memory.graph.json` (same format) is used only by sessions whose profile has the `organizer` role, for their `memory.*` tools and recall; project graphs are never aggregated into it, and automatic learning never writes to it.

The Memory tool group maintains project memory without accumulating avoidable duplicates:

Treat this memory as a concise project journal, not a general preference or
activity log. Create or update an entry for a verified handoff, a material
architecture/compatibility decision, a durable blocker or caveat, or a
completed release/publication. A release entry records its version or
identifier, what was published, current caveats and useful next step, backed by
evidence such as a tag, artifact, successful validation, or deployment result;
a version or changelog edit alone does not prove publication. Do not journal
unimplemented plans, unverified claims, command-by-command activity, raw logs,
large diffs, temporary progress, or facts already obvious from current files.
A read-only agent can retrieve and verify journal context but cannot mutate it.

- `memory.read` reads recent entries; use `detail: "index"` for a compact summary/ID view and the default `detail: "full"` for complete content.
- `memory.search` runs BM25 keyword retrieval over the graph and follows links to related entries; with an embedding provider configured it fuses semantic hits in via reciprocal-rank fusion. It is strictly read-only: searching never rewrites the graph or its retrieval statistics — only automatic recall performs that maintenance.
- `memory.write` adds a new entry; writing content that already matches an active entry returns that entry instead of duplicating it, and the tool says so — the result reports `written`/`deduplicated` truthfully instead of claiming every call saved something.
- `memory.update` rewrites an entry in place: the id, creation date, and archive state are preserved, the original `Timestamp` is kept and `Updated` added when omitted.
- `memory.archive` deactivates a stale entry by id so it stops influencing retrieval without being deleted.

Before writing, search for an active entry about the same durable project fact. Update it when appropriate instead of appending a duplicate, and do not write when nothing materially changed. Embeddings are opt-in and off by default: without a provider, entries carry no vector and retrieval is pure BM25 keyword matching. The embedding configuration is an endpoint URL plus an optional model: configure it in `/setup` ("Memory embeddings": BM25 only / add / change / remove), where an OpenRouter choice is proposed immediately when OpenRouter is among the configured providers (canonical endpoint `https://openrouter.ai/api/v1/embeddings`, model `qwen/qwen3-embedding-4b`; a model already saved, such as the earlier default `qwen/qwen3-embedding-8b`, stays valid), or for compatibility export `ZENCODE_MEMORY_EMBEDDING_ENDPOINT` (endpoint only). Setup validates the URL locally and never connects to it. When a model is configured ZenCODE sends it in the request body; otherwise the endpoint identifies the embedding model itself and the request omits `model`, so an endpoint-only OpenAI-compatible `/v1/embeddings` server chooses. The OpenRouter preset reuses the configured provider's API key at runtime only when the referenced provider is a configured OpenRouter provider and the embedding endpoint is itself an OpenRouter endpoint — the key is never duplicated in the embedding settings, and manual endpoint edits reset to an endpoint-only configuration so an edited endpoint can never forward the key to another host; custom/legacy endpoint-only setups send no Authorization header. Entries record the model identity that embedded them, so changing the provider degrades retrieval to keyword matching instead of returning mismatched results. Mutations are serialized per workspace within one ZenCODE process, and each one commits only after the graph save succeeded: a failing save leaves the in-memory graph unchanged.

The vendored engine ships optional intelligence layers — a query analyzer (default `DirectMemoryQueryAnalyzer`, which uses the prompt as the query), a selector, an extractor (default `NoopMemoryExtractor`, which extracts nothing) and a context formatter — plus `context(for:)` (a ready-to-inject memory block) and `learn(from:)`; these remain unwired engine internals. Automatic recall is wired and on by default: before each turn ZenCODE retrieves relevant entries — BM25 plus graph expansion locally (or semantic similarity plus fusion when an endpoint is configured), never a second LLM call — and injects them as a labelled `<project-memory>` block into the outgoing copy of the last user message on every tool round. The embedding provider selected in setup is fixed and independent of the destination chat model/provider: operator and delegated turns using GLM, Claude, GPT, or another model query the same graph through that embedder and receive the selected memory as text, without per-model copies. Recall remains bounded by a deadline (`ZENCODE_MEMORY_RECALL_TIMEOUT_MS`, default 150 ms); with embeddings enabled, a maintenance-free local BM25 block is prepared alongside semantic retrieval, so a slow endpoint yields that lexical fallback instead of erasing memory context, while an unavailable graph or a fallback not ready by the deadline still degrades to no memory without delaying the turn. The block itself does add input tokens to the request, so it is capped by a character budget (`ZENCODE_MEMORY_RECALL_MAX_CHARACTERS`, default 4 000 characters ≈ about 1k tokens, clamped to [200, 32 000]); recalled content is escaped so it cannot close the container, and the payload is truncated on line boundaries with a notice when it does not fit. The block is a transient per-turn channel merged into the outgoing copy of the last user message only — exactly once per round, because it is never written back into the session — and it never enters conversation history, saved-session snapshots, or the session cache key, so saved sessions and prompt caching are unaffected. Delegated sub-agent turns receive the same recall. The main model reads and writes durable memory explicitly through the five `memory.*` tools above. `ZENCODE_MEMORY_AUTO_RECALL` (default on) switches recall off.

`AGENTS.md` is optional and can be created or updated manually whenever a
project needs durable workspace guidance. If it exists in the working
directory, ZenCODE reads it and inserts it into the agent context. ZenCODE does
not create or rewrite this project file automatically. This project file is
distinct from the global `~/.zencode/AGENTS.md`, which supplies operating rules
across workspaces.

## ACP Mode

```bash
zen --acp --working-directory /path/to/project
```

stdout contains only ACP JSON-RPC messages. Clients provide prompts, sessions,
and tool exposure. `--agent`, `--model`, `--working-directory`, `--skills`, and
token environment variables still apply.

### Authentication Methods

`initialize` publishes authentication methods according to the client's
`clientCapabilities`:

- `zencode-client-compatibility` (`type: agent`, name **Continue with
  ZenCODE**) is published when the client declares an `auth` capability. It
  is a no-op confirmation, required by some clients (for example Xcode 27
  beta 3) before they open a session. It does not configure or authenticate
  any provider.
- `zencode-setup` (`type: terminal`, name **Set up ZenCODE**, `args: []`) is
  published when the client declares
  `clientCapabilities._meta["terminal-auth"]` as `true`, as the ACP Registry
  validator does. Its args replace `--acp`, so the client runs `zen` with no
  arguments in a terminal. If configuration is missing, the interactive setup
  (provider and sign-in) opens. When setup is finished, `zen` enters the chat,
  which is left with `/exit`. If ZenCODE is already configured, the chat opens
  directly. When the process exits, the client reconnects and initializes the
  agent again.

If both capabilities are declared, both methods are published, with the
`agent` method first. If neither is declared, `authMethods` is empty.

### Before ZenCODE Is Configured

When `zen --acp` or `ZENCODE_AGENT_MODE=acp` runs without the configuration
required by first setup (`settings.json` or `agents.json` missing or invalid,
or no model configured), the interactive setup does not start inside the ACP
stream, and stdout still contains only JSON-RPC messages:

- `initialize` responds normally with `authMethods` and an empty model list.
- `session/new`, `session/load`, `session/resume`, `session/prompt`, and
  `_zencode/model/preload` respond with the ACP error `auth_required` (code
  `-32000`) and this message:

  ```text
  Authentication required: ZenCODE is not configured. Use the "Set up ZenCODE" terminal authentication method, or run `zen` in a terminal.
  ```

The configuration is not reloaded while the agent runs. After setup, the client
must restart the agent; the `zencode-setup` flow does this by itself. If setup
is cancelled, ZenCODE stays unconfigured and those requests keep returning
`-32000`.

## Recommended Workflow

1. `cd /path/to/project && zen` — start in the target project; first-run setup opens automatically when required.
2. `/setup` — reconfigure providers, models, agents, or features later without leaving the TUI.
3. `/tools` and `/skills` — select tools and skills.
4. `/plan <goal>` or `/goal <goal>` — optional planning before editing. `/plan` delegates to a Planner sub-agent with an approval step; `/goal` works until completion or a genuine blocker, executing directly or delegating when useful with a persistent task graph.
5. Implement with the active profile.
6. `/changes diff` and Git — inspect changes.
7. `/review` — read-only review before commit.
8. `/sessions name` — save meaningful checkpoints.
9. Update project memory at handoff points (via `memory.write` / `memory.update`).

## Troubleshooting

- **Setup starts automatically**: required configuration (`settings.json` or `agents.json`) is missing or invalid, or no model is configured; complete setup before the chat starts. Use `/setup` later to reconfigure.
- **An ACP client reports "Authentication required: ZenCODE is not configured"**: start the client's **Set up ZenCODE** method, or run `zen` in a terminal, complete setup, and restart the agent in the client. See [ACP Mode](#acp-mode).
- **Model not found**: run `/models` or check `settings.json`.
- **A profile is never chosen for delegation**: check its role compatibility, its tool grant, and that it has a model binding with a capability — see [bindings.md](bindings.md).
- **No tools available**: use `/tools`, switch profile, or check ACP client tool exposure.
- **`/feature` unavailable**: switch to `/agents Builder`.
- **Optional feature tools are missing**: install the package with `zen --install-features <id>` (or choose it in setup), then enable/select it with `/tools`.
- **`/plan` or `/review` needs sub-agents**: enable `sub-agents` with `/tools` or switch profile. `/goal` does not require sub-agents; delegation is optional.
- **Xcode tools missing**: make sure Xcode is running. See [xcode.md](xcode.md).
- **Figma tools missing**: make sure the Figma desktop MCP server is enabled.
- **Voice mode or Telegram voice messages do not work**: see the troubleshooting table in [voice.md](voice.md#troubleshooting).
- **A scheduled prompt fails, never runs, or sends no mail**: see [Errors and fixes](#errors-and-fixes) for `/cron`.
