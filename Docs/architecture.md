# Architecture and Layout

This document records the repository layout contract used when reorganising
ZenCODE. It is intentionally conservative: moving an implementation file must
not silently change a public module, executable, protocol, persistent format,
or build variant.

## Compatibility Contract

The following surface is stable unless a separately announced compatibility
migration says otherwise:

- package identity `ZenCODE` and Swift tools version 6.4;
- library products and imports `ZenCODECore`, `FeatureKit`, `ToolCore`,
  `FeatureMCPBridgeKit`, and `LocalToolsSupport`;
- the public API of `Sources/ZenCODECore/Chat`, which follows semantic
  versioning (see [Embedding ZenCODECore in a Host App](embedding.md)):
  additions arrive in minor releases and breaking changes only in major
  releases; public enums are not `@frozen`, so a minor release may add cases
  and clients switch over them with a `default` case; the `@ChatSessionActor`
  isolation is part of the contract;
- executable `zen` and its ACP entry point;
- executable `ZenCRON`, the host that cron runs for scheduled prompts (see
  [ZenCRON Host](#zencron-host)): its installed path
  `<support directory>/bin/ZenCRON`, the single line `ZenCRON <number>` that
  `--zencron-version` prints, and the exit status or signal it replicates;
- optional feature IDs, executable product names, tool names, selection
  prefixes, source-relative paths,
  and the `--list-tools` / `--invoke` JSON envelopes;
- settings, profiles, per-project agent selections, permissions, session snapshots,
  feature manifests, per-workspace memory graphs, and cache key formats;
- the ZenCODE crontab block markers (`# >>> ZenCODE cron >>>` /
  `# <<< ZenCODE cron <<<`), the `PATH=/usr/local/bin:/usr/bin:/bin` line that
  starts the block (it is how ZenCRON finds `zen`, and how cron finds the bare
  `zen` of older lines), the `# zencode-cron id=… created=…` entry marker, and
  the generated cron command layout decoded by `/cron list`. New lines run the
  single-quoted absolute path of ZenCRON, `'<support directory>/bin/ZenCRON'`;
  lines written before ZenCRON existed run a bare `zen` and are still decoded,
  listed, run, and removed. Both kinds take the same arguments, with `--jsonl`
  only for JSONL entries (lines written earlier always have it), then
  `-f '<path>'` and/or `-p '<prompt>'`, at least one, in that order;
- public installer entry points under `Scripts/install*.sh`.

**Announced migration: agent profile format.** Every profile in `agents.json`
now requires a `role` (`developer`, `builder`, `minimal`, `planner`,
`reviewer`, `reporter`, `organizer`, `promoter`, or `tester`), and `AgentProfile`
decodes it strictly: a missing, non-string, or unknown value makes the whole
manifest invalid (`AgentProfileStoreError.invalidFile`, with a message naming
the profile and the valid roles), so setup is required and `zen --setup` offers to
rewrite the file. The role is never deduced from the ID or the name and there
is no automatic migration. The recommended (system) profiles now have their
role as ID instead of the former fixed UUIDs; a profile is a system profile
exactly when its ID equals its role (`AgentProfile.isSystemProfile`), and a
project without a saved agent selection sees only those. References persisted
with the former UUIDs (saved sessions, per-project agent selections) are not
migrated: they resolve like references to a deleted profile.

**Announced migration: shared chat session controller.** The terminal chat,
ACP sessions, and the headless runner (plain text and JSONL) run every session
through one `ChatSessionController`, isolated to the `ChatSessionActor` global
actor (see `Sources/ZenCODECore/Chat` under [Target Layout](#target-layout)).
A host app drives the same controller through the public API (see
[Embedding ZenCODECore in a Host App](embedding.md)).

*What is shared.* The controller runs the turn pipeline: the coordinator tools
a turn adds, from the single `ChatTurnPurpose.additionalToolNames(activePlan:)`
table, `/plan` finalization, `/goal` continuation, the bounded transcript,
file-change tracking, and the mapping of runtime events onto a
`ChatSessionPresenter`. It owns the session operations that the terminal chat
used to implement itself, `/sessions` (new, save, save under a name, list,
load, delete, compact, restore from a checkpoint, and the DS4 engine
checkpoints), and the selections of model, thinking level, agent (with the
project's agent association), tools, and skills (with install and uninstall),
together with the composition of the session configuration and system prompt
from them, so a channel with an interaction host offers them without terminal
code. `ChatModelCatalog` (`Chat/Models`) is the one model list of the terminal
and ACP; ACP keeps its epochs, fences, reconfiguration with rollback, and
prompt composition. The terminal's commands are adapters over the controller
that keep their public signatures, and the helpers that moved remain
forwarders. The headless runner builds its session configuration and prompt
skills from a controller instead of instantiating `TerminalChat`.

The controller also runs the slash commands that the channels share.
`ChatCommandRegistry` (`Chat/Commands/ChatCommandRegistry.swift`) lists them
as `ChatCommandDescriptor` values: who runs the command (`.shared` or
`.channel`), the `ChatCommandContext` facts the operator needs to see it,
whether it runs while a prompt is generating (and for which actions), and what
it answers while hidden. A channel sets its registry as the controller's
`commandRegistry`, and `handleCommandLine(_:context:)`
(`ChatSessionController+Commands.swift`) resolves a line there and runs it. The
shared commands (`sharedDescriptors`) are `/help`, `/models`, `/think`,
`/agents`, `/tools`, `/skills`, `/sessions` (also `/session`), `/attach`,
`/open`, `/artifacts`, `/changes`, `/undo`, `/tasks`, `/plan`, `/goal`, and
`/review`, on the operations of `+PlanLifecycle.swift`, `+PlanLibrary.swift`,
`+GoalCommands.swift`, `+ReviewCommand.swift`, `+TasksCommand.swift`,
`+WorkspaceCommands.swift`, and `+WorkspaceReferences.swift`; the gates of the
planning commands, `commandTurn` and `superseded`, and the routing of the
replies they wait for stay in `+PlanningCommands.swift`. The commands a
channel runs itself answer `.channelCommand`, for the channel to run: the
terminal's `/telegram`, `/voice`, `/ds4`, `/feature`, `/cron`, and
`/exit`, which its registry declares with the `.channel` scope, and
`/tools logs`, which the shared `/tools` leaves to the channel. ACP runs
`/telegram` itself too, and answers it before the line reaches the controller.
The terminal places its commands after anchors among the shared ones and adds
its own facts to the context (`.telegramEnabled` and `.ds4Model`, next to
Chat's `.builderAgent`); its command handlers are adapters with unchanged
signatures. ACP keeps its parser (`CoordinatorCommandParser`), its strings,
`acpReviewPrompt`, and `availableCommandsUpdate`, and routes `/plan`, `/goal`,
`/review`, and the replies they wait for onto the same operations with a
`ChatPlanningCommandPolicy` (`Chat/Commands`): its terminal values run the
terminal's sequence and its ACP values the sequence ACP had, so the ACP
`/review` still differs from the terminal's. `ZenCODEACPBridge+PlanLibrary.swift`
is gone, and the unused `ACPCommandPromptPurpose.additionalToolNames` is
removed. Before it routes a command, ACP takes a `ChatCommandFence`
(`Chat/Commands/ChatCommandFence.swift`), the controller's turn token, which
`cancelActiveTurn` invalidates; the commands write their state under the lock
of `ChatSessionStateStore` only while the fence holds, and undo their runtime
changes once it fails.

*The session host.* `Chat/Host` is the channel-neutral container of the chat
sessions of one process. A `ChatSessionHost` owns what every session shares:
the `AgentCoreSessionRunner`, the Telegram route authority
(`TerminalTelegramSessionRouter`) and Bot API poller
(`TerminalTelegramBotDispatcher`), one of each per host, created on first use
and handed to the Telegram channel of every slot, the sleep assertion held
while any slot runs a session, and the epoch counter. A channel opens a *slot* with a
`ChatSlotDescriptor`: its identity (`ChatSlotIdentity`: `.terminal`, an
`.acpSession`, a `.window` of a host app, `.telegram`, the session of
`zen --telegram`), the working directory, and the
channel's bindings, which the slot keeps across its sessions and applies to
every controller it runs: the presenter, the interaction
(`ChatSlotInteraction`: the channel's own `ChatInteractionHost`, or a
`ChatPendingRequestHost` per incarnation), the consent authorizer, the channel
hooks, the command registry, and whether a `ChatSessionStateReducer` is
attached to each controller as it is created (`publishesState`). A slot runs
one *incarnation* at a time (`ChatSessionIncarnation`: the session id, the
controller, its reducer when published, and an `epoch` the host assigns from
one strictly increasing counter, never reused across slots or sessions).
`openSlot(_:)` opens a slot without a session, `openSlot(_:sessionID:)` with
its first one in one synchronous step, and `newSession(in:sessionID:)` and
`loadSavedSession(in:name:checkpointEntryID:)` replace the incarnation: the
previous controller is fenced (`cancelActiveTurn`), its reservation dropped,
its pending requests refused, and its reducer detached before the new
controller exists, so selection, plan, workflow, and transcript never carry
over, except the selection of a new session in a slot opened with
`keepsSelectionOnNewSession`, which starts from the selection of the session
it replaces (a load still restores the saved selection); the runner session
of the previous incarnation is discarded, the new one is created by the
channel. `adoptSessionID(_:in:)` gives the current
incarnation another id in place, keeping its controller and epoch, for a
channel that continues persisted work under the id it was persisted with before
the runtime session exists. The startup recovery of a task graph does not need
it: the graph moves into the session, which keeps its id
(`ChatSessionController.offerResumableTaskGraphs(choiceHost:)`, described with
the `Sources/ZenCODECore/Chat` layer under *Target Layout*), and the terminal
no longer adopts the id of the session that left the graph. A controller the host
creates carries its binding to the host, so the session replacements of the
shared commands (`/sessions new`, `/sessions` loading a saved session,
`/sessions restore`) and of `startNewSession(newSessionID:)` and
`loadSavedSession(_:checkpointEntryID:)` come back to the host as new
incarnations, with the channel hooks in their order: the first step
(`incarnationDidChange(reason:)` with `.newSessionWillStart` or
`.savedSessionWillLoad`) and the end of the planning discussion on the
controller being replaced, the rest on the new one; the id of a new session is
the slot's (`ChatSlotDescriptor.sessionIDPrefix`, `terminal` for the terminal
and `chat` otherwise, with a new lowercased UUID); a controller a channel runs
on its own still switches in place. One prompt
runs per incarnation: `reservePrompt(in:)` checks and reserves in one call of
the host, `releasePrompt(_:)` and `cancelPrompt(in:armingWorkflowRecovery:)`
end it, `holdsPrompt(_:)` tells late work whether its reservation still holds,
and `withReservedIncarnation(_:_:)` and `withLiveIncarnation(_:epoch:_:)` run
a write in the same step as the check, so a channel in another isolation
domain never splits them across a suspension and a replaced or closed
incarnation is never written into by its own late work. The host is isolated
to `ChatSessionActor`; `incarnations(in:)` streams the incarnations of a slot
to an observer, newest first when it is slow, the snapshots of a reducer the
host created end with its incarnation, and `shellSnapshots()` streams
the `ChatShellSnapshot` of the whole host (`shellSnapshot` is the current
one): the `ChatSessionSummary` of the session each slot runs, which is its
reducer's when it has one and otherwise built from the incarnation with the
reducer's rules by one function of the host, which creates no reducer for it,
and which a new or loaded session shows once, with no slot without session in
between; the `ChatSavedSessionSummary` values of the open workspaces, by
standardized URL; and a `ChatShellTelegramState` (Telegram configured by the
settings, the poller running, the slots Telegram drives). The saved sessions
and the settings are read off the chat actor, the store listed without
migrating its files, and only while a shell observes the host, until its last
stream ends: then again when a slot starts another session, when a session of
the host is saved or deleted, the settings with the poller when a slot hands
itself to Telegram, takes itself back, or closes, and on
`refreshShellSnapshot()`, never on a timer.
`closeSession(in:runtimeSession:)`
ends a slot's session and keeps the slot, `closeSlot(_:runtimeSession:)`
forgets it, and `shutdown()` ends every slot before its
first suspension and shuts the runner down, all of it. The task graphs stay
where they were: `SessionTaskOrchestrator` belongs to the runner, and the host owns
only the incarnations. The ACP bridge is an adapter over the host: one slot
per ACP session, opened with `publishesState: false`, a binding of slot,
epoch, and controller that never changes for the life of the session, the
prompt reservation and the reconfiguration held through the host, and its
own shutdown latch; the ACP wire is unchanged. The terminal is one slot: see
`Sources/ZenCODECore/TUI` below.

The working directory of a slot can be a Git worktree. For `zen --worktree
NAME`, `AgentWorktreeManager` (`Runtime/Configuration`) creates or reuses
`<support>/worktrees/<project key>/<NAME>/<repository folder name>` before the
configuration is built and passes it as the last `--working-directory`;
`AgentConfiguration.worktree` (an `AgentWorktree`) and
`ChatSessionEnvironment.worktree` record the request, so the controller adds the
`Git worktree:` section to the system prompt of the sessions whose working
directory is the worktree. The leaf keeps the repository's folder name, so the
name-based `ProjectStorageKey` is the repository's and the project memory,
sessions, task graphs, and project agents are shared with the main checkout;
`<support>/worktrees` is runtime state outside session snapshots and
checkpoints. The terminal (`TerminalChat+Worktree.swift`), when its chat ends,
and the macOS app (`ZenWorktreeClosure` in `ZenAppSession`), when its last
window closes or it quits, offer to merge, keep, or remove the worktree and run
the choice through `AgentWorktreeManager.perform`.

What an operation or a command needs from the operator goes through the
`ChatInteractionHost`, which declares its `ChatChannelCapabilities`. A
`choose…` operation asks the host for a menu and, without the matching
capability, returns the non-interactive output of its command instead.
`openExternal(_:)` takes a `ChatOpenTarget` (by default it throws `Opening
files is not supported by this channel.`), and `pickAttachment(startingAt:)`
returns `nil` by default; their capabilities are `.externalOpen` and
`.attachmentPicker`. The controller never asks a host without `.externalOpen`
to open anything, and the terminal declares both capabilities only when stdin
or `/dev/tty` is an interactive terminal.
`ChatSessionEnvironment.userHomeDirectoryURL` is where the picker starts and
what a leading `~` stands for in `/attach` and `/open`: the terminal, ACP, and
the headless runner pass `UserHomeDirectory.current()`, and with `nil` the `~`
is not expanded and `/attach` offers no picker. The channel's own steps
between the steps of an operation or a command go through the weakly held
`ChatSessionChannelHooks`. The steps of a session that changes are one hook,
`incarnationDidChange(reason:)`, whose `ChatIncarnationChange` names the step
and carries its data: `.newSessionWillStart` and `.newSessionDidStart` around
`/sessions new`, `.savedSessionWillLoad`, `.savedSessionWillRestore`, and
`.savedSessionDidRestore(transcript:contextWindow:)` of a saved-session load
(the terminal replays the restored transcript at the last one, so the replay
keeps its place before the loaded notice), and
`.sessionDidCompact(contextWindow:)` after `/sessions compact`. The other steps
the terminal ran between an operation and its closing notices are
`selectionDidApply(_:command:)` (with a `ChatSelectionCommand`) and
`commandContextWindow()`, and `responseLanguageShouldLock()`, which
`/plan approve` calls before its implementation turn starts; the steps of a
selection that creates the session again are `agentDidChange(_:)`,
`sessionWillCreate(reason:)`, `sessionDidCreate(reason:)`,
`modelPreloadDidEmit(_:)`, and `modelDidPreload(_:reason:)`.

The task-graph and sub-agent overviews are semantic values
(`Chat/Contracts/ChatOverviewState.swift`): `ChatTaskGraphOverview`, the graph
with its task views, signature, and significance threshold, which
`current(in:sessionID:)` reads for `/tasks` and for the ACP plan;
`ChatSubAgentOverview`; and `ChatOverviewOrigin` (`.automatic` or
`.explicit`). The presenter reserves a `ChatOverviewPublication` before the
controller waits or reads (`reserveTaskGraphOverviewPublication()`,
`reserveSubAgentOverviewPublication()`) and gets it back with
`presentTaskGraphOverview(_:origin:publication:)` and
`presentSubAgentOverview(_:origin:publication:)`, so it can drop a publication
that a later one overtook; the text of a section stays the channel's. The
controller owns the observers, `ChatTaskGraphObserver` (debounced by 150 ms
and fenced on the observed session and on the graph revision it read) and
`ChatSubAgentOverviewRefresher` (every 2 s while a blocking `agent.*` call
runs), and the channel starts and stops them: the terminal from its own
callbacks, quiescing the task-graph observer at every turn boundary
(`quiesceTaskGraphObserver()` stops it and publishes the latest graph once, and
the terminal runs it again once the turn is closed), and the Telegram channel
for the turns it presents (the sub-agent overview from its presenter's
tool-call callbacks, and on the slot of an ACP session the task-graph observer
too, from the moment it drives the slot until it stops, quiesced at the end of
each turn it presents as the terminal does: the final graph reaches the turn
that closes, and nothing the observer debounced crosses into the next one),
while ACP's own prompts and the headless runner start neither and never read the
sub-agent snapshots for an overview. ACP builds its `plan` and `tool_call`
updates from `ChatTaskGraphOverview`. The prompts accepted while a session is
busy wait in `ChatPromptQueue<Origin>` (`Chat/Queue`), a FIFO of
`ChatQueuedPrompt<Origin>` bounded at 32 prompts whose origin type is the
channel's.

Telegram is a channel of the slot (`Chat/Channels/Telegram`), never a part of
the terminal chat and never a mirror: a slot is driven by the channel that
opened it (`ChatSlotChannel.primary`: the terminal, an ACP session, a window of
a host app) until `/telegram on` hands it to the linked chat
(`ChatSessionHost.activateTelegram(in:primaryChannelDescription:)`), and
`/telegram off` takes it back (`deactivateTelegram(in:presentingCatchUp:)`). The
slot of `zen --telegram` (`ChatSlotIdentity.telegram`) is the exception: its
primary channel is silent, and the slot is handed to the Telegram channel at
startup and never taken back. The slot's
`TelegramChannel` is created on the first `/telegram on` (at startup, for that
slot) and kept, attached or
not, for the life of the slot: it owns the control service, the validated
route lease, the linked chat, the session's topic, and the Telegram side of the
turn in progress, and it runs the turns the chat asks for through the host
(`runTelegramTurn`, internal), with the composition of the primary channel
(`ChatSessionChannelHooks.turnSessionConfiguration(for:controller:)`: the
terminal's default composition, or the editor's for an ACP slot, through
`ACPSessionChannelHooks`) and inside the environment of its turns
(`ChatSessionChannelHooks.runTurnFromAnotherChannel(controller:_:)`: none for
the terminal, which has no environment of its own; for an ACP slot the text
file system the client serves, so a file the turn writes goes to the editor's
buffer and not past it to the disk, and the prompt-skill selection of the
session's agent, both through the helpers the editor's prompts use), so a
prompt, a voice note, or a `/plan` `/goal`
`/review` from the chat runs as one typed on the primary channel.
`TelegramChannelRegistry` keeps the channels attached in the process, per bot.
Every controller of a slot presents through the slot's `ChatSlotPresenter` and
asks through its `ChatSlotInteractionHost`, which forward to the channel that
drives the slot now; a switch in the middle of a turn tells the new channel the
turn moved onto it (`ChatSlotChannelPresenter.turnDidMoveToChannel(_:)`, with
the block already streaming), asks the open requests again on the new channel,
and the ending of a turn is presented by whoever drives the slot when it ends
(`presentTurnEnding(_:in:)`). While Telegram drives the slot, the terminal
presents the ending of its own turn before it releases the turn's reservation
(`presentOwnTurnEndingInTelegram`), and a turn the channel begins waits for a
closing still in progress (`waitForFinishingTurn()`), so no turn starts from
the chat before the previous turn's outcome and summary reached it; a message
from the chat that arrives meanwhile queues (the busy gate lets it through:
`refusesMessagesAsBusy` is `false` while `isPresentingPrimaryTurnEnding`) and the channel's queue
starts again once the reservation is released
(`sessionReservationDidEnd()`). The channel's `TelegramChannelPresenter` sends
the session's output to the chat through the turn's ordered reporter
(`TerminalTelegramTurnProgressReporter`, whose closed payload surface is
`TerminalTelegramTurnPayload`): each completed reasoning block as a thinking
message (`.thought`: a plain-text `sendMessage` of `💭` and the reasoning,
which one `expandable_blockquote` entity covers whole and an `italic` entity
covers from the reasoning on, cut at 3,900 characters, never a rich message
and never parsed as Markdown or HTML); a root response
buffered by the reporter and published at the next tool boundary, or at the
reasoning block that the next content closes, so content, reasoning, and
content reach the chat in the order they were written; each root tool call as
a row of an activity message edited in place, its title
(`ToolCallPresentation.toolTitle(for:)`) and then only its outcome, `⏳`, `✅`,
or `❌` by the terminal's own criterion for ⚠️
(`ToolRenderingPolicy.toolResultIsFailure(for:result:)`, under `Presentation`),
and its elapsed time
(`ToolCallPresentation.elapsedTimeText(_:)`, the time the tool executor measured
and the result carries, `DirectAgentToolResult.elapsed`, none for a result
without one; every running row keeps room for it in the message, and a
time that would still take the message past its limit is left out), never its
arguments or result, and none for the calls the terminal does not show
(`ToolRenderingPolicy.shouldSuppressToolRendering(for:)`); and the overviews the
controller publishes: a task graph once per signature within a turn (the
progress card, edited in place and deleted when the reporter retires), and the
sub-agent overview, which the presenter asks the controller for when an
`agent.*` call starts and settles, refreshes while a blocking one runs, and
publishes once more when the model work ends, as the terminal does. An
overview is presented by signature for the presenter's life, which is the
channel's, so one equal to the last sends nothing, in this turn or a later
one; a changed one with agents becomes the turn's
`🤖 Sub-agent` status message (`.subAgentStatus`, created once per turn and
edited in place), and each partial or completed sub-agent response not sent
yet a message of its own. The responses are deduplicated by token for the
presenter's life too, not per turn: at most 512 are remembered, the least
recently presented forgotten first, and every overview refreshes the ones it
still shows before it adds new ones. What the sub-agents already show when the
channel starts driving the slot (`channelDidStartDriving()`, once per drive),
which the primary channel showed, is the backlog: the presenter reads it from
the controller, marks its responses as sent and its overview signature as the
last presented before the next publication is compared, so none of it reaches
the chat and an overview unchanged since that moment creates no status
message; only the responses and changes that come later do. Any new message
closes the activity message, and the next call opens another below it, and so
does an activity message that could not be created (a send whose outcome is
unknown fences its ledger for good: it is never edited nor created again);
editing the card or the status in place closes nothing, and a call's outcome is
written in its own row. The activity and status messages stay in the chat, and
`TerminalTelegramTurnActivity` shapes
their texts, which are model output and are never parsed as Markdown or HTML.
The turn's ending follows, with its outcome and file-change summary. The
chat receives the last `TelegramChannel.handoverContextEntryCount` (6) prompts
and responses as context at the handover. The catch-up of `/telegram off` is a
`ChatTelegramCatchUp`: the entries of the incarnation's log with a sequence
greater than the last one the primary channel saw, or the whole log when the
slot runs another incarnation, with the response still streaming; a channel
that renders it itself (the terminal, through `presentingCatchUp`) renders it
right after the switch and before the link stops, while the slot's presenter
holds what the turn in progress presents (`ChatSlotPresenter.holdOutput()`),
so the rest of the turn follows the catch-up, in order and whole. A slot that
publishes no state gets a reducer for the handover, seeded with the transcript
(or the runtime history when the controller keeps none) and detached once the
catch-up is read. The log and that reducer are transient: nothing of the link
is persisted. While Telegram drives the slot the primary channel is dormant:
`admitLine(_:in:)` admits only `/telegram`, `/telegram off`, and `/exit`, and
answers `ChatSlotAdmission.dormantRefusalText` to every
other line. The consent authorizer resolves the host that asks each session's
consent by session id (`ChatToolConsentAuthorizer.setConsentHostResolver(_:)`,
installed by the host), so an *Always* given in the chat is recorded in the
slot's authorizer and covers the session on every channel. `ChatSessionObserver`
(`Chat/Contracts`) is the presenter that observes a controller whatever
channel presents it, the reducer: `addObserver(_:)` and `removeObserver(_:)`,
read at every call by the internal `ChatObservedPresenter`, so an observer
added in the middle of a turn sees the rest of it. `SharedChatMentionParser`
(`Chat/Contracts`) parses and sanitizes live `@mentions` for the terminal and
the channel alike, and `SharedChatMessageLabel` (`Chat/Contracts`) builds the
route label of a live message (`Worker [18:05:09] → Coordinator`) that the
terminal reader and the macOS app render alike; while the channel drives the
slot it observes the session's shared-chat room itself, relays its messages to
the chat, and runs its auto-triggers as hidden turns. The relay is bound to the
session's room as soon as the channel starts driving, on the link's route when
that route serves the room (`TerminalTelegramRouteKey.admits(roomID:)`: its
own room, or any room when it is the `default` route, `sharedRoomID`), so the
room reaches the chat without waiting for a message from it; a route bound to
another room never binds it. Only the messages that come after the relay starts
forwarding a room
reach the chat: the room's present ones (its transcript, read before the
observation attaches) are marked as handled in the relay's ledger, atomically
with the binding (`TerminalTelegramSharedChatRelay.activate(...presentMessageIDs:)`
and `markPresent`), at the first `/telegram on`, at `/telegram on` after
`/telegram off`, after a room swap, and when the route comes back, whether the
route is shared or a topic's; a refresh of the lease on the room it already
forwards marks nothing, and a reply to a card already forwarded still reaches
its sender. The terminal's `TerminalChat+Telegram.swift`
holds the `/telegram` command, the notice sink that writes the channel's texts
(the activation text, a poll-health notice, a failure) as system or failure
messages, the status line, the dormant admission, the rendering of the
catch-up as a restored transcript, and the adoption of a turn still running
from Telegram, whose ending reaches the input loop as a generation completion
and which Esc stops through the channel (`stopTelegramTurnIfReserved`). Only
the interactive input loop hands its slot over: the line-by-line fallback,
which neither reserves its prompts nor adopts a turn, refuses `/telegram on`.
While Telegram drives the slot the loop's queue waits, whole, and no turn of
the terminal starts (a dictation and the access-mode shortcut are refused as
well); `/telegram off` restarts the queue once the terminal is free.
ACP routes `/telegram` in `Telegram/ZenCODEACPBridge+TelegramCommand.swift`: the reply
to `/telegram on` carries the notices of the attach after the activation text
(`activateTelegramCollectingNotices`, `ACP/Telegram`), the editor's prompts are
refused with the dormant text while Telegram drives the slot, and the reply to
`/telegram off` carries the catch-up as text (`Catch-up from Telegram:` with
`You:`, `ZenCODE:`, and `ZenCODE (in progress):` lines). On ACP the editor
cannot take the slot back in the middle of a turn from Telegram, which holds
the slot's prompt reservation: `session/prompt` is refused with a text that
says so, `session/cancel` stops the turn (`stopTelegramTurnIfReserved`), and
the next `/telegram off` catches up with it; the terminal, which runs its
commands outside the reservation, adopts such a turn instead. The channel of
each slot has its own `TerminalTelegramControlService`, while every channel of
a `ChatSessionHost` shares the host's `TerminalTelegramSessionRouter` and
`TerminalTelegramBotDispatcher` (`ChatSessionHost+Telegram.swift`), so a bot
has a single long poll. The link belongs to the slot: a new or loaded session
keeps the channel, and the topic follows the session through
`rebind(sessionID:displayName:)`.

*Public API and construction points.* The Chat surface is public API under the
semver rule of this contract. It comprises `ChatSessionController`, whose
initializers are `nonisolated`; the session host (`Chat/Host`):
`ChatSessionHost` (with `RuntimeSessionDisposition`), `ChatSlotID`,
`ChatSlotIdentity`, `ChatSlotInteraction`, `ChatSlotDescriptor`,
`ChatSessionIncarnation`, `ChatSessionOperationState`,
`ChatPromptReservation`, and `ChatSessionHostError`, with the shell
(`ChatShellSnapshot`, `ChatShellTelegramState`, `shellSnapshot`,
`shellSnapshots()`, and `refreshShellSnapshot()`); the contracts `ChatSessionEnvironment`,
`ChatSessionPresenter`, `ChatSessionObserver`, `ChatSessionRuntime`,
`ChatSessionManagementRuntime`, `ChatSessionChannelHooks` (with
`ChatIncarnationChange`, `ChatSessionRecreationReason`, and
`ChatSelectionCommand`), `ChatInteractionHost`, `ChatChannelCapabilities`,
`ChatToolConsentAuthorizer`, and `ChatConsentCommandLine` (the one-line command
of a consent request, with runs that mark the executables the consent covers);
the observable state (`Chat/State`):
`ChatSessionStateReducer`, `ChatSessionSnapshot` (with `ChatTurnState`,
`ChatFileChangesState`, and `ChatSessionSummary`), `ChatTurnEntry` (with
`ChatTurnOrigin` and `ChatTurnPhase`), `ChatPendingRequestHost`, and
`ChatPendingRequest`; the notices and their payloads, with
`ChatSessionNoticeText.text(for:)`; the outcomes; `ChatTurnRequest`,
`ChatTurnResult`, and `ChatTurnFailure`; `ChatModelCatalog`;
`ChatPromptQueue` and `ChatQueuedPrompt`; `ChatCommandRegistry`,
`ChatCommandDescriptor`, and `ChatCommandContext`; `SharedChatMentionParser`
and `SharedChatMessageLabel`; and the Telegram channel: `TelegramChannel`
(with `SessionTopic`), `TelegramChannelAttachError`, `ChatSlotChannel`,
`ChatSlotAdmission`, and
`ChatTelegramCatchUp`, with the host's `activateTelegram(in:primaryChannelDescription:)`,
`deactivateTelegram(in:presentingCatchUp:)`, `telegramStatusText(in:)`, `activeChannel(in:)`,
`telegramChannel(in:)`, `telegramChannelCreatingIfNeeded(in:primaryChannelDescription:)`,
`stopTelegramTurnIfReserved(_:in:)`, and `admitLine(_:in:)`. Of the controller, the session facts and state
(`sessionID`, `environment`, `modelCatalog`, `workingDirectory`, `host`,
`authorizer`, `transcript`, `selection`, `savedSessionState`, and
`activePlan`) are read-only, and `commandRegistry` and `channelHooks` are
settable. The turn (`runTurn(_:)`, `cancelActiveTurn(armingWorkflowRecovery:)`,
and `additionalToolNames(for:)`), the commands (`handleCommandLine(_:context:)`
and `pendingReplyAction(for:)`), the composition
(`currentSessionConfiguration(discoverExternalTools:responseLanguageSection:)`,
`turnSessionConfiguration(for:responseLanguageSection:)`, and the initial
agent and skill selections), the selections, the session operations, the
staged attachments, the overviews, and the observers (`addObserver(_:)`,
`removeObserver(_:)`) are public.
`turnSessionConfiguration(for:responseLanguageSection:)` composes the
configuration of one turn as the terminal does: `/plan` and `/review` turns
leave the active plan's progress out, and normal and `/goal` turns keep it.
`ChatCommandFence`, `ChatPlanningCommandPolicy`, `ChatSessionStateStore`, and
`ChatCommandState` stay internal.

`ChatSessionRuntimeFactory` (`Chat/Runtime`) is the construction point of the
session runtime. The backend is chosen in one place of Core,
`ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are
composition roots that inject it; no other layer of Core chooses a backend.
`makeSessionRunner(toolAuthorizationHandler:featureRuntime:mcpRuntime:backendFactory:)`
builds the `AgentCoreSessionRunner`, with `backendFactory` defaulting to
`productionBackendFactory`. `zen` (`ZenCODEMain`) injects
`productionBackendFactory`. The chat of the command-line runner and the
headless runner build their runner with `makeSessionRunner`, passing the
factory they receive, or `productionBackendFactory` when it is `nil`, and a
`TerminalChat` created without a runner uses the default. The ACP bridge
builds its runner as before, with the factory it receives. The fallback of
`AgentCoreBackend.prepareBackend` for a `nil` factory stays for compatibility.
`ChatSessionHost.telegramRouter()` (`ChatSessionHost+Telegram.swift`) builds
the route authority of the Telegram settings once per host, which saves every
route change with `AgentSettingsManifestStore.saveTelegramRoutes(_:ownerUserID:)`,
and `telegramDispatcher()` the poller; the host creates the Telegram channel
of a slot on them, with a control service of its own, at the first
`activateTelegram(in:primaryChannelDescription:)`: nothing of the link is
built outside the host. `ChatSessionHost` is the construction point of the
sessions a channel runs: `zen`'s command-line runner builds one for its chat
with
`TerminalChat.makeSessionHost(configuration:sessionRunner:)` over the runner
it owns, hands it to `AgentRuntimeLauncher.runTerminalChat(…sessionHost:)`,
and shuts it down (`shutdown()`) when the chat ends, whether it returns or
throws; a `TerminalChat` created without a host builds one over the runner it
receives or creates; the ACP bridge builds one over its runner.

*Observable changes.* Apart from the ACP additions below, which are the only
extension of the ACP wire, the shape of every ACP request, reply, and
notification is unchanged, and so are the headless output and the JSONL wire
([JSONL](jsonl.md)).

- Every channel: in-memory "always" consent decisions use the ACP key
  semantics (owning session `delegatedIdentity.rootSessionID ?? sessionID`,
  tool, working directory, command identity, delegated identity).
- ACP: a turn that changes files ends with one more `agent_message_chunk`,
  the file-change summary (`🪬 Summary: …` and one line per file, without the
  terminal `/undo` hint), sent before the `stopReason` reply.
- ACP: turns get the implementation task tools whenever an approved plan is
  open and apply legacy `todo.write` progress to it, as the terminal does.
- ACP saves model and thinking choices as the global default, as the terminal
  always did: a `session/set_model`, or a `session/set_config_option` for
  `model` or `thinking`, whose reconfiguration succeeded writes the choice to
  `settings.json` (the model with its thinking level, or the thinking level
  alone). A reconfiguration that is rolled back, or whose session was closed
  meanwhile, writes nothing, a write failure is only logged and never changes
  the reply, and with `hostedModels` nothing is ever saved.
- ACP: new sessions (`session/new`, and `session/load` or `session/resume` of
  a session ID the agent does not hold) start from that default, read when
  the session is created, and `initialize` and the configuration options
  report it. The model resolves from the client's `modelId`, then `--model`,
  then the model of the launch agent's binding when it is configured, then
  the selected (or only configured) model of `settings.json`; with
  `hostedModels` the default stays the model resolved at launch.
  `_zencode/model/preload` without a `modelId` still preloads the model
  resolved at launch.
- ACP: a prompt `/telegram`, `/telegram on`, or `/telegram off` is a command
  of its session, answered at once with the terminal's texts (without their
  trailing newline) and never sent to the model; while the settings do not
  enable Telegram, every `/telegram` line is answered
  `ZenCODE: unknown command '/telegram'.`
- ACP: while the settings enable Telegram, `available_commands_update` lists,
  after the existing entries,
  `{"name":"telegram","description":"Telegram status, or turn it on/off for this session","input":{"hint":"on or off"}}`.
- ACP with Telegram driving the session: the linked chat runs prompts, voice
  notes, `/plan`, `/goal`, `/review`, and replies to pending questions, with
  the editor's composition (the session's configuration plus the purpose's
  tools) and environment (the client's text file system, the agent's skills),
  and accepts `/start`, `/help`, `/status`, `/changes`, `/diff`,
  `/chat`, and the permission replies; `/undo` is refused with a text that
  names the editor. A gated tool of a turn from Telegram is asked in the chat
  only; the editor receives no `session/request_permission` for it. The
  editor's `session/prompt` is answered with `ZenCODE: this session is driven
  from Telegram. Use /telegram off to take it back.` and `end_turn` while the
  session is idle, and refused with the `invalidParams` error `A turn from
  Telegram is running for this session. Send session/cancel to stop it, or
  wait for it to end, then send /telegram off.` while a turn from Telegram
  holds the reservation (the editor's own prompt keeps `A prompt is already
  running for this session.`). `session/cancel` stops a turn from Telegram
  as it stops the editor's; the chat sees `Stopped.`. The reply to
  `/telegram off` is `Telegram remote control stopped.` followed, when there
  is something to catch up with, by `Catch-up from Telegram:` (with `(new
  session <id>)` or `(older entries omitted)` when it applies) and one `You:
  …` or `ZenCODE: …` line per prompt and response, then `ZenCODE (in
  progress): …` for a response still streaming. `session/load` of a live
  session replays the runner's history, the turns run from Telegram included.
- ACP: the Telegram link is not persisted: after `session/load` the session
  needs `/telegram on` again. The reply to `session/close` waits for the
  channel to shut down.
- Terminal: "always" approvals of destructive tools other than `local.exec`
  now last for the current session instead of the process, while
  `local.exec` approvals remain persisted and valid across sessions.
- Terminal: `/review` turns also get `tasks.create`, `tasks.list`,
  `tasks.get`, and `tasks.update`.
- Terminal: `/agents` reports `Switched to agent: <name>. Plan and task graph
  reset; conversation kept.` instead of `… Session reset.`, since the
  conversation was already kept and only the plan and the task graph are
  reset.
- Terminal without interactive input (neither stdin nor `/dev/tty` is a
  terminal): `/open <file-or-url>` no longer opens its argument and answers
  `ZenCODE: Opening files is not supported by this channel.`; a missing file
  is still reported as not found.
- Telegram with several sessions: a message in General, in a topic no route
  knows, or on the legacy route (see
  [Telegram Single-Owner Routing and Persistence](#telegram-single-owner-routing-and-persistence))
  is handled by every attached session. While several channels are
  attached to the same bot in the process, `/allow`, `/always`, and `/deny`
  without a request ID on such a shared route are refused and ask for the ID,
  since they could decide the request of another session. Duplications
  remain: with an ID, the other sessions answer that they have no such
  request (`No permission request is pending.` or
  `No pending permission request <ID>. Pending: …`), and a reply to a
  ForceReply card or a tap on a `/diff` button gets an error or a refusal
  from the other sessions.
- Telegram: while the chat drives a session, a turn reaches it as the terminal
  shows it, with no setting: each completed reasoning block as one
  expandable blockquote of `💭` and the reasoning (cut at
  3,900 characters), each root tool call as a row (`⏳`, then `✅` or `❌`) of
  an activity message edited in place, with the call's title and no argument
  or result, and the sub-agent overview as one `🤖 Sub-agent` status message
  per turn, edited in place.

*Corrections found on the way.*

- Selected prompt skills are kept when a `/tools` change rebuilds the session;
  the rebuild used to drop the session's skill provider.
- `/sessions delete` also removes the deleted session from the
  `sessions.json` index
  (`SavedSessionsStore.removeSavedSession(projectPath:sessionName:)`) when the
  index records it.
- Terminal: `/tasks`, `/tasks status`, `/tasks list`, and `/tasks ls` typed
  with leading spaces now run while a prompt is generating. The action used to
  be read from the untrimmed line (`line.dropFirst("/tasks".count)`), so
  leading spaces turned it into another word and the command was refused as
  unavailable while a prompt is running;
  `ChatCommandRegistry.isAvailableDuringGeneration` reads the line without
  its leading spaces.
- ACP: the reply to `/telegram on` carries, after the activation text, the
  notices the channel presented while it attached, for example a topic that
  the Bot API did not create, instead of dropping them. Outside that window
  the channel's notices are still dropped, because ACP writes only inside
  the reply to a prompt.
- Terminal: a prompt submitted while another one was generating was queued
  and then dropped without running; it now runs when the turn in progress
  ends.
- Telegram, route without a topic (`default`): the messages of the session's
  live chat room never reached the chat, because the relay was activated with
  the route's room (`default`), not the session's, and its rebind required
  the route's room to equal the session's; the relay is now bound to the
  session's room, as soon as the channel starts driving the slot, on any route
  that serves it (`TerminalTelegramRouteKey.admits(roomID:)`), and a reply to
  a forwarded message reaches its sender. A route bound to another room is
  still refused. Only new messages are forwarded: when an activation starts
  forwarding a room to a chat (the relay's `forwardingRoute` differs from that
  room and chat: the first `/telegram on`, `/telegram on` after `/telegram off`
  or after the route was revoked, both of which unbind the relay, and a room
  swap by `/sessions new` or a load, on the shared route or a topic alike), the
  room's present messages, read before the observation attaches
  (`startSharedChatObservation()`), are marked as handled without a card
  (`activate(...presentMessageIDs:)`, `markPresent`), so the observer's replay
  of the retained transcript forwards nothing. A new lease of the pair already
  forwarded (a route refresh) marks nothing, so nothing a running observation
  has still to offer is skipped.
- Telegram: a turn driven from Telegram never published the sub-agent
  overview, since the channel's presenter did not ask the controller for it;
  it now does, as the terminal does (see above), and the dedup of the
  sub-agent responses is the presenter's, for the life of the channel and
  bounded (512, least recently presented forgotten first), not the turn's. The
  responses present when the channel starts driving the slot, already shown by
  the terminal or the editor, are marked as sent and never reach the chat.
- ACP: a turn driven from Telegram never delivered the task-graph card to the
  chat, since ACP never starts the controller's task-graph observer and the
  editor's per-prompt observer does not run then; the channel now starts it
  while it drives the slot of an ACP session, and the editor's silent presenter
  receives nothing of it. The observer is quiesced at the end of every turn the
  channel presents (`finishTurn(ending:)`), as the terminal does at its
  boundaries: the last graph is published to the turn that ends, before its
  outcome, and the observer runs again once the turn's reporting ended and
  before the next queued prompt starts, so no publication it debounced crosses
  into the next turn.

*Compatibility names.* `TerminalChatActor`, the former public name of
`ChatSessionActor`, was removed in 5.0.0: write `@ChatSessionActor`. The
internal `Terminal*` aliases are removed: `TerminalPromptPurpose`,
`TerminalPlanBrainstormingState`, `TerminalQueuedPrompt`,
`TerminalQueuedPromptMode`, `TerminalQueuedPromptBuffer`,
`TerminalSessionTranscriptTurn`, `TerminalPlanGenerationError`,
`TerminalChatCommandDescriptor`, `TerminalOpenCandidate`,
`TerminalSavedSessionCommandAction`, and `TerminalPlanPointCollector`.
`LocalExecPermissionAuthorizer` and `ACPPermissionBroker` are not deprecated:
they are the terminal's and ACP's channel adapters over
`ChatToolConsentAuthorizer`, the single consent policy.

**Migration: `search-tools` moved into the core.** The optional
feature ID `search-tools` (package `Sources/Features/SearchTools`, product
`search-tools-feature`, selection key `feature:search-tools`) is retired
explicitly. The package and its `ZenBundledFeatureCatalog` entry are removed.
The tools `search.glob`, `search.grep`, and `search.locate` keep their names and
schemas but become core tools of `zen`, implemented in `LocalToolsSupport` and
executed in-process like the file and text tools, so they are available on
macOS and Linux without installation. They form the core group `search` (title
"Search") in `/tools`, and the recommended Developer, Builder, Reviewer,
Reporter, and Planner profiles select it. As read-only core descriptors they are
kept by `readOnly` profiles such as Reviewer and Planner.

- The legacy keys `feature:search-tools` and `search-tools` remain accepted as
  aliases of `search` in `agents.json`, in tool selections, and in saved
  sessions. Nothing is rewritten at startup; the key is rewritten as `search`
  the next time profiles are saved.
- A copy installed in `~/.zencode/features/search-tools` (or under
  `ZENCODE_SUPPORT_DIRECTORY`) is ignored: it is neither loaded nor listed. The
  folder is not modified or deleted, and the user may remove it by hand.
- `zen --install-features search-tools` fails with
  `Unknown optional Swift feature: search-tools.`.
- `search.` is a reserved core namespace, like `local.` and `text.`: it cannot
  be the `toolPrefix` of an MCP bridge.
- No persisted format changes.

**Migration: stable provider keys (settings v15).** Providers are no longer
identified by UUIDs. Every provider has one stable lowercase key, derived by
`AgentRemoteProvider.providerKey(providerProfileID:protocolProfileID:)` (the
single key table; setup presets use it): `openrouter`, `openai`, `anthropic`,
`zai`, `zai-coding-plan`, `google.gemini`, `deepseek`, `moonshot`, `nvidia`,
`modal`, `custom`, `ds4`, `chatgpt`, and `claude`. The key is the provider
profile raw value, except the subscriptions (`chatgpt`, `claude`, the prefixes
their model ids already used) and the Z.ai Coding Plan. The DS4 provider has
its own `ds4` provider profile (formerly `custom`), with unchanged runtime
behaviour. An id is never generated: a provider is configured at most once, and
setup refuses to add a provider whose key is already configured (it must be
reconfigured instead), so Custom exists at most once.

- `settings.json` v15: provider `id`, model `providerID`,
  `memoryEmbedding.providerID`, and the keys of `remoteAPIKeysByProviderID`
  (field name unchanged) hold provider keys. Remote API model ids are
  `<providerKey>:<modelID>` (for example `openrouter:moonshotai/kimi-k3.1-pro`);
  the model component may contain `:`, so ids are split on the first colon.
  Subscription (`chatgpt:<model>`, `claude:<model>`) and DS4
  (`ds4:<catalog-id|file-stem>`) model ids are unchanged. The `remote:<uuid>`
  provider group id becomes `remote:<key>`.
- `AgentProviderKeyMigration` migrates older files automatically and persists
  the result. It runs at composition start in `zen` (after argument validation,
  before the startup configuration gate, for TUI, Telegram, headless, JSONL, ACP, and
  `--setup` alike; `--help`,
  `--version`, `--doctor`, and `--install-features` stay read-only) and again
  right after a backup import. It is not part of the settings load path, so
  reads never mutate files and setup's compare-and-swap baseline stays valid.
  It owns the legacy-UUID-to-key map and commits `settings.json` and
  `agents.json` together under the shared manifest lock with the
  rollback-first journal of `ZenFileService` (atomic `0600` writes). The
  fixed UUIDs `…0003`/`…0004` and the subscription protocols map to
  `chatgpt`/`claude`; `…0005` or a DS4 runtime maps to `ds4`; every other
  provider gets the key of its profiles. Model ids and `llmID`s of the form
  `remoteapi:<uuid>:<model>`, the selected model, the API-key map, and
  `memoryEmbedding.providerID` (dropped when it names no provider) follow. In
  `agents.json`, binding `id`/`modelID`, `defaultModelBindingID`, and the legacy
  profile `modelID`/`defaultModelID` are rewritten at JSON level, so profiles
  that fail strict decoding are kept too; references to a UUID that names no
  legacy provider are left for the next profile save, and an `agents.json` that
  is not a JSON object is left untouched. When two legacy providers map to one
  key, the first in persisted order is kept and the later one is dropped with
  its models and API key, with a warning on standard error naming it.
- The migration runs when the version is below 15 or a provider id is not a
  known key (so a legacy manifest re-saved as v15 after a failed migration is
  still healed); current files, and their `agents.json`, are never touched. A
  failure is reported on standard error and is not fatal: legacy files still
  decode (their UUIDs become lowercase string ids, consistent with the
  UUID-keyed API-key map) and the migration is retried at the next start.
- Saved sessions are not migrated: a `remoteapi:<uuid>:<model>` reference still
  restores through the model-component fallback of `TerminalChat.modelReferences`.
  The `remoteapimodel:<uuid>` and `remoteapi:<uuid>` spellings are no longer
  documented for `--model` / `ZENCODE_AGENT_MODEL`; use `<provider>:<model>`.

`Package.swift` remains the authoritative declaration of the SwiftPM graph,
platform conditions, products, and build flags. Every local Swift target enables
`MemberImportVisibility`: each source file must import the module that defines
members it uses, while `public import` is reserved for intentional API re-exports.
`ZenBundledFeatureCatalog` is the runtime catalog authority for optional feature
identity. Every catalog entry owns a standalone SwiftPM package at its
`sourceRelativePath` under `Sources/Features`; the root `Package.swift`
intentionally declares none of their executable products or targets. Parity
checks ensure that every package has its catalog product and the marker
`// zencode:package-path` immediately above
`.package(name: "ZenCODE", path: "../../..")`. The explicit `name: "ZenCODE"`
keeps the `package: "ZenCODE"` product references valid whatever the checkout
directory is called; installation still accepts and normalizes the legacy
unnamed form. That marked dependency is rewritten when the package is installed outside the
checkout. Linux eligibility remains an explicit `isInstalledOnLinux` catalog
property, so `xcode-tools` remains visible as bundled metadata but cannot be
installed or executed there. Generic MCP bridge scaffolding and execution are
currently macOS-only; Linux eligibility must remain false for every bundled MCP
feature until `FeatureMCPBridgeKit` has a real Linux transport and lifecycle test
suite rather than an unsupported-platform stub.

`xcode-tools` is a macOS-only optional package and owns its entire integration:
MCP bridge discovery and policy, request compatibility, workspace matching,
execution, presentation, and tests. The root graph exports no Xcode feature
product and `ZenCODECore` imports no Xcode implementation module. Linux builds
retain only the generic bundled-feature identity, description, selection aliases,
and timeout required for catalog parity; they compile no Xcode implementation or
compatibility shim.

Presentation content crosses frontend boundaries through the transient,
backend-neutral `PresentationDocument` tree under `Presentation`.
Domain presentation nodes contain only visible text, semantic blocks and opaque
already-uploaded document references; they contain no Telegram types, local file
paths, reasoning records or tool payloads. Reasoning has no place in the tree:
the thinking message is a plain text with entities
(`TerminalTelegramTurnActivity.thoughtMessage(_:)`), never parsed as Markdown.
Transport adapters depend inward on
that tree: the Telegram adapter renders the supported subset to Bot API 10.3
`InputRichMessage` wire values, while the presentation layer never imports or
names Telegram. Rich draft, thinking, and final delivery share the Telegram outbound
governor. An explicit 400/404 compatibility rejection may degrade to the tree's
deterministic plain-text projection; ambiguous transport/server outcomes never
trigger a second final send. The tree is not persisted, so settings, session,
checkpoint and transcript formats remain unchanged.

The transient presentation rule also covers file-change evidence.
`FileChangeArtifactMapper` provides the backend-neutral projection consumed by
both TUI and ACP, while `SessionFileArtifactHistory` keeps the complete,
session-scoped turn history used by `/artifacts` only in memory. It is cleared at
new/load/restore boundaries and is excluded from saved sessions,
checkpoint trees, transcripts, snapshots, and ACP wire formats. TUI and ACP may
render the shared evidence differently, but path normalization, ordering,
deduplication, byte-budget fallback, and binary/uncertain evidence semantics
remain shared. The existing `Summary`, `/changes`, `/changes diff`, `/undo`,
and ACP wire contracts remain unchanged. In TUI, root and delegated tool
completions publish only their new operation artifacts through the same Markdown
renderer as `/artifacts`, including during active thinking/assistant streams.
The history reserves a stable turn number on the first live or final artifact;
it still stores only net-final turns, so reverted live turns can leave number
gaps. Pending turn tokens and per-turn agent/call deduplication are runtime-only
and invalidated on reset. Final reconciliation compares the latest live postimage
with the final bytes already read by the tracker, omitting unchanged live evidence
without hiding a subsequent opaque-tool edit to the same path. Uncertain evidence
is not treated as proof of an unchanged postimage. No watcher, polling, extra
worktree read, or wire field is introduced.

The observable session state follows the same transient rule. A
`ChatSessionStateReducer` (`Chat/State`) records what a session presents in one
ordered log per session, whose entries carry a strictly increasing `sequence`,
and publishes a `ChatSessionSnapshot` after every change; the transcript, the
tool activity, the notices, and the file-artifact history of the snapshot are
projections of that log. The log keeps the byte budget of the session transcript
(`ChatSessionController.maximumTranscriptBytes`, counted the same way) and drops
its oldest entries whole; the notices keep the latest 64. The log and the
snapshot live in memory only: they are never written to saved sessions, session
snapshots, checkpoint trees, or task checkpoints, and they add nothing to the
TUI output, the ACP wire, or the headless and JSONL records. A saved session's
log is rebuilt from its transcript when it is loaded, by the controller in one
place, and a session change starts a new epoch of the log. That rebuild
(`ChatTurnEntry.kinds(fromTranscript:)`) is also what ACP replays at
`session/load` and `session/resume`: the prompts and blocks of the entries
rebuilt from the runtime history, on the same wire as before. The rebuild
pairs a tool result with its call by id, in its turn or still open from an
earlier one, and a result without an id with the oldest call without an id
still open in its turn (with its tool name when it has one), so no restored
call stays running. The terminal replays a restored transcript itself,
because it renders a tool call without an id as started, pairing results by
id only, while the rebuilt log completes it, and because the rebuilt log
keeps one start of a tool call id repeated in a turn. The shell snapshot of a
host (`ChatShellSnapshot`) is transient too.

The transcript of a delegated sub-agent (`ChatSubAgentTranscript`, read with
`ChatSessionController.subAgentTranscript(agentID:)` and scoped to the
controller's session as the root session) adds no event log: it is the same
rebuild of the agent's own backend history, read from the live backend at
each call. The read completes it for presentation only, without changing the
history: an assistant message without reasoning takes the text of its
`thinking` blocks as its thought (Anthropic keeps its reasoning only there),
and when the history has a tool call, the calls take the title and
presentation of the agent's own tool descriptors, which are asked for only
in that case and only as the backend already knows them
(`AgentRuntimeBackend.knownToolDescriptors(sessionID:)`), so a read never
starts a feature's tool discovery (`--list-tools`) or the consent it can ask
for: until a feature whose tools are discovered at runtime is discovered
again after a reload of the feature bundles, only its declared tools are
known. The system prompt, the dynamic context, and the memory block are not
in that history. The only state behind the read is the elapsed time of the
tool calls, which the history does not keep: the runtime records, when it
handles a `.toolCallCompleted` of the agent, the time the tool executor
measured for the call and its result carries
(`DirectAgentToolResult.elapsed`), and keeps, only in memory in the agent's
record, the durations of the agent's most recent tool calls (at most
`DirectSubAgentRuntime.maximumRetainedToolCallDurationsPerAgent`; the oldest
are evicted first, and they survive the agent's turns and its end), exposed
as `toolDurations` by tool call id. Every backend records a tool result
before it reports the completion, so a read between the two can show a
completed call whose duration only a later read has. Once
the agent's backend is shut down (the agent was closed, cancelled, failed, or
released from standby) the read returns `nil`: the runtime keeps no copy of
the history, in the agent's record or anywhere else, and neither the history
nor the durations reach saved sessions, session snapshots, checkpoint trees,
or task checkpoints. A host that wants to show the conversation after the
agent ends keeps its own last read.

Local operation evidence may also contain a complete compact unified patch and
its counts instead of full old/new text. Compaction runs on the operation's
captured regular-file preimage and committed text, never in the mapper or TUI.
Retained text/patch limits remain 64 KiB per image or patch and 256 KiB per
operation, shared by both representations. Temporary snapshot inputs are capped
at 1 MiB per file and 4 MiB cumulatively per operation; compact-diff input scans
have a separate 4 MiB cumulative reservation. The synchronous line diff keeps
three context lines, preserves UTF-8 bytes and final-newline markers, and bounds
line count, edit distance and comparison work. Exceeded budgets produce a clear
explanation, never unavailable counts displayed as zeros. The one exception is
a text file added, deleted or modified during the turn and detected by the
workspace checkpoint: when its evidence exceeds 64 KiB (or the remaining
operation budget), the artifact shows the leading part of its single-file git
patch instead of an explanation only. File header lines stay verbatim, hunks
that fit are kept whole, and the first hunk that does not fit keeps its longest
prefix of whole lines, with its `@@` header recounted for the kept lines (for example
`@@ -0,0 +1,K @@` for an added file, `@@ -1,K +0,0 @@` for a deleted one) and
hunks after it dropped. The artifact keeps the full counts and carries a
truncation explanation with the shown and total diff lines. Only the artifact is
cut: the summary entry keeps the complete patch for `/undo`.
Patches that are not a well-formed single-file git patch, binary evidence and
direct operation evidence (so ACP) keep the explanation-only fallback without a
truncated patch.
Patch-only evidence is not a complete postimage for reconciliation. ACP uses
existing standard text content for these patches; no persisted or wire fields
are added.

Optional feature packages are not executables distributed beside `zen`. The
installer and `zen --install-features` copy a package to
`~/.zencode/features/<id>/`, generate the same manifest shape used by a local
Builder feature, build its release product there, and enable it only after the
build succeeds. The installer retains its source checkout at
`~/.zencode/source/` (or under `ZENCODE_SUPPORT_DIRECTORY`) when it was
bootstrapped from a temporary URL checkout, so later installs can resolve the
root package; an installer launched from a local checkout continues to use that
checkout. Existing user-created Builder packages keep the same discovery,
manifest, and selection contracts.

The task control plane follows the same compatibility rule: `SessionTaskOrchestrator` is the sole mutable owner, task checkpoint schema 1 is written atomically per project/session, and saved-session v4 embeds the checkpoint tree (`SessionCheckpointTree`) alongside the current graph. Schema-1 task graphs may carry additive optional `TaskGraphSavedPlan` metadata: `/plan save` writes a draft graph into a stable project plan-library logical session, preserving the goal and complete plan text beside the existing todo-derived tasks while checkpoints without that field remain decodable. Keeping that library separate from the live chat session lets a logical chat reset delete its own execution checkpoint without deleting explicitly saved plans. `/plan load` requires that no plan is active, reads the library metadata of the oldest saved plan that is not completed into a new unapproved plan, and does not take over previous execution state. `/plan save` may write several draft graphs in one checkpoint commit when the Planner authored a sequence of plans, in sequence order, a plan already in the library keeping its original position; saved sessions keep their current version and may carry an optional ordered list of queued plans beside `activePlan`, so sessions saved earlier still decode. Approval materializes every plan into the current session's graph; a text-only legacy plan receives one stable task rather than an inferred task breakdown. Sessions saved before v4 are not loadable. Backend replacement may rebuild transient model state but must not discard the graph; only a logical session reset deletes its checkpoint. Startup recovery identifies work by the pair `sessionID + graphID`, not by session alone: the selected graph is moved into the current session, which keeps its id, where it must become active/current, and the current session's checkpoint is written before the graph is removed from the old one, so it is never lost (in the terminal this happens before backend creation). A checkpoint's formerly current graph must never replace a different graph explicitly selected by the operator.

`/goal` additionally persists optional `TaskGraphWorkflow` metadata on schema-1
graphs: the immutable original goal (nil only for adopted legacy graphs),
`running` / `awaiting_user` / `blocked` / `completed` control state, an explanatory message,
and a workflow-specific monotonic revision. These are owned and committed only
by `SessionTaskOrchestrator`; frontend reply transcripts remain transient.
Open workflows are retained for recovery even before the first task exists and
after all currently defined tasks complete, including metadata-free legacy graphs.
Completing the last task never finalizes a workflow: the coordinator must verify
the whole objective, then explicitly call `tasks.update` with
`workflow: {state: "completed"}` and the current graph revision. That transaction
atomically marks the workflow and graph completed; only then can recovery pruning
remove its checkpoint and automatic continuation stop for successful completion.
`tasks.update` exposes an exclusive root-coordinator workflow mode requiring
`graphID`, `expectedRevision` from `tasks.list`, and `workflow: {state, message}`;
it rejects task payloads, objective changes, non-current/non-active/non-workflow
graphs, and delegated execution scopes. Both TUI (including Telegram) and ACP
use the graph state to stop on a clarification or genuine blocker, without
parsing explanation text. A plain user reply resumes the same graph and
reinserts its original objective. Resume/rollback compare workflow metadata and
graph incarnation, not task revision, preserving independent child progress;
rollback changes only metadata and advances its token to prevent ABA adoption.
`/goal` keeps a persistent DAG for direct, delegated, or mixed execution and
continues until completion or a genuine blocker; sub-agent tools are optional.
Workflow identity (`isWorkflow`) is separate from delegation policy (the public
`requiresSubAgentExecution` compatibility property is false). Direct work uses
`tasks.update` from `pending` to `in_progress` (creating a coordinator attempt)
and then records its outcome. Successful delegated attempts still require
independent validation regardless of the runtime's completion hint; negative
validation records `failed`, and retry creates a new attempt. The effective
attempt executor determines this policy, not its original task specification.
Workflow lifecycle, ownership, dependency and revision checks remain intact;
explicit completion requires a nonempty graph whose tasks are all `completed`
and whose delegated results have been validated. Manual and plan graphs retain
their derived automatic completion. No task, mutation or delegation grants are
expanded. The runtime checks lifecycle consistency, not semantic goal attainment:
the coordinator is responsible for verifying the original objective before finalizing.
The schema remains 1; `completed` is an additive workflow control-state value.
Existing checkpoints remain readable, and previously terminal graphs are not
silently reopened (their old `running` metadata is not evidence of unfinished work).
Older binaries do not understand the new value in saved finalized snapshots.
Older schema-1 checkpoints without this field still decode. Their unavailable
original objective is explicit rather than inferred from tasks or replayed chat;
the legacy heading protocol remains a compatibility fallback only until first
resume or structured update adopts the graph. This persistence exception is
specific to `/goal`, not unfinished Planner clarification.

`CoordinatorCommandParser` under Agent Core owns shared recognition and transport
routing for `/plan`, `/goal`, and `/review`; `PlanningCommandKernel` owns the
shared planning and workflow semantics consumed by the TUI, Telegram adapter, and
ACP bridge: hidden coordination prompts, Planner identity and output-revision
fencing, structured `todo.write` projection, and coordinator history replacement.
Frontends retain only transport-specific presentation and lifecycle adaptation. An
unfinished Planner clarification is deliberately
runtime-only, non-`Codable` state: it survives ordinary turns and agent/profile
reconfiguration in the same live session, but new-session, load/resume,
close, and shutdown boundaries discard it and close its Planner. It is
never inferred from replayed chat, saved sessions, plan-library metadata, or task
checkpoints. ACP additionally fences every completion by session id, epoch,
active prompt id, collection id, and the runner's session-generation token.
History replacement is serialized with runner creation/recreation; teardown
preemptively invalidates its generation. Cancelled or stale command turns roll
back their own history or task-graph mutation before a new incarnation may adopt
it.

The live messages (`AgentSharedChat`) is deliberately transient: the operator, coordinator, and active delegated agent instances share a bounded, in-memory room that is never written to a session snapshot or task checkpoint. The human operator is a trusted, unregistered sender that never occupies a room slot or mailbox, keeping it distinct from the coordinator LLM. The coordinator authorises at most one synthetic turn from the messages at a time, bound to the prompt it consumes, so a message can never open a second concurrent generation. Delivery is priority-based for every recipient with an active turn: its mailbox is reserved for that turn's direct-tool executor, which appends pending messages only to the model-facing result of the next tool call so the recipient replies immediately and then resumes its current work; visible tool output is unchanged. Idle and standby agents drain into their serial work loop normally. If an active turn ends before another tool boundary, the coordinator monitor or agent work-loop re-arm drains the mailbox and starts the ordinary synthetic/queued fallback turn. Every active observer receives each message from the bounded transcript replay (delivery is deduplicated by message id); the live room is surfaced by the terminal TUI, the linked Telegram chat, and the macOS app; the terminal TUI routes these messages only to its transient `Chat` reader rather than the main transcript, and an observer that falls behind recovers from the transcript on the next poll rather than losing messages; shared-chat messages are never dropped from the terminal event queue. The reader is invisible when closed with no messages, compact with total and unread counts when closed with messages, compact for an empty open state, and expanded for an open state with messages. The macOS app observes the room of each window through the public observation API of `AgentCoreSessionRunner` (`attachSharedChatObservation(rootSessionID:)` and the calls that resolve what it delivers), as the terminal does: it keeps the messages in its own transient `Chat` reader (invisible when closed and every message is read, never saved, reset by a new or loaded session), sends the operator's leading `@mentions` to the room at once, also while a turn runs, and runs an auto-trigger as a hidden coordinator turn of the window, claimed only while the window is idle and given back when the turn does not start; while the window's slot is driven from Telegram (`/telegram on` in the window) the window leaves the auto-triggers to the slot's `TelegramChannel`, which relays the room to the linked chat as it does for the terminal. Readable `@mention` handles are derived from participant display names by an actor-isolated catalogue, routing always resolves back to the stable participant id, aliases are never recycled within a session, and the legacy `@agent-Base64` spelling remains accepted for backward compatibility. No shared-chat state is persisted or restored; `SessionTaskOrchestrator` remains the sole owner of any checkpointed graph state.

The terminal voice mode runs on an engine in `Voice/Mode` behind the platform-neutral `VoiceModeController` contract and is coordinated by `VoiceModeSession` (`Voice/Mode/VoiceModeSession.swift`), a public coordinator the TUI uses and a host app can use as well; it needs no provider change and touches the runtime only through the generic per-turn instruction described below. It is independent of the active agent: `/voice on|off|pause|resume` (bare `/voice` toggles pause/resume) controls it, and its state belongs to the current interactive panel loop only, surviving agent and session switches but never persisted. Each utterance is submitted as an ordinary typed line and final answers are read aloud in full; a paused voice mode neither listens nor reads answers aloud. Text that would read as a slash command is submitted as a plain prompt, so dictation never runs a command. While an answer is read the controller reports it to the input panel, so `Esc` stops the reading (without clearing the draft) exactly as it stops a generation. Dictated prompts are ordinary session history and persist like typed prompts; microphone and synthesized audio, and the recognizer's partial results, are never persisted. The voice language is not a setting: `VoiceLanguage` (`Voice/VoiceLanguage.swift`) resolves the response language, else the system language, else English, for voice mode, the Voice mode setup section and Telegram voice-message transcription alike. The voice mode options are settings, shared by both platforms and staged by the Send mode item of `zen --setup` > Voice mode: the additive optional `voice.utteranceSilenceSeconds` field (whole seconds of silence that end an utterance; default 5) and the send mode, the additive optional pair `voice.sendMode` (`"pause"`, the default, or `"keyword"`; an unknown value decodes as absent) and `voice.sendKeyword` (the typed word, kept when the mode goes back to pause), all in `settings.json`. The `voice.maximumSpokenCharacters` field that 2.4.0 wrote is retired: answers are always read whole, so the field is ignored when decoding and dropped on the next save, as the old `voice.language` key is. `VoiceModeOptions` resolves them against the built-in defaults when `/voice on` creates the controller, so a missing key keeps the default, a non-positive pause is dropped on decode, and keyword mode without a usable word is pause mode. In keyword mode (`VoiceModeSendKeyword`, `VoiceKeywordCollector` in `Voice/Mode`) silence never sends: recognized speech is collected until a segment ends with the word, compared as whole folded words, and the word is removed; on macOS the trailing word counts only once the recognizer has finalized the segment ending with it and a session that ends on its own moves its text into the collector, on Linux the Silero VAD splits speech on a fixed 1 s gap and each printed segment goes through the collector. The live-chat dialogue reports through `VoiceModeController.setAwaitingShortAnswer` whether a yes or no is awaited, in which case a bare answer is sent without the word; a yes/no word is refused as the keyword in setup. The `voice` object is stored while any of transcription, a reading voice or an option is set, and re-running Telegram setup keeps the options like the reading voice.

`VoiceModeSession` holds what is the same in every channel: the `/voice` command with its texts and the lifetime of one controller (created from the settings by the platform factory, or by an injected `ControllerFactory` in tests, and started without awaiting `start()`), the per-turn instruction, the final answer read when a turn ends (`turnDidEnd(finalAnswer:)`), the gating of the comments before a tool call, `Esc` (`interruptPlayback()`), and the live-chat dialogue (`VoiceChatDialogue`): the announcements one at a time, the reading, the reply, the "message to …" phrases, the 60 s answer deadline identified by a token, the `setAwaitingShortAnswer` sync after every transition, the messages older than `announcementsSince` or already read in the reader that are never announced, and the classification of a dictation (`VoiceModeDictatedInput`: text that starts with `/` is a plain prompt, anything else a line as if typed). What only a channel knows is behind `VoiceModeSessionHost`: its texts, the prompt draft (the preview and the take of a dictation), how a dictated line or prompt runs (admission while Telegram drives the slot and the prompt queue included), the room it shows (participants, unread state, marking read, whether a destination is still active, publication), and its serialized context. The session's state (`VoiceModeSessionState`: on, paused, speaking) is published through `stateUpdates()`. One session serves one microphone and its host can change at runtime: `setHost(_:announcingMessagesSince:)` and `targetDidChange(announcingMessagesSince:)` have the semantics of the terminal's rebind (the reading stops, the question and the queued announcements are dropped, only messages sent from the given instant on are announced), and `dictationEnded(through:)` forwards the end of an edited dictation to `discardDictation(through:)`. The session is `@ChatSessionActor`; the host's isolated requirements run there, while its `nonisolated` ones are called from the controller's own context through a `Mutex`-protected relay (the current host, held weakly, and the controller), never through the chat actor, because previews and the end of a reading are reported from inside calls the channel awaits. The host puts the utterances, the speaking changes and the deadline tokens into its serialized context and hands them back to `handleUtterance(_:)`, `speakingChanged(_:)` and `answerDeadlineElapsed(_:)` one at a time, so the session never waits there for room. The TUI is the host through `TerminalVoiceModeHost` (`TUI/Chat/Voice/TerminalChat+Voice.swift`): previews and takes go straight to the interactive reader, an utterance and a deadline token go into the panel loop's `TerminalChatEventQueue` with backpressure, a speaking change is offered first and retried with backpressure only from a task of its own, and the loop's single consumer drives the session in FIFO order; the loop installs its room, its reader buffer and its line handling in the host while it runs, and `/voice on` outside it shows `ZenCODE: /voice is available only in the interactive terminal.` without creating a controller.

On macOS it is local dictation with `SpeechAnalyzer`: `AppleSpeechModel` (`Voice/AppleSpeechRecognition.swift`) picks `SpeechTranscriber` when it supports the language, else `DictationTranscriber` (with frequent finalization), and installs the missing model assets through `AssetInventory` on first use. Each recognition generation gets its own analyzer fed with the converted microphone samples; volatile results preview the segment in progress and final results close it, utterances end on a silence gap, and final answers are synthesized locally. Capture and playback share one `AVAudioEngine` whose I/O nodes run in system voice-processing mode for echo cancellation, and synthesized speech is rendered into that engine so it is cancelled from the microphone as well. Answers are read with the system voice chosen in `zen --setup` > Voice mode (macOS downloads nothing; the section lists the installed `AVSpeechSynthesisVoice.speechVoices()` of the voice mode language, without novelty voices and Personal Voice — Siri voices are not exposed to other apps) or, with "Automatic", the best installed voice of the exact locale, else of any region of the language. Choosing a voice, or "Automatic" while an installed voice reads the language, opens a preview submenu whose "▶ Listen" reads a short sample with `AVSpeechSynthesizer.speak(_:)` straight to the system output (no microphone, no voice-processing engine, nothing saved) and returns at once, so the menu stays usable; a new sample or leaving the submenu stops it, only "Use this voice" stages the choice, and the player is an injectable seam so tests play no audio. The choice is the additive optional `voice.macOSVoiceIdentifier` field of `settings.json`, staged like the other setup sections and read when `/voice on` creates the speaker. A saved voice is used only while `AVSpeechSynthesisVoice(identifier:)` still resolves it and it reads the primary language of the resolved voice mode language; otherwise the automatic choice applies, so a removed voice or a later language change never reads answers with the wrong pronunciation. The `voice` object stays a single settings value: `enabled` keeps meaning Telegram voice-message transcription, the object is stored while either transcription, a reading voice or a voice mode option is set, settings without the new keys decode unchanged, and re-running Telegram setup keeps the reading voice (also on Linux, where the field is inert). The former `language` key, which Telegram setup wrote as a fixed `"it"` that overrode the response language, is ignored when decoding and no longer encoded, so it disappears on the next save; versions that still read it fall back to their own default.

On Linux it runs the sherpa-onnx command-line programs as external processes; nothing is linked into ZenCODE and the SwiftPM graph is unchanged. `sherpa-onnx-vad-alsa-offline-asr` (Silero VAD with the configured silence gap, 5 s by default, Parakeet TDT 0.6B v3) listens on the default ALSA device and prints one line per utterance; `sherpa-onnx-offline-tts-play-alsa` reads an answer with a Piper voice and exits, with its mandatory WAV output pointed at `/dev/null`. Without echo cancellation the microphone is off while an answer is read: the recognizer process is stopped before reading and relaunched when the reading ends or `Esc` interrupts it. The programs, models and the single chosen voice are downloaded only from `zen --setup` > Voice mode (Linux only), from the sherpa-onnx GitHub releases pinned in `Voice/SherpaOnnx` by URL, size and SHA-256 (a newer upstream file requires a ZenCODE release). Each file is streamed into `<support directory>/voice/.staging`, verified, unpacked with the system `tar`/`bzip2`, and moved into place, so an installed directory is always complete. `<support directory>/voice/` holds only re-downloadable programs and models: a Data management export skips it, and an import, which replaces the whole support directory, removes it.

The per-turn instruction is the generic channel `AgentTurnInstructionContext.currentTurnInstruction` (`Agent/Runtime/Configuration`), a task-local that the runtime transports without reading it, mirroring the memory block of `MemoryTurnContext`. `AgentCoreSessionRunner.sendPrompt(..., turnInstruction:)` binds it only around the single `backend.sendPrompt` call, and `RemoteGenerationClient.applyingCurrentTurnMemory(to:block:instruction:)` appends it, after the `<project-memory>` block, to the outgoing copy of the last user message. Session history, saved snapshots and the session cache key never see it, and with neither a block nor an instruction the request stays byte-identical. Delegated sub-agent turns and the memory proposal bind `nil` and so never receive it, and ACP passes none. Voice mode is the only caller that sets it: `VoiceModeSession.turnInstruction()`, which the terminal's `voiceTurnInstruction()` asks for every prompt, returns a fixed English instruction for every prompt while voice mode listens (running and not paused), asking for short sentences and brief comments on the work. Those comments show in the terminal, and only the final answer is read aloud.

Telegram voice-message transcription (`AgentVoiceTranscriptionService`) is enabled by Telegram setup on every platform. macOS transcribes the downloaded file on the Mac with `SpeechAnalyzer` and the same model choice and first-use asset installation as voice mode, in the resolved voice language. Linux reuses the Voice mode installation through `SherpaOnnxFileTranscriber` (`Voice/SherpaOnnx`); `SherpaOnnxVoiceInstallation.transcriptionPaths()` requires the programs, the recognizer and the voice activity detector, but no Piper voice. The decoders are resolved from the fixed directories `/usr/bin`, `/bin` and `/usr/local/bin`, independently of `PATH`: for Ogg Opus `opusdec`, with `ffmpeg` as the fallback when both are installed; for any other format `ffmpeg` alone. When `opusdec` fails (non-zero exit, launch error or no output file) its partial output is removed and `ffmpeg` decodes the same input; a cancelled decoder is never retried, and when both fail a single `decodingFailed` error names `opusdec` and carries both reasons. It writes a 16 kHz mono 16-bit WAV into a private `0700` temporary directory that is removed on every exit path. `sherpa-onnx-vad-with-offline-asr` (Silero VAD, Parakeet TDT 0.6B v3, `--model-type=nemo_transducer`) prints one `<start> -- <end>: <text>` line per segment on stdout, and the segments are joined. Both programs run off the cooperative pool with bounded stdout and a stderr tail for diagnostics; cancelling the transcription task sends SIGTERM, then SIGKILL after a short grace, because children can inherit the terminal's ignored SIGTERM. Missing files, a missing decoder and program failures surface as operator-facing errors on the terminal and in the linked chat. Nothing is linked into ZenCODE and the SwiftPM graph is unchanged.

Telegram uses one `TerminalTelegramBotDispatcher` per `ChatSessionHost`,
shared by the control services of its slots' channels, as the exclusive owner
of long polling and offset persistence, with one long poll per bot (an app
runs one host per process: a second host on the same bot would poll it twice,
and the Bot API would answer HTTP 409). It broadcasts raw
updates to active control services before those services apply their room ACL,
so no session can acknowledge and discard another session's traffic. Ingress is
resolved only by `TerminalTelegramSessionRouter`; the resulting lease includes
the ACL route generation and a separate effective forum topic. That lease is
carried through queue admission, generation cancellation, route-scoped
permission state, drafts/cards and final egress, with validation before every
route-scoped turn side effect. Chat-wide fallback ACLs therefore do not collapse forum
topics. Stop is an awaited barrier for poll subscription, presence, rate state,
consents and temporary files. Outbound consent captures SHA-256 at offer time
and the multipart encoder verifies the hash while reading the exact bytes that
will be sent.

## ZenCRON Host

`ZenCRON` is the program that cron runs for every scheduled prompt that
`/cron add` writes; it then starts `zen`. On macOS the privacy (TCC)
permissions of a cron job are attributed to the first program cron starts, and
they stay with it for all its descendants, the features that `zen` launches
included. `zen` is signed only ad hoc, so its identity changes with every
installation and the permission prompts would come back after each update.
ZenCRON is the stable identity that receives them.

ZenCRON is not an optional feature and not a composition root: it selects no
backend and reads no settings. The backend is chosen in one place of Core,
`ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are
composition roots that inject it; no other layer of Core chooses a backend.
The contract is written at the head of
`Sources/ZenCRON/Sources/ZenCRON/main.swift` and is summarized here:

- **Package.** A standalone SwiftPM package at `Sources/ZenCRON`, with the
  product and executable target `ZenCRON`, no dependencies, and a package-local
  test target. Its source imports only the C library (`Darwin`, `Glibc`, or
  `Musl`). It does not depend on `zen`, on `ZenCODECore`, or on any other
  ZenCODE target, and none of them depends on it: `ZenCODECore` knows only its
  installed path, its name, and the output of `--zencron-version`.
- **Invocation.** cron runs it by absolute path. Every argument is passed to
  `zen` verbatim, an empty list included. The one exception is
  `--zencron-version` as the only argument: ZenCRON prints the line
  `ZenCRON <number>` (today `ZenCRON 1`) and exits without looking for `zen`.
  `zen --setup` and `/cron add` use it to compare versions and to check that the file
  starts.
- **Finding `zen`.** On the `PATH` of its environment, which under cron is the
  `PATH=` line of the ZenCODE block; an unset `PATH` counts as empty. Entries are
  separated by `:`. Empty and relative entries are ignored, because they would
  depend on the working directory of the job. Trailing slashes are removed (the
  entry `/` gives `/zen`). The first `<entry>/zen` accepted by `access(X_OK)`
  wins and is passed to `zen` as its `argv[0]`. This is deliberately the rule of
  `ZenCronJobCommand.locateZen(onPath:)`, which `/cron add` uses to check the
  block's `PATH`: the `zen` accepted when the job is scheduled is the one
  ZenCRON runs. Change both together, or neither.
- **No `zen`.** ZenCRON writes `ZenCRON: no executable zen in PATH=<value>` to
  standard error and exits with 127.
- **Spawn, never exec.** ZenCRON starts `zen` as a child with the same
  arguments, environment, standard descriptors, and process group, waits for it,
  and ends the same way: with its exit code, or by dying from the same signal.
  After an `exec`, TCC would evaluate `zen` again and the host would be
  pointless. SIGTERM, SIGINT, SIGHUP, and SIGQUIT are forwarded to the child.
  ZenCRON never changes session or process group.
- **Host version.** The version of the host's behaviour is the number printed by
  `--zencron-version`. It is raised only when that behaviour changes: on macOS
  every new version is a new binary, for which macOS asks for each permission
  again.

ZenCRON is built by `zen --setup` (the **Scheduled prompts (ZenCRON)** section), not
by the installers, and it is not in the release archives. The setup flow uses
the ZenCODE source checkout of the optional features, syncs `Sources/ZenCRON`
to `<support directory>/zencron/package` (keeping the `.build` directory there,
so builds are incremental), runs `swift build -c release --product ZenCRON`,
and installs the binary as it was built, without sudo, at
`<support directory>/bin/ZenCRON`. The replacement rule depends on the platform:

| Platform | Installed ZenCRON has the same version as the build | Installed ZenCRON is missing, unreadable, or of another version |
| --- | --- | --- |
| macOS | kept, so the permissions granted to it stay valid | installed |
| Linux | replaced | installed |

On Linux the Swift runtime is linked dynamically to the toolchain, so a ZenCRON
built with a previous toolchain may stop starting after a toolchain change; it
is built again from `zen --setup`. The section stores nothing in `settings.json`, and
no persisted format changes.

`/cron add` requires an installed ZenCRON that answers `--zencron-version`
with a single `ZenCRON <number>` line, on every platform, and refuses before it
reads or writes the crontab otherwise. Lines written before ZenCRON existed keep
a bare `zen`; they remain valid, but on macOS their permissions still belong to
`zen`. The CI job `zencron-package` tests and builds the package on macOS and
Linux and checks its `--zencron-version` output. The installers and the release
archives are unchanged.

## Provider Boundary

ZenCODE composes its agent backend from remote providers reached over the
network: OpenAI-compatible HTTP endpoints and the browser-authenticated
subscription bridges. The single exception is the optional DS4 local runtime:
a model whose manifest carries `ds4Runtime` is served in-process by a
user-built engine library loaded at runtime (see
[DS4 Local Runtime Compatibility, Ownership, and Persistence](#ds4-local-runtime-compatibility-ownership-and-persistence)).
This remote-provider boundary is an intentional,
announced compatibility migration, not an incidental gap: apart from that DS4
exception the runtime holds no model weights and performs no inference
in-process, so generation, token
budgeting, and any model/attention cache belong to the provider. The backend
is chosen in one place of Core,
`ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are
composition roots that inject it; no other layer of Core chooses a backend.
The chosen remote provider reaches the runtime through the same runtime
contracts described below. The
client-side persistence surface stays local and provider-agnostic: session
snapshots, checkpoint trees, task graphs, permissions, feature manifests, and
the session cache-key formats survive a change of provider, while only transient
per-request model state is rebuilt.

The prompt-skill tools (`skills.list`, `skills.read`) are intrinsic, always-on
tools owned by `AgentCoreSessionRunner` as a per-session mutable
`PromptSkillSessionProvider`. Their descriptors and the single static skill
instruction in the system prompt are part of the stable remote session identity
from creation — even with no skills selected — so adding or removing a skill
updates only the provider snapshot (via `updatePromptSkillSelection`) and never
the system prompt, allowlist, cache key, history, or remote continuation. The
model discovers the current selection at runtime through `skills.list` and loads
guidance through `skills.read`. `skills.list` remains metadata-only; it never
includes prompt bodies, source directories, or resource contents. `skills.read`
returns the normalized absolute installed `sourceDirectoryPath` when available
so relative resources and script paths can be resolved against the real skill
directory. That installed path takes precedence over stale/example paths in
skill guidance. `skills.read` is a reader, not an executor: it cannot access
arbitrary filesystem paths and accepts only selected-skill guidance or relative
regular resources within that skill's boundary. For referenced scripts,
guidance to use `local.exec` is conditional on the tool being available and the
specific command being authorized by the local-execution permission policy. If
`local.exec` is unavailable or unauthorized, the model must report a blocker
rather than inspect the script or infer/invent a path. When no source directory
is available, the read output says so and likewise requires a blocker instead
of an invented path. Resource paths remain relative, are resolved under the
selected skill's boundary, and are rejected when they traverse that boundary
or are not regular files. Revocation is non-retroactive
(it blocks future reads but cannot erase guidance already in the conversation
without sacrificing the continuation). A session persisted with a legacy
eager/lazy skill catalog is normalized to the static instruction on restore,
which is a one-time full replay; subsequent selection changes are cache-stable.

Remote generation has one cross-platform transport stack. HTTP/1.1, incremental
SSE, and ChatGPT Responses WebSockets under `Remote/Generation`, the ChatGPT
client/task/pool, and Anthropic messages are expressed as `RemoteHTTP*` /
`RemoteWebSocket*` values and executed only by `RemoteTransportCore` on
SwiftNIO. Those paths must not select an implementation through platform
conditions, Foundation networking, Network, or libcurl. The `CLibCURLWebSocket`
target and its adapter are retired; no system curl linker dependency remains.

Feature invocations may add an optional `attachments` array to the successful
`--invoke` envelope. Each `FeatureInvocationAttachment` names an absolute local
image path plus its kind and content metadata; `FeatureRunner` emits the field
only for outputs conforming to `FeatureInvocationAttachmentProviding`, so the
legacy envelope remains byte-for-byte unchanged for ordinary feature tools.
`ZenCODECore` must read and validate each declared file before it becomes an
`AgentRuntimeAttachment`, retain it on the tool message in session snapshots,
and map it to the provider's native multimodal form. Chat Completions receives a
text tool result followed by a grouped user image message, Responses receives a
`function_call_output` followed by `input_image` content, and Anthropic embeds
the image content inside `tool_result`. A feature-generated image path must
never be sent to the remote provider as a substitute for the image bytes.

MCP-backed features whose tools change files in another process may also add an
optional `fileChanges` array to the successful `--invoke` and `--serve`
invocation envelopes. Each `FeatureInvocationFileChange` carries an absolute
path, optional before/after text, and an optional explanation when no diff is
available. `RemoteMCPFeatureRunner` emits the field only when it is non-empty,
so the legacy envelope stays byte-for-byte unchanged. The evidence is
transient and advisory. `ZenCODECore` drops undecodable lists, relative paths,
and entries beyond the cap instead of failing the tool. It records the rest
through `ExternalFileChangeEvidence` under the same byte, binary, and
compact-diff policy as local writes; the evidence is never persisted.
`xcode-tools` produces this evidence by reading the local filesystem around
`XcodeUpdate`, `XcodeWrite`, `XcodeRM`, and `XcodeMV` calls. It never makes
extra Xcode content reads.

Feature manifests may opt into the additive `supportsPersistentSession` flag.
For those features, the session-owned `SwiftFeatureRuntime` starts one private
`--serve` JSON-lines process and reuses it for runtime discovery plus subsequent
invocations; reload, explicit shutdown, or runtime teardown closes the process.
The transport is opt-in and internal: the stable one-shot `--list-tools` and
`--invoke` commands and their JSON envelopes remain unchanged. `xcode-tools`
uses this mode so its package-local MCP executor and Xcode consent live for the
whole ZenCODE session instead of being recreated for every tool call.

`RemoteTransportCore()` borrows the process-wide NIO event-loop group. A client
that constructs its own transport closes it during `shutdown()`; an explicitly
injected transport remains owned by its embedding composition root. The ChatGPT
pool follows the same rule: `closeAll()` is reusable, while its terminal
`shutdown()` closes its default owned transport. Historical `urlSession`
initializer labels and properties remain typed compatibility values for source
consumers, but are never consulted for generation I/O. The compatibility facade
is deliberately isolated from the transport engine; it preserves API inspection
and injection without restoring a second networking path.

The root ChatGPT Subscription session prefers Responses WebSockets, but transport
availability is session-scoped rather than mandatory. Delegated ChatGPT
sub-agent backends start directly on HTTP/SSE: each delegated backend remains
reusable after completing work, so allowing every one to retain an independent
WebSocket would accumulate uncoordinated long-lived connections across parallel
batches. Structured transient Responses failures and transport failures retry on
a fresh WebSocket within the bounded replay-safe budget, matching Codex; an HTTP
426 upgrade rejection or exhaustion of that budget switches a root logical agent
session to HTTP/SSE for all later turns and tool rounds. The HTTP
scope key combines the logical session with its installation generation, remains
independent of the rotating WebSocket transport ID, and survives continuation
resets without leaking into a recreated session incarnation. Closing that
incarnation fences late activation and cancels any HTTP stream that is opening or
active. The transport client never replays events after replay-unsafe reasoning,
refusal, content, or tool output crosses its callback boundary. At the generation
boundary, an unexpected transient transport interruption receives one bounded
full-turn retry on a fresh transport connection even when provisional stream
callbacks have started: final assistant content and tool calls remain buffered
until a terminal event, so the failed accumulator can be discarded without
duplicating a committed assistant response or executing a tool twice. HTTP/SSE
completion requires a terminal Responses event; `[DONE]` or EOF alone cannot
commit partial output.
Structured `error` events use stable transient identifiers
(`server_error`, `server_is_overloaded`, `slow_down`,
`websocket_connection_limit_reached`, or `previous_response_not_found`) or a
wrapped 5xx status. A `response.failed` event is also retryable by event
provenance after known context, quota, policy, and malformed-request identifiers
have been excluded, matching Codex even when the backend omits a transient code.
When received again over HTTP/SSE, these failures retry within the bounded stream
budget only when no replay-unsafe output crossed the callback boundary. A valid
provider retry delay on a rate-limit failure takes precedence over the local
exponential backoff. Message text or callback errors alone can never activate
that retry. Authentication failures retain their token-refresh path on both
transports.

Each opened HTTP/SSE response and upgraded WebSocket separates its public handle
from the NIO driver actor that the scoped `executeThenClose` run-task retains.
`RemoteHTTPBody` / `RemoteHTTPStreamingResponse` / `RemoteSSEEventStream` (and
their iterators) and `RemoteWebSocketConnection` are the handles; they retain a
shared internal `RemoteTransportLifetimeToken`, while the run-task captures only
the driver actor and a weak reference to the token. Releasing the last handle
copy closes the channel lease, cancels the run-task, and abandons the driver's
continuation-based waiters, so the run-task completes and the driver is released
even when a consumer stops draining a stream. This is reached only through
actual handle release, never through a `channel.closeFuture` observation: the NIO
inbound iterator stays the sole authority for a clean end-of-stream versus a
Content-Length or framing truncation error, so such errors are never masked as a
clean `nil` (the earlier regression).


Authentication remains intentionally separate from generation transport.
ChatGPT uses the macOS local-browser callback (including its callback listener)
and the non-macOS device-code flow; its OAuth exchanges retain their
provider-specific behavior. Anthropic retains its hosted authorization-code
flow and OAuth exchange behavior. These Auth/Callback-only differences may use
platform APIs where required, but must not change provider IDs, wire event
handling, credential persistence, backend selection semantics, or the common
generation transport.

## DS4 Local Runtime Compatibility, Ownership, and Persistence

DS4 is an optional local runtime that `ZenCODECore` runs in-process. The engine
is `libzencode-ds4.{dylib,so}`, a ZenCODE-owned C shim compiled on the user's
machine against the user's DS4 checkout. `ZenCODECore` loads it at runtime with
`dlopen(RTLD_NOW | RTLD_LOCAL)`, so `zen` has no compile-time dependency on DS4.
No DS4 server process and no loopback endpoint exist. The DS4 provider remains
a provider in the manifest. Its generation goes through a dedicated branch of
`RemoteGenerationClient` that calls the in-process engine instead of HTTP.

This is a local, in-process exception to the remote-only boundary described in
[Provider Boundary](#provider-boundary). The `zen` composition-root rule and the
provider-agnostic session and checkpoint formats are unchanged. The operational
guide is [ds4.md](ds4.md).

### Components

1. **Engine library.** `DS4EngineLibrary` resolves the symbols of the ABI version
   `DS4EngineABI.expectedVersion` (2; version 2 added `zencode_ds4_tokens_push`, so
   a version 1 library is obsolete). A version mismatch or a missing symbol is
   reported as a stale or foreign build. `DS4EngineLibraryLocator` finds the
   library at `<support>/ds4/engines/<backend>-<hash16>/libzencode-ds4.{dylib,so}`.
   The hash is the first 16 hex characters of the SHA-256 of `ds4.h`,
   `zencode_ds4_shim.c`, and `zencode_ds4_abi.h`, concatenated. `build.json`
   records the root, backend, architecture, date, hash, and ABI version. A
   library whose metadata does not match is `stale`.
2. **Build.** `DS4EngineBuilder` extracts the embedded shim sources and
   `Scripts/build-ds4-engine.sh` into `<support>/ds4/shim/` and runs the script
   through setup or by hand. The shim is compiled against the checkout's
   `ds4.h` and linked with the objects of the DS4 Makefile that it needs. Only
   those objects are built, by name; `make clean` is never run. The toolchains
   are Xcode Command Line Tools (`metal`), `cc` with `-DDS4_NO_GPU` (`cpu`),
   `nvcc` (`cuda`), and `hipcc` (`rocm`).
3. **Shim sources.** The canonical copies are
   `Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h` and
   `zencode_ds4_shim.c`, excluded from the SwiftPM target. The generator
   `Scripts/GenerateDS4EngineShimSources.swift` embeds them in
   `Sources/ZenCODECore/Local/DS4/Engine/DS4EngineShimSources.generated.swift`.
   Its `--check` mode verifies that the embedded copy is current, and a parity
   test compares the two. The sources live in the binary because the installers
   copy only `zen`, not SwiftPM resources.
4. **Runtime.** `DS4NativeEngine` implements `DS4Engine` and runs every C call on
   one dedicated thread (`DS4EngineThread`). `DS4EngineRegistry` is process-wide
   and keeps at most one engine open. Its FIFO generation lock serializes the
   `sync` and `generate` rounds, and a different model closes the open engine
   after the round in progress. `DS4SessionPool` maps ZenCODE sessions to live
   engine sessions, with LRU eviction and the capacity `engineSessions`.
5. **Transcript and tools.** `Local/DS4/Generation` renders the transcript with
   the native chat template and tool syntax of the model family, compacts it
   (`DS4CompactionPolicy`), maps `/think` (`DS4ThinkModeMapping`), and stages
   images (`DS4ImageStaging`). `Local/DS4/Tools` holds the tool syntax and the
   streaming parsers. The private `ds4_*` message keys (`DS4MessageKeys`) let
   already sent turns be reproduced exactly: a generated turn is replayed with
   the token ids the engine committed (`DS4GenerateResult.tokens`, kept as
   `ds4_raw_tokens` with the identity of the model, `DS4TranscriptOperation.tokens`)
   so the common prefix with the live KV does not depend on how the text would
   be tokenized again, and falls back to the raw text for another model. They
   never reach snapshots or other providers.
6. **Remote client and control.** `RemoteGenerationClient+DS4Engine.swift` drives
   the rounds, and `RemoteGenerationClient+DS4Checkpoint.swift` saves and restores
   KV checkpoints. `AgentDS4Control` holds the values changed with `/ds4`, which
   are never persisted.

### Identity rules

The checkout's catalog and download identity is separate from the model's API
identity. A `DS4ModelCatalog` entry exposes `apiModelID`. For a GGUF outside the
catalog, the API id is inferred from the file name (`DS4ModelCatalog.inferredAPIModelID`)
or chosen among the six ids that DS4 serves. Setup may keep a stable ZenCODE
selection key, `ds4:<catalog-id>` or `ds4:<file stem>`, but the model manifest and
provider payloads use the canonical API id. The engine has no `/v1/models`
readiness step: the API id is the model id recorded on the manifest, and no alias is
invented.

### Ownership and lifecycle

`ZenCODECore` owns the DS4 scanner and catalog, the setup integration, the
persisted DTOs, the library locator and builder, the engine registry and pool,
and the remote-client adaptation. The backend is chosen in one place of Core,
`ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are
composition roots that inject it; no other layer of Core chooses a backend.
Terminal UI, Telegram, ACP, and delegated-agent layers do not own the engine.

Sub-agents that use the same DS4 model share the open engine and its FIFO queue.
A sub-agent that selects another provider is an ordinary remote client and never
touches the engine.

Closing an agent backend is handled as follows:

Closing an agent backend (for example on an agent switch) releases only its DS4 sessions; the loaded model stays resident. The engine is closed when `zen` exits, when a different DS4 model is requested, or when a new agent backend uses a non-DS4 model while no DS4 session is live.

### Process boundary

One DS4 model runs per `zen` process. DS4's instance lock (`/tmp/ds4.lock`, or
the path in `DS4_LOCK_FILE`) prevents a second DS4 process from using the model,
and that process fails with an explicit error. DS4 calls `exit()` on a malformed
or unsupported GGUF, which ends `zen`; this is an accepted limit.

### Persistence boundary

`ds4Runtime` is an additive optional field in provider and model manifests. A
model-level runtime is authoritative for that model, so one DS4 provider can
serve several GGUFs from the same folder, each recorded on its own model
manifest. The provider runtime is the fallback for models that carry none.
Manifests that stored the same runtime on both records resolve identically, and
manifests without the field remain decodable.

The persisted runtime contains configuration only:

- canonical absolute `rootDirectory`;
- `modelRelativePath`, and the auxiliary paths `visionRelativePath`,
  `mtpRelativePath`, and `steeringRelativePath`, relative to that root;
- `backend`, `contextWindow`, the SSD streaming options, and the MTP, DSpark,
  steering, and engine options;
- `cudaArch`, `rocmArch`, `engineSessions` (1...8), and `extraEngineArguments`,
  opaque tokens that the shim validates with DS4's public parsers.

The retired `batchedSessions` key is ignored when decoding and never written.
Path validation canonicalizes the root and rejects absolute or traversal model
paths, escapes, symlink components, missing required files, and non-regular
files. Process IDs, runtime state, readiness, diagnostics, and hardware
information are not persisted. The provider base URL, `http://127.0.0.1:8000/v1`,
is only a compatibility placeholder that the in-process engine does not use.

Setup stages a complete candidate and commits it only through the existing
cooperative manifest transaction. A failed scan, validation, cancellation, or
empty selection returns the prior manifest, and non-DS4 providers, models,
credentials, and unrelated settings are retained.

Engine state is not part of session snapshots, task checkpoints, cache keys, or
any other durable session state. The one exception is the explicit KV checkpoint
`<name>.ds4kv`, written beside the session file by `/sessions save` and
`/sessions <name>`. It is restored when the session loads with a DS4 model, and
it carries a versioned trailer with the DS4 metadata of each message. It is
skipped for sessions with images or without live DS4 state, and it is deleted
with its session. It is not part of snapshots or task checkpoints. See
[ds4.md](ds4.md#kv-checkpoints-ds4kv) for the operator flow.

`SensitiveManifestCoordination` is the cross-process ownership boundary for
cooperative writes and destructive reset of application-support manifests.
Setup captures a read-only compare-and-swap baseline, validates the final
`settings.json`/`agents.json` pair, and commits it under one lock with a
restrictive recovery journal. Transactional publish/delete steps synchronize the
parent directory so journal, manifests, and cleanup retain their ordering across
system crashes. The journal is rollback-first: successful unlink is the commit
point, while any earlier interruption restores the original generation.
Delegation loads the pair under that same lock and completes such recovery
before routing. Individual
files continue to use `SensitiveFilePermissions` for symlink rejection, `0600`
temporary inodes, data synchronization, and atomic rename. Test and embedding scopes
that need a different support root use `AppStorageDirectory`'s lexical
`TaskLocal` override; the historical process-wide override remains compatible.

## Target Layout

The root product surface is intentionally simplified: interactive setup now
belongs to `ZenCODECore`, and the former `ZenCODESetup` product/target has been
removed as an explicit migration.

Within `ZenCODECore/ZenCODE`, the internal `DirectToolRuntimeBackend` refinement
in `Agent/Runtime` shares forwarding for three remote clients without changing
`AgentRuntimeBackend`, concrete public APIs, external defaults, or ownership;
Anthropic retains its overhead-invalidation overrides. The internal
`TerminalSelection` helper in `Tools/Selection` shares tool/skill selection syntax
and Unicode lookup normalization, leaving domain-specific resolvers and errors
separate. Feature record-to-bundle projection uses an internal initializer, and
status construction avoids a redundant intermediary while preserving `source`
and `isCore` overrides and permissions. The internal `ModelNamePresentation`
helper under `Presentation` owns the two identifier-to-display-name transformations
shared by setup and terminal presentation. The existing public `TerminalChat`
formatting methods remain compatibility forwarders; model identifiers, catalog
lookup, and persisted bindings are unchanged. `ToolRenderingPolicy`, also under
`Presentation`, owns the two decisions about a tool call that the terminal and
the Telegram activity rows share and that carry no styling: which calls have no
representation (`shouldSuppressToolRendering(for:)`) and which completed calls
count as failed (`toolResultIsFailure(for:result:)`, with the reading of the
`exit_code:` line of a `local.exec` result), so the Telegram channel applies
them without a terminal type.

| Area | Intended responsibility and directory layout |
| --- | --- |
| `Sources/ToolCore` | Dependency-light wire, descriptor, environment, compatibility, and declarative tool-presentation types used by lower-level process/transport modules. It contains no registry or presentation policy keyed by tool name and does not contain Xcode- or Figma-specific request or workspace behavior. |
| `Sources/FeatureKit` | Feature contracts, schemas, process protocol, runner support, and shared process-tree supervision/TERM→KILL escalation; depends on `ToolCore`. `Process/` owns the lifecycle primitives both one-shot and persistent feature processes reuse: a race-safe typed one-shot signal (exit observation and termination requests), descriptor helpers (idempotent SIGPIPE ignore, non-blocking switches, quiet close), and a bounded SIGTERM→grace→SIGKILL escalator with cancellation-aware exit waits, so `FeatureProcessRunner` and `FeaturePersistentProcess` retain orchestration and JSON-lines protocol responsibilities without duplicating low-level state machines. `Network/` owns the policy-free network primitives the Web and Browser features share: `FeatureIPAddress` parsing (canonical dotted quad, WHATWG/`inet_aton` IPv4 literal forms and "ends in a number", `inet_pton` IPv6, IPv4 embedded in compatible, mapped, 6to4, or NAT64 form) and the public/loopback/non-public classification, the `getaddrinfo` `FeatureSystemHostResolver` with neutral errors, the generic `FeatureSingleResumeBox`, and the cancellation-aware `FeatureBlockingOperation.run` offload. It contains no policy: URL schemes, which host names may be contacted (the access policy over names such as `localhost` or `.local`, which `FeatureIPAddress` never classifies), what loopback means, and user-facing errors stay in each feature. The one name-level rule it encodes is resolution, not access: `FeatureSystemHostResolver` still resolves `localhost` and any `.localhost` name to `127.0.0.1` and `::1` per RFC 6761, without asking the platform resolver. Every `FeatureTool` owns and publishes its explicit `ToolPresentationDefinition`; `--list-tools` requires the same contract for generated and bundled features. Outputs may conform to `FeatureInvocationAttachmentProviding` to add validated local images to the model's multimodal tool context. |
| `Sources/FeatureMCPBridgeKit` | Generic MCP feature integration, configuration, transports, OAuth, execution, injectable local-transport policy hooks, and typed shared MCP pump/transport units. Local stdout, stderr, and diagnostics all drain through one bounded `MCPStreamPump` with a single cancellation/EOF/policy-stop/read-failure contract; per-stream differences are expressed as typed handlers, line framing is owned by a bounded accumulator, and the former single stream-handling file is decomposed into focused readers, stdio events, message routing, transport policy, process lifecycle, and logging units so no file combines pumping, diagnostic policy, JSON-RPC routing, and pending-response completion. It has no Xcode- or Figma-specific endpoint, reachability, or workspace behavior; optional feature packages own those policies. |
| `Sources/Features/FigmaTools` | Standalone Figma MCP feature package. It owns the Figma Desktop endpoint and reachability policy and passes only generic MCP configuration into `FeatureMCPBridgeKit`; the generic bridge kit must not contain Figma-specific factories or network probes. |
| `Sources/Features/XcodeTools` | Standalone macOS-only `xcode-tools-feature` package. Its package-local `XcodeToolsFeature` library owns MCP configuration and policy, compatibility normalization, workspace selection, discovery, execution, presentation, and error mapping; its thin executable delegates to that private implementation. The package depends only on the root's generic `FeatureKit`, `ToolCore`, and `FeatureMCPBridgeKit` products. |
| `Sources/Features/BrowserTools/Sources/BrowserToolsFeature` | `BrowserToolsFeature` library target owned by the standalone Browser package: the opt-in Chrome/CDP Browser runtime, direct URL policy plus a per-invocation Fetch/DNS request guard (both built on FeatureKit's address classification and system resolver; Browser keeps its loopback capability, `.local` names, and fail-closed ambiguous numeric hosts), persistent page handles, fixed viewport presets, scoped state reset, bounded semantic observations, snapshot-bound DOM/computed-CSS inspection, page and element wait/assertions, guarded interactions, redacted/filterable network diagnostics, decoded-pixel screenshot comparison with Browser-owned diff artifacts, and PNG/PDF artifacts. It denies downloads fail-closed, must not enable Browser in a default agent profile, and must not expose raw CDP/JavaScript evaluation or selectors to the model. The request guard is not a persistent network sandbox: pages may keep running between one-shot feature invocations, so durable isolation requires a separate browser guardian/proxy or host firewall boundary. |
| `Sources/Features/BrowserTools/Sources/browser-tools-feature` | Thin `browser-tools-feature` executable target that delegates to `BrowserToolsFeatureRunner`. |
| `Sources/Features/DesktopTools` | Standalone macOS-only `desktop-tools-feature` package exposing the single typed tool `desktop.run`: permission/system inspection, app and window enumeration, PNG screenshots attached to the model's multimodal context, pointer/keyboard/clipboard input, and app/window management through AppKit, Accessibility, and Quartz. It must never execute caller-supplied shell or AppleScript code, must not be enabled in a default agent profile, and requires Screen Recording plus Accessibility consent (`action=permissions` first). Actions that can run code or end processes (`open` of anything but a plain http/https URL, launching from an app path, and `terminate_app`) are gated in the host by `DirectToolExecutor`'s destructive-consent gate (`DirectToolExecutor+DesktopGating.swift`, which reuses the `local.exec` authorizer); the feature runs `/usr/bin/open` and `screencapture` from `/` so URL-looking targets cannot resolve to workspace files. `isInstalledOnLinux` is `false` because the platform integration does not exist there. |
| `Sources/LocalToolsSupport` | Reusable local file, search, text, and patch tooling. It also implements the core `search.glob`, `search.grep`, and `search.locate` tools, which run in-process on macOS and Linux and replace the retired `search-tools` optional package (see the `search-tools` migration under Compatibility Contract). |
| `Sources/ZenCODECore/Memory/Engine` | Internal memory implementation area within the `ZenCODECore` target; it is not a separate Foundation-only module or public product. It is an MIT-licensed independent Swift implementation of the memory architecture of `1jehuang/jcode`, attributed in `THIRD_PARTY_NOTICES.md`. It owns the memory graph, typed edges, lexical retrieval through a pluggable `MemoryIndex` protocol (default `BM25MemoryIndex`; its batch `search(queries:…)` requirement has a default implementation that searches query by query, and the BM25 index implements it by tokenizing the corpus once per retrieval through the transient `MemoryLexicalCorpus`), optional semantic retrieval through a pluggable `EmbeddingProvider` (reciprocal-rank fusion only when one is present), a breadth-first cascade with depth decay, the confidence lifecycle, persistence (the graph JSON plus, from graph version 4, a binary vectors file with binary16 components bound to their entries by an FNV-1a fingerprint), and embedding provider protocols. The graph, BM25 path, default selectors, and persistence — including the hand-written binary16 conversion and the fingerprint — remain dependency-free; opt-in OpenAI-compatible transport adapters and ZenCODE diagnostic seams live in the same implementation-private target and are not installed when a store opens. Retrieval is also pluggable end to end through a `MemoryQueryAnalyzer` (default `DirectMemoryQueryAnalyzer`, which uses the prompt verbatim as the query), a `MemorySelector` (default `TopScoreMemorySelector`), a `MemoryExtractor` (default `NoopMemoryExtractor`, which extracts nothing) and a `MemoryContextFormatter` (default `BulletMemoryContextFormatter`); every default is dependency-free and makes no network call. The engine additionally exposes `context(for:)` (a ready-to-inject memory block) and `learn(from:)` (automatic extraction), and ships LLM-backed analyzer/selector/extractor implementations over the `MemoryLanguageModel` / `OpenAICompatibleChatModel` contracts; all of these stay unwired engine internals — opening a product store never installs a network-backed extractor or makes a generation request. ZenCODECore wires automatic recall through its `MemoryTurnCoordinator`: it calls the store's `context(for:scope:)` inline before every turn and is on by default over the dependency-free BM25 path (no second LLM call — the formatted block rides the turn's own outgoing request). Durable entries are read and written explicitly by the main model through the five `memory.*` tools (`memory.read` / `memory.search` / `memory.write` / `memory.update` / `memory.archive`), guided by `MemoryService.toolUsagePromptSection()`. The `MemoryVerifier` protocol is deprecated in favour of `MemorySelector`. This source area is implementation-private within `ZenCODECore`, not a separate SwiftPM target or public library product. |
| `Sources/ZenPackageMetadata` | Internal bundled-feature distribution metadata used for catalog parity; it is not a public product. |
| `Sources/Features/<Feature>` | A self-contained optional SwiftPM package with its own `Package.swift`, `Sources/<product-name>/`, and package-local `Tests/`. It is outside the root graph; keep the entry point thin and place implementation in feature-owned support or library targets. The marker `// zencode:package-path` must immediately precede the root `.package(name: "ZenCODE", path: "../../..")` dependency so installation can rewrite only that path. |
| `Sources/ZenCRON` | The standalone SwiftPM package of the `ZenCRON` executable, the host that cron runs for scheduled prompts (see [ZenCRON Host](#zencron-host)): `Package.swift`, the `ZenCRON` executable target with a single `main.swift`, and the package-local `ZenCRONTests` target. It sits outside the root graph, which declares none of its products or targets, and it is not an optional feature: it has no catalog entry and no manifest, and it is not a composition root. It has no dependencies, and it depends on none of `zen`, `ZenCODECore`, and the other targets, nor do they depend on it. `ZenCODECore` knows it only through its installed path, its name, and its `--zencron-version` output (`Support/Scheduling/ZenCRONInstallation*.swift`); the one thing the two share is the `PATH` search rule of `ZenCronJobCommand.locateZen(onPath:)`, which ZenCRON repeats and which changes together with it. |
| `Sources/ZenApp` | The standalone SwiftPM package of the ZenCODE macOS app (package `ZenApp`, product `ZenCODE`, executable target `ZenCODEApp`, plus one library product per library target, which exists only so that Xcode creates the schemes the SwiftUI previews need; see [ZenCODE for macOS](app.md)): a native SwiftUI app for macOS 26 (Liquid Glass, in the colors of the terminal UI) that replicates the terminal chat. It is a host app of the public Chat API (see [Embedding ZenCODECore in a Host App](embedding.md)) and its own composition root, `ZenAppRuntime`: one `ChatSessionHost` per process over the production runner, and one slot per window. The package has `Package.swift`, the library targets `ZenAppTheme` (the terminal palette as SwiftUI colors), `ZenAppMarkdown` (the Markdown renderer on swift-markdown, with code highlighting, diffs, and tables), `ZenAppSession` (the composition and the window model, without SwiftUI, and `ZenWorktreeClosure`, which closes the worktree of a `--worktree` launch before the app quits), `ZenAppTranscript` (the conversation views), and `ZenAppControls` (composer, status bar, consent sheet, and menus), the `ZenCODEApp` executable target (the app shell, with the Worktree window that asks how to close that worktree), and a package-local `Tests/<Target>Tests` target for each library target, run with `swift test --package-path Sources/ZenApp`. It sits outside the root graph, which declares none of its products or targets, and it is not an optional feature. It consumes only the public products `ZenCODECore` and `ToolCore` of the root package, through the path dependency `path: "../.."`, and swift-markdown, which the root graph already resolves; the root graph and `zen` never depend on it, and root commands do not build it. On macOS only, `zen --ui` builds the package in release mode from the source checkout (the one `zen` was built from, else the installer copy in `<support>/source`) into `<support>/app` (SwiftPM scratch path `app/build`, installed executable and resource bundles in `app/current`, rebuilt when the build stamp of the running `zen` changes) and starts `ZenCODE` as a separate, detached process; `ZenCODECore` knows the app only by its package path, its product name, and its install location (`Support/App`, compiled only on macOS), as it knows ZenCRON, so the root graph still has no build dependency on it. Inside the package, `ZenAppMarkdown`, `ZenAppTranscript`, and `ZenAppControls` depend on `ZenAppTheme`, `ZenAppSession` on no other target of the package, and only `ZenCODEApp` depends on all of them. |
| `Sources/ZenCODECore` | Runtime domains: `Agent`, `Remote`, `Tools`, `Features`, `Context`, `Memory`, `FileChanges`, `Chat`, `Runtime`, `Setup`, `Telegram`, and `Support`; `TUI` and ACP remain source areas within this target. The `Memory` domain is an async facade over the internal `Memory/Engine` implementation: `MemoryGraphLocation`, `MemoryGraphStore`, `MemoryService`, `MemoryLegacyCompatibility` (the deprecated 1.1.x synchronous surface), and the automatic-recall pipeline (`MemoryTurnCoordinator`, `MemoryTurnContext`, `MemoryAutomationSettings`). `MemoryService+Documents.swift` is removed. ZenCODECore exposes its own public DTOs (`MemoryEntry`, `MemoryScope`, `MemoryCategory` under `Models`) that preserve the 1.1.x contract (`id: UUID`, `Hashable`, journal-shaped scope); the internal engine implementation keeps its graph types hidden behind the facade. |
| `Sources/ZenCODECore/Tools/Direct/SubAgents` | Delegated-agent lifecycle and dispatch. `agent.create` requires an explicit configured profile or a `profileRole` that the runtime resolves to one, and normally derives the child tool grant from that profile; model-authored creation arguments and task metadata cannot add, remove, or replace profile tools. An optional `workingDirectory` (an existing directory equal to or inside the coordinator's) sets the directory the child works in; files, shell, git, project memory, and project-agent association follow it. When the resolved child profile is the same as the coordinator profile, the child inherits the coordinator's effective session allowlist so session-local additions and removals are preserved; only child-intrinsic skills, collaboration, and applicable task-reporting tools are added, with the profile's `readOnly` core-tool policy reapplied. Different profiles (including Reviewer, Planner, and Minimal) retain their own grant boundaries. Model bindings are optional: a profile without bindings inherits the main session's selected model and provider when `model` is omitted; profiles with bindings still require an explicitly authorized model reference, except `profileRole` items, whose binding the runtime selects from `complexity`. |
| `Sources/ZenCODECore/Setup` | Interactive configuration for providers, models, agents, feature packages, Telegram, voice, response language, optional memory embeddings, and the build-and-install of ZenCRON (`Integrations/ZenCODESetupRunner+ScheduledPrompts.swift`). Setup is started only by `zen --setup`, which the executable composition root dispatches, even though its implementation and contracts belong to Core; no chat, mode, or channel opens it. |
| `Sources/ZenCODECore/Runtime/Sessions` | Neutral session state and persistence, including the authoritative task DAG, attempt fencing, execution scopes, atomic task-graph checkpoints, startup enumeration/recovery, and the session checkpoint tree (`SessionCheckpointTree`). Workflow-sourced graphs require sub-agent execution attempts, while coordinator tool grants remain independent of that lifecycle constraint. Startup recovery is graph-specific and moves the graph into the session that is running (`SessionTaskOrchestrator.adoptResumableTaskGraph(_:intoSessionID:workingDirectory:)`, in `SessionTaskOrchestrator+Resume.swift`): the orchestrator restores the owning session, which interrupts its persisted active attempts and blocks their tasks, activates exactly the operator-selected graph in the current session, which keeps its id, archives that session's other active graphs, and writes the graph as the current one into the current session's checkpoint first; only then does it remove the graph from the old checkpoint, deleted when nothing resumable remains while its other graphs stay. If that second write fails the graph is still resumed and at worst offered again at the next startup, never lost. The move works before the runtime session exists (the terminal, whose session creation finds the adopted graph, so `currentGraphID` is persisted before backend creation) and after it (Telegram, ACP, the app); a graph that already belongs to the session is resumed in place (`resumeTaskGraph(_:workingDirectory:)`). A negative validation persists `failed`; `tasks.retry` returns the task to `pending`, and retrying a failed attempt always claims a fresh workflow attempt through a new `agent.create(taskID:)` rather than resuming the prior agent. Separately, once a task-bound attempt completes, the agent may optionally remain in a runtime-only, non-persisted `.standby` state for conversational follow-up turns over direct messages that do not mutate the task graph; standby is bounded by a turn budget and an idle timeout, and is released when the graph becomes terminal, when a newer attempt supersedes it, or when the budget/timeout is exhausted. Standby turns are never task attempts, never reopen the completed attempt, and never change `task.activeAttemptID`. `AgentCoreSessionRunner` owns one orchestrator and injects it into every backend; its internal `AgentCoreBackendManager`, `AgentCoreSessionSnapshotStore`, and `AgentCoreAuthorizationRouter` isolate backend generations, session snapshot incarnations, and authorization lifecycle without changing the runner facade. The runner declaration itself keeps only actor state, initializers, local-exec access mode, session creation/options, and skill selection, with domain companions (`+PromptTurn`, `+SessionLifecycle`, `+SharedChat`, `+SnapshotAuthorization`, `+MCP`, `+Tasks`, `+SavedSessions`) implementing prompt-turn execution, session/backend lifecycle, shared-chat turns, snapshot/authorization routing, MCP wiring, task-graph projection, and saved-session persistence for the same actor. Direct task tools are stateless adapters and TUI/ACP code only projects or requests orchestrator-owned snapshot restoration. |
| `Sources/ZenCODECore/Telegram` | Telegram remote-control runtime: Bot API transport, long-polling, pairing, channel state, voice-attachment download, tool-call permission brokering, safe tool-call presentation, and the ordered per-turn progress reporter (responses, reasoning blocks, tool activity, task-graph card, and sub-agent status; `TerminalTelegramTurnActivity` shapes the texts of the reasoning, activity, and status messages). `TerminalTelegramControlService` retains lifecycle and ingress coordination; pairing, wire effects, attachments, and the command registry are separated into dedicated runtime files. It depends only on `Foundation`/`FoundationNetworking`, `ToolCore`, and neutral runtime contracts (`Agent` settings, `Agent` tool-authorization requests, `ToolCallPresentation`, voice input); it must not depend on terminal presentation types. `TelegramChannel` (`Chat/Channels/Telegram`) is the only adapter that binds this runtime to a chat session, as the Telegram channel of a slot of the `ChatSessionHost`; the TUI and ACP hand their slot to it and back through the host (`TUI/Chat/Telegram/TerminalChat+Telegram.swift`, `ACP/Telegram/ZenCODEACPBridge+TelegramCommand.swift`); `zen --telegram` (`Runtime/Launcher/ZenCODETelegramRunner.swift`, with its process handling and log in `Runtime/Launcher/ZenCODETelegramProcess.swift`) opens a `.telegram` slot that it hands to the `TelegramChannel` at startup and never takes back. |
| `Sources/ZenCODECore/ACP` | ACP protocol adaptation only: JSON-RPC routing, parsing, lifecycle, and event encoding. Tool-call updates are wire-normalized here: the richer internal presentation kinds are mapped onto the closed ACP set (`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`), and `locations` are absolute paths resolved against the session workspace rather than the agent process directory. `ACP/Telegram` holds `ACPSessionChannelHooks`, the composition and the environment of the turns the Telegram channel runs on an ACP slot, the collection of the attach notices for the reply to `/telegram on`, and the `/telegram` command itself (`ZenCODEACPBridge+TelegramCommand.swift`). The history replay of `session/load` and `session/resume` (`replaySessionHistory`) renders the log entries rebuilt from the runtime history (`ChatTurnEntry.kinds(fromTranscript:)`). A `session/prompt` turn runs in phases (prepare, route, execute, settle; `Routing/ZenCODEACPBridge+Prompt.swift`), each of its exits that answers a stop reason writes the reply before releasing the reservation, and `session/new` and the restore of a session that is not live share the opening of the new incarnation, the install of its MCP servers, and the cleanup of both on failure (`withNewIncarnation`, `Lifecycle/ZenCODEACPBridge+Lifecycle.swift`). |
| `Sources/ZenCODECore/Chat` | Channel-neutral chat-session layer consumed by `TUI`, ACP, the headless runner and the Telegram runner in `Runtime/Launcher`, and a host app through its public API (see [Embedding ZenCODECore in a Host App](embedding.md)); the headless runner composes its session configuration and prompt skills from a controller and does not instantiate `TerminalChat`. The layer contains no terminal, ACP, or JSONL types, apart from the pure layout helpers that `Chat/Channels/Telegram` still reads from `TUI` (see the note on the Telegram channel in the `Sources/ZenCODECore/TUI` row). `ChatSessionController` (one per session, isolated to the `ChatSessionActor` global actor) runs the turn pipeline: the purpose-specific coordinator tools from the single `ChatTurnPurpose` table, `/plan` finalization and `/goal` continuation, the bounded session transcript, file-change tracking (`TurnFileChangeCoordinator`, `SessionFileArtifactHistory`), and the mapping of runtime events onto a `ChatSessionPresenter`, which a channel may bind to one request (ACP prompts). `ChatSessionStateStore` keeps the transient command state and the turn fence under one lock, so a channel in another isolation domain can check its own fences and update that state in one synchronous step, and `cancelActiveTurn` fences a turn that is still unwinding. The controller also owns the session operations (`ChatSessionController+Sessions.swift`: new, save, save under a name, list, load, delete, compact, restore from a checkpoint, and the DS4 engine checkpoints) and the selections (`+ModelSelection.swift`: initial model and model; `+ThinkingSelection.swift`: thinking level; `+AgentSelection.swift`: agent and the project's agents; `+ToolSelection.swift`: tools; `+SkillSelection.swift`: skills with install and uninstall; `+SessionRecreation.swift`: the runtime session recreated for the selection; `+WorkspaceAccess.swift`: the workspace-folder access request that follows an agent or tool selection; `+Selection.swift` keeps the session state and the steps that apply the selection to the runtime session), and composes the session configuration and system prompt from them (`+Composition.swift`). The startup offer of the task graphs that earlier sessions left incomplete is one shared flow, `ChatSessionController.offerResumableTaskGraphs(choiceHost:)` (`+ResumeTaskGraph.swift`), used by the terminal, Telegram, ACP (with an ACP-specific choice host that asks through `session/request_permission`), and the macOS app: it lists the resumable graphs of the project without those of its own session and of the sessions another slot of the host runs (`ChatSessionHost.liveSessionIDs()`), asks for the resume, the deletion, or a fresh start through the `ChatInteractionHost` menus, moves the chosen graph into the controller's session with `ChatSessionManagementRuntime.adoptResumableTaskGraph(_:intoSessionID:workingDirectory:)` (the session keeps its id), and returns its notices for the channel to present when it is ready (`presentSessionNotices(_:)`). A channel without a multiple-choice menu deletes every listed graph. A channel gives it a `ChatSessionEnvironment`, the immutable launch facts read once from `AgentConfiguration` (hosted models and agent profiles, explicit and launch model, launch agent, tool-round and output limits, app mode, initial skills, feature runtime), so Chat never reads environment variables, the current directory, or the terminal. The operations run on `ChatSessionManagementRuntime`, the wider runtime contract that `AgentCoreSessionRunner` implements (session create, restore, reset, rebuild, and compaction, model preload, prompt-skill selection, DS4 checkpoints, task graphs, tool descriptors) next to the turn-only `ChatSessionRuntime`. A `choose…` operation asks the host for a menu and, without the matching capability, returns the non-interactive output of its command instead; a `select…` operation applies a choice. Results reach the channel as `ChatSessionNotice` values, through `ChatSessionPresenter.presentSessionNotice` as they happen or in the `ChatSelectionOutcome` and `ChatSessionOperationOutcome` that an operation returns, and `ChatSessionNoticeText` is the exact text the terminal writes for each; the selection and the saved-session link (`ChatSessionState`) are mirrored to the channel through `presentSessionStateChanged`. A channel's own steps between the runtime steps of an operation (status bar, panel suggestions, response-language lock) and the response-language section of its prompt go through the weakly held `ChatSessionChannelHooks`, whose steps of a session replacement and of a compaction are one `incarnationDidChange(reason:)` with a `ChatIncarnationChange`. `ChatModelCatalog` (`Chat/Models`) lists, searches, and validates the models, resolves the thinking level and the default model, and saves a choice as the global default unless the channel supplies `hostedModels`; the terminal and ACP share it, while ACP keeps its epochs, fences, reconfiguration with rollback, and prompt composition. `ChatInteractionHost` declares `ChatChannelCapabilities` (tool consent, serial consent dialogs, single choice, multiple choice, focused multiple choice, text input, live file artifacts, external open, attachment picker); its public additions are source-compatible, each with a default: `chooseManyWithFocus(…)` (default `nil`, returning a `ChatFocusedChoice` with the ticked items and the confirmed one), `requestWorkspaceAccess(_:)` (default grants, taking a `ChatWorkspaceAccessRequest`), `openExternal(_:)` (default throws, taking a `ChatOpenTarget`), `pickAttachment(startingAt:)` (default `nil`), and `ChatChoiceItem.group` and `isCurrent`. The terminal host declares menus, text input, external open, and the attachment picker only when stdin or `/dev/tty` is an interactive terminal, and the headless host offers nothing. `ChatToolConsentAuthorizer` is the single consent policy behind `LocalExecPermissionAuthorizer` and `ACPPermissionBroker`, and refuses gated tools with a diagnostic when the host offers no consent. The controller also resolves and runs the shared slash commands (`Chat/Commands`: `ChatCommandRegistry`, `ChatCommandFence`, `ChatPlanningCommandPolicy`; `handleCommandLine(_:context:)`) and owns the task-graph observer and the sub-agent refresh that publish the semantic overviews of `Chat/Contracts/ChatOverviewState.swift`; `Chat/Queue` holds the bounded prompt queue (`ChatPromptQueue`). `Chat/Channels/Telegram` holds the Telegram channel (`TelegramChannel`, its `TelegramChannelPresenter`, and `TelegramChannelRegistry`), which the slot owns and which implements the generic single and multiple choice menus of `ChatInteractionHost` as inline buttons, so the controller's menus show in the linked chat instead of answering with the non-interactive output of their command; the controller presents through the slot's `ChatSlotPresenter` and the observers (`ChatSessionObserver`, through the internal `ChatObservedPresenter` of `Chat/Contracts`). `Chat/Contracts/SharedChatMentionParser.swift` parses and sanitizes live `@mentions` for every channel, and `Chat/Contracts/SharedChatMessageLabel.swift` builds the route label of a live message for every channel that shows one (the terminal reader and the macOS app; the terminal's `sharedChatIncomingCardRoute` forwards to it). `Chat/Runtime` holds `ChatSessionRuntimeFactory`, which builds the session runner (`makeSessionRunner(toolAuthorizationHandler:featureRuntime:mcpRuntime:backendFactory:)`): the backend is chosen in one place of Core, `ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are composition roots that inject it; no other layer of Core chooses a backend. `Chat/Host` holds the session host, the container of the chat sessions of one process (see *The session host* under the Compatibility Contract): `ChatSessionHost`, the slots a channel opens (`ChatSlotDescriptor`, `ChatSlotIdentity`, `ChatSlotInteraction`, `ChatSlotID`), the incarnations they run (`ChatSessionIncarnation`, with their epochs), the prompt reservation (`ChatPromptReservation`, `ChatSessionOperationState`), the shell snapshot of the host (`ChatShellSnapshot`, `ChatShellTelegramState`, `ChatSessionHost+Shell.swift`), the Telegram router and dispatcher shared per host, and the sleep assertion; the task graphs stay with the runner's orchestrator. `Chat/State` holds the observable session state: `ChatSessionStateReducer`, a presenter that builds a `ChatSessionSnapshot` from one ordered log per session, and `ChatPendingRequestHost`, a host that publishes the operator interactions in that snapshot until the client resolves them (see the transient rule above). The public API of the layer follows the semver rule of the Compatibility Contract; `ChatCommandFence`, `ChatPlanningCommandPolicy`, `ChatSessionStateStore`, and `ChatCommandState` are internal. Channels keep their transport, the rendering of the overviews, their own commands (the terminal's `/telegram`, `/voice`, `/ds4`, `/feature`, `/cron`, `/exit`, and `/tools logs`, and ACP's `/telegram`), the handover of their slot to Telegram and back, voice, and the steps only they have (the terminal's status bar). |
| `Sources/ZenCODECore/TUI` | Terminal-only state, input, rendering, and presentation. `TerminalChatRenderCoordinator` is the sole actor owner of stateful chat writes and streaming formatter/cursor state; the coordinator declaration itself keeps only actor state, initializers, and cursor topology, while cohesive implementation units live in same-domain extension files (streaming and write coalescing, transcript messages, tool-block lifecycle and row ownership, overview arbitration, diagnostics/snapshot barriers, and low-level channel output). Its actor-confined overview arbitration, tool-block accounting, and per-channel/pending-write value state live in `TerminalChatRenderState` value types, while stateless text normalization lives in `TerminalChatTextFormatting`, `TerminalMarkdownStreamFormatter` owns incremental Markdown state, and `TerminalWidth` centralizes cached terminal-width probes, on which `TerminalTextMetrics` builds the text and geometry measures (display width, physical rows, terminal columns; `TerminalChat.terminalColumnCount(forceRefresh:)` forwards to it). Several pure helpers have moved out of the extensions of `TerminalChat` into namespace enums: `ToolArgumentReader`, `ToolLanguageHint` (with the public `TerminalChat.codeLanguageHint(forPath:)` as forwarder), `ToolMutationClassifier` and `ToolSnippetRenderer` for the source rows of a tool call (`Chat/Presentation`), `TerminalSubAgentOverviewLayout` for the sub-agent overview (`Chat/Tools`: densities, row budget, elision, physical rows; `TerminalChat` keeps publication, refresh, and the public `renderSubAgentOverview(_:modelTitleResolver:)`), and `TerminalTaskGraphLayout` for the task-graph Markdown (`Chat/Planning`). The Telegram channel still reads four functions of these enums (`TerminalSubAgentOverviewLayout.statusRows`, `partialResponses`, and `markdownResponses`, and `TerminalTaskGraphLayout.markdown`). They produce terminal-styled rows (ANSI, indentation), and `partialResponses` and `markdownResponses` return the coordinator's response types (`TerminalChatRenderCoordinator.SubAgentPartialResponse` and `SubAgentMarkdownResponse`), which is a dependency on those types and not on any styling. The ANSI is stripped downstream: the channel strips the task graph and the response headings with `TerminalANSIText` (`TelegramChannel+Presenter.swift`), and the Telegram runtime strips the status rows (`TerminalTelegramTurnActivity.singleLine`, in `Telegram/Presentation/TerminalTelegramTurnActivity.swift`). They stay in `TUI` until they are split into a neutral model and a terminal rendering. `TerminalStatusBar` separately owns status and input-panel rendering state. `TerminalChat` is one slot of a `ChatSessionHost` (`ChatSlotIdentity.terminal`, `publishesState: false`), opened in its `init` with its first session, and runs the controller of the slot's current incarnation (`chatSession`); it follows the slot through the host's incarnation observer when `/sessions new` or `/sessions load` replace the session, while the slot's Telegram channel follows the new controller by itself and its own per-session steps keep running in the channel hooks; the host is given by `ZenCODECommandLineRunner` or built over the runner the chat receives or creates, and ends the chat's session with `closeSession(in:)`. Shared runtime types must not be introduced here. Telegram runtime lives under `Telegram` and the channel of a slot under `Chat/Channels/Telegram`; in `TUI/Chat/Telegram`, `TerminalChat+Telegram.swift` holds the `/telegram` command, the notice sink, the status line, the dormant admission, the catch-up rendering, and the adoption of a turn still running from Telegram. |
| `Sources/zen` | The executable composition root, command-line dispatch (`--setup` among the options, which runs the interactive setup and exits), the startup configuration gate that stops every mode except ACP when the configuration is missing or invalid, optional-feature installer CLI, and, on macOS only, the `--ui` launcher of the macOS app: `ZenCODEMain` validates the forwarded options with `ZenAppLaunchCommand` (Core, `Support/App`), stops with the not-configured message when ZenCODE is not configured, and lets `ZenAppLaunchCommand.run` build, install, and start the app detached. The backend is chosen in one place of Core, `ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are composition roots that inject it; no other layer of Core chooses a backend. `ZenCODEMain` passes it to `ZenCODECommandLineRunner.main(arguments:backendFactory:)`. `ZenCODEMain` handles `zen --setup` itself, through `ZenCODESetupCommand.run()` (Core, `Setup/ZenCODESetupCommand.swift`), before it reaches the command-line runner; no setup handler exists, and a chat never rebuilds its configuration or its TUI around a setup. |
| `Tests` | Root-package unit targets: `ToolCoreTests`, `FeatureKitTests`, `FeatureMCPBridgeKitTests`, `LocalToolsSupportTests`, and `ZenCODECoreTests`. Memory-engine suites live under `Tests/ZenCODECoreTests/Memory/Engine`; setup suites live under `Tests/ZenCODECoreTests/Setup`. Feature packages, including XcodeTools, own and run their package-local tests separately. |

The former public `ZenCODESetup` module is intentionally folded into
`ZenCODECore`; repository consumers import `ZenCODECore` for setup APIs.

### Responsibility-based subtrees

Internal directories group cohesive responsibilities without adding SwiftPM
modules or changing public names, feature paths, wire formats, or persistence:

```text
Sources/ZenCODECore/
├── ACP/                      # JSON-RPC adapter: routing, lifecycle, permissions, updates
├── Agent/
│   └── Core/
│       ├── Commands/         # Parsing, transient state, plans, and workflow control
│       │   └── Prompts/      # Planning/workflow prompt text, unchanged by relocation
│       └── Coordinator/SessionRunner/  # AgentCoreSessionRunner and its domain companions
├── Features/                 # Optional-feature catalog, management, runtime, and scaffold
│   └── Catalog/ Management/ Runtime/ Scaffold/
├── Models/                   # Public DTOs such as MemoryEntry, plus Thinking/
├── Support/                  # Cross-cutting helpers split by concern
│   └── Compatibility/ Diagnostics/ Prompting/ Process/ Storage/
├── TUI/                      # Terminal-only state, input, rendering, and presentation
│   ├── Chat/Presentation/RenderCoordinator/
│   ├── Input/                # LineReader/, CheckboxMenu/
│   └── Rendering/            # Markdown/, CodeBlocks/, StatusBar/
├── Setup/
│   ├── Profiles/             # Agent instructions, bindings, and tool/skill selection
│   ├── Models/               # Providers, catalogs, model selection, and DS4 setup
│   ├── Interaction/          # Menus, prompts, and response language
│   ├── Integrations/         # Features, memory embeddings, Telegram, and voice mode setup
│   └── Maintenance/          # Data management and configuration reset
└── Telegram/
    ├── Transport/            # Bot API, multipart encoding, and rate governance
    ├── Routing/              # Dispatcher, mailbox, leases, routes, and update offsets
    ├── Control/              # Control service, commands, and permission requests
    ├── Attachments/          # Inbound files, artifact policy, and consent
    ├── Pairing/              # Pairing service and grants
    └── Presentation/         # Rich messages, streaming, shared chat, and progress

Tests/ZenCODECoreTests/
├── Tools/SubAgents/           # Thematic runtime tests and domain-specific fixtures
└── TUI/RenderCoordinator/     # Tools, overlays, overview, streaming, and resize tests
```

Other top-level areas under `Sources/ZenCODECore/` (not expanded above) are
`Context`, `FileChanges`, `Local`, `Memory`, `Presentation`, `Remote`, `Runtime`,
`Skills`, `Tools`, and `Voice`.

`Setup` retains its runner, requirement, and shared setup types at the root.
Command files extend the existing `PlanningCommandKernel`; they do not create a
second coordinator or task-graph owner. The two test entry files retain their
suite declarations and traits, with scenario methods in thematic extensions.
Shared test helpers remove repeated setup and output projections while preserving
suite/test names, assertions, per-test state, and lifecycle boundaries.

## Dependency Direction

Arrows point from a dependency to its consumer. The actual direction is from
reusable leaf/support modules toward the runtime and executable composition
root:

```text
ToolCore ──→ FeatureKit ──→ LocalToolsSupport
    └────────────────────→ FeatureMCPBridgeKit
FeatureKit ──────────────→ FeatureMCPBridgeKit

ZenPackageMetadata ─────→ ZenCODECore

ZenCODECore / ZenPackageMetadata ───────────────────────────────→ zen

ZenCODE root products ──→ Sources/Features/<Feature>/Package.swift
                              ├───────────────────────────────→ package-local implementation
                              └───────────────────────────────→ feature executable
```

`FeatureMCPBridgeKit` depends on `FeatureKit` and `ToolCore`;
`BrowserToolsFeature` depends on `FeatureKit` and is composed only by its thin
package-local `browser-tools-feature` executable; the package-local
`XcodeToolsFeature` implementation depends on the generic MCP support products
and is composed only by its package-local `xcode-tools-feature` executable;
`LocalToolsSupport` depends on `FeatureKit`; `ZenCODECore` contains the internal
`Memory/Engine` source area and consumes all generic support targets plus
`ZenPackageMetadata`, including the interactive setup implementation.
`TUI` and ACP may consume neutral runtime
contracts, but Agent, Remote, and ACP code must not depend on terminal
presentation types. `Chat` depends only on the Agent, Tools,
FileChanges, Features, Memory, Skills, Support, Presentation, and Runtime
domains, and its Telegram channel (`Chat/Channels/Telegram`) on the
`Telegram` runtime; it never depends on `TUI` or ACP. `TUI`, ACP, and
`Runtime/Launcher` depend on `Chat`, never the reverse, and the TUI and ACP
drive Telegram through the host: they hand their slot to its Telegram channel
and back, and neither runs the link itself. The host (`Chat/Host`) depends on
the controller, the reducer, the Telegram channel and its runtime objects, and
the runner, never on a channel of its own;
`TUI`, ACP, and `Runtime/Launcher` open their slots in it. Remote providers receive backend factories through runtime
contracts rather than constructing Agent coordinators directly. The backend
is chosen in one place of Core,
`ChatSessionRuntimeFactory.productionBackendFactory`; `zen` and a host app are
composition roots that inject it; no other layer of Core chooses a backend.
`Sources/ZenCRON` is outside this graph: it depends on none of these modules
and none of them depends on it.

## Memory Ownership and Persistence

Durable memory storage, retrieval, embedding, recall, and the persisted graph
format are part of this contract and are specified in
[memory.md](memory.md). `ZenCODECore` owns the `ZenMemory` engine and its public
`Memory` facade; the per-workspace graph files under the support directory are the
authoritative stores, and a global graph at `memory/global/memory.graph.json` in
the same directory is an additional persisted store with the same format. Their
format changes only through an explicit migration.

**Announced migration: memory graph version 4.** A graph is now two files:
`memory.graph.json`, whose entries no longer carry `embedding`, and the binary
`memory.graph.json.vectors` next to it. Versions 1–3 still load and are
rewritten as version 4 only by the first save; earlier builds reject a
version 4 graph with `unsupportedGraphVersion(4)` and leave both files
untouched, and there is no export back to version 3. The cleanup backup is the
pair `memory.graph.json.bak` and `memory.graph.json.vectors.bak`. The layout,
the fingerprint and the coherence guarantees are specified in
[memory.md](memory.md).

## Telegram Single-Owner Routing and Persistence

Telegram routing is an authorization boundary, not presentation state. Schema 2
persists one global private-chat identity in `settings.json`; routes describe only
the owner's sessions (terminal and ACP) and their optional private topics:

```json
{
  "telegram": {
    "enabled": true,
    "botToken": "…",
    "linkedChatID": 42,
    "linkedChatTitle": "…",
    "ownerUserID": 7,
    "routingVersion": 2,
    "routes": [{
      "topicID": 12,
      "roomID": "room-id",
      "lifecycle": "active",
      "generation": 1
    }]
  }
}
```

`TerminalTelegramSessionRouter` accepts ingress only when both the private chat
and sender match `(linkedChatID, ownerUserID)`. It serializes route create,
close, delete, resolution and validation; each mutation persists its normalized
draft before publishing it in memory. A lease retains the complete
`(chatID,userID,topicID?,roomID)` key and route generation, so suspended work
cannot cross an owner, session, lifecycle or generation change. A closed exact
topic stays closed. A missing or deleted topic may use the unique active
`topicID: null` fallback. Groups, supergroups, member lists and per-route ACLs
are unsupported and fail closed.

There is no schema-1 compatibility or runtime owner claim. Any non-schema-2,
ownerless or incoherent configuration is inactive and must be paired again.

`TerminalTelegramRouteRuntimeState` partitions prompt queue, attempted-delivery
ledger, draft ownership and reply receipts by the complete route key. Reply
targets must name the same room. Text prompt origins retain that key through the
TUI queue, and Bot API persistent sends carry the matching
`message_thread_id`. Stop-generation updates contain no reliable user identity:
they can only request cancellation of a locally owned `(route,draftID)` and are
never authorization evidence. Native drafts are optional private-chat UX.
Teardown removes one route bucket, while generation validation prevents late
work from recreating it. No Mini App or web deployment is part of this
architecture.

Topic mode uses the private-chat topics of Bot API 9.3 (`message_thread_id` in
a private chat, and `has_topics_enabled`, which `getMe` reports) and 9.4
(`createForumTopic` in a private chat), and requires Threaded mode, enabled for
the bot in @BotFather. In topic mode each attached session has a topic of its
own, whose route carries its `topicID` and `roomID == sessionID`; otherwise the
link is in legacy mode, on the `default` route without a topic that every
attached session shares. One rule decides which sessions a route serves
(`TerminalTelegramRouteKey.admits(roomID:)`): a route bound to a session's room
serves that session, and the `default` route serves every session; the
ingress of a message, the topic-less route the channel resolves for its link
at attach, and the binding of the shared-chat relay all apply it, and a route
bound to another session's room serves none of them. On attach a channel reuses an active route of its
session (`activeRoute(forRoomID:)`); otherwise, when the bot has Threaded mode,
it creates a topic, and General is told once, only when the topic is created;
otherwise, and also when the creation fails, it falls back to legacy mode.
A new or loaded session in a slot Telegram drives, which only a host app can
start (the terminal and ACP refuse `/sessions` meanwhile), rebinds the same
topic to the session it switches to (`rebind(_:toRoomID:)`: the generation
advances by one, so the previous lease no longer validates) and renames it with
`editForumTopic`.
Detach and shutdown close the topic's route in the router and prune the
inactive routes down to 32 (`prune(keepingInactive:)`, which never removes the
route without a topic or an active route), without `deleteForumTopic`. As a
consequence, after `/telegram off` and `/telegram on`, or at a new launch, a
session receives a new topic, and the old one stays in Telegram.

In topic mode a message in General, or in a topic no route knows (which falls
back to the route without a topic), is handled by every attached session,
which answers in the topic the message came from without moving its own link
there; a message in the topic of a session reaches that session only. The
permission replies without a request ID on such a shared route follow the rule
recorded under [Compatibility Contract](#compatibility-contract). Drafts carry
the route's `message_thread_id`, as persistent sends do. The persisted format
is unchanged: schema 2, `routingVersion` 2, and no new key.

## Consumer Migration Note

The interactive setup now starts only with `zen --setup`. The terminal command
`/setup` was intentionally removed and answers as an unknown command.
Every mode except ACP stops, with exit status 1 and the message ``ZenCODE is not
configured. Run `zen --setup` to configure it, then start zen again.``, when the
required configuration is missing or invalid, instead of opening setup. In the
ACP wire contract, the `zencode-setup` terminal authentication method (name
**Set up ZenCODE**) now publishes `args: ["--setup"]` instead of `[]`, and the
`auth_required` (-32000) message names `zen --setup`; the method id, name, and
type are unchanged.

The remaining root library products and imports, `zen`, and generated
Builder-feature wire and persistence contracts remain compatible. The former
`ZenCODESetup` product was intentionally folded into `ZenCODECore`; consumers
that imported it must depend on and import `ZenCODECore` instead. The former
root `XcodeToolsFeature` product was also intentionally removed: consumers must use
the standalone optional package rather than importing its implementation.
The former optional `search-tools` package was folded into the core as well:
its tools are now core tools implemented in `LocalToolsSupport`, and
`zen --install-features search-tools` is refused (see the `search-tools`
migration under Compatibility Contract).
Optional feature executables
are no longer installed beside the `zen` binary or built by the root package.
Install the desired package with `zen --install-features [id,id,...]` (or select
it in setup) before selecting its tools. Installed catalog packages use the
same `~/.zencode/features/<id>/` layout and feature manifest behavior as a
Builder-created local feature. `ZenPackageMetadata` remains an internal
implementation detail.

The terminal-rendering concurrency migration is an intentional source-level
exception: `TerminalChat` operations that may render or update terminal UI are
async and callers must await them. Observable CLI output remains compatible;
the actor boundary prevents independent tasks from mutating formatter, cursor,
overlay, or status-bar state concurrently.

The public APIs of `ToolCore`, `FeatureMCPBridgeKit`, and `ZenCODECore` that had
no callers were intentionally removed, as an announced source-level exception
to Migration Rule 7 below. Several were compatibility wrappers, such as
`JSONValue.encoded()` and `MCPTransportCodec.nextMessageBody(from:)`. The
`### Removed` entries under `## [Unreleased]` in
[CHANGELOG.md](../CHANGELOG.md) list each removed symbol and its replacement.
The output of `zen`, the ACP wire, the `--list-tools` and `--invoke` JSON, and
the persisted formats remain compatible. The feature scaffolds that the Builder
generates use none of the removed symbols: they already use
`FeatureProcessProtocol` and `FeatureListToolsResponse`. A feature generated in
the past that used any of the removed symbols must migrate to the replacements
listed there.

## Migration Rules

1. Add characterisation tests before moving a path that participates in JSON,
   persistence, feature adoption, or build discovery.
2. Make test imports direct in `Package.swift`; do not rely on transitive test
   dependencies.
3. Replace `#filePath` parent-count assumptions with a package-root resolver
   before moving source or test files.
4. Keep mechanical moves separate from behavioral fixes. A moved file should
   preserve public symbols and observable output.
5. Update source paths, package excludes, feature registry entries, scripts,
   and their parity tests in the same change.
6. Preserve existing test suite names during the first relocation so filters
   continue to work.
7. Retire aliases, facades, and legacy paths only in a later compatibility
   release after consumer and persisted-state migration coverage exists.

## Validation Gates

Every structural checkpoint must at least build the affected target and run its
focused tests. Before a release, resolve only from the tracked
`Package.resolved`, validate the root package graph, build `ZenCODECore`, run
the complete non-live root test suite with `swift test --no-parallel`, and build
the release `zen` product. An
optional feature change additionally runs `swift test` from its own
`Sources/Features/<Feature>` package (with an isolated scratch directory) and
checks its `--list-tools` output after installation. A ZenCRON change
additionally runs `swift test --package-path Sources/ZenCRON`, which the CI job
`zencron-package` also runs. Validate shell syntax with
`bash -n Scripts/*.sh`, and finish with `git diff --check`.

The version/release contract is documented in [release.md](release.md): a
`vX.Y.Z` tag must equal `ZenPackageMetadata.version`, and release installers
receive the same immutable tag or full commit SHA through `--ref`. The tracked
GitHub Actions workflow mirrors the ordinary macOS/Linux non-live gate; network
and installer execution remain dedicated validation tasks rather than routine
checks for a layout-only change.

## Subscription catalog persistence

Authenticated setup-only subscription discovery is described in
[subscription-catalogs.md](subscription-catalogs.md). Catalog schema 1 is a separate
private account/login-scoped cache and never owns runtime selection. Credentials
add an optional Anthropic `catalogScopeID` UUID for OAuth login lineage; legacy
credentials remain decodable. Generation overrides add optional
`subscriptionThinkingMode` metadata (`adaptive`, `enabled`, `disabled`), leaving
legacy manifests unchanged. These additive fields must survive settings round
trips; cache contents contain no tokens or token hashes. Only setup may select
new discovered models, and existing saved manifests are not silently replaced.

## ACP standard presentation and operation evidence

ACP projects the current `SessionTaskOrchestrator` snapshot as a complete standard
`plan`, using its event stream as invalidation (including delegated mutations),
not as a second DAG owner. `normal` priority becomes `medium`; blocked, failed and
cancelled entries retain their real state in the label rather than being shown as
successful completion. Attempt work is a separate standard tool row from the real
`agent.create` call. Runtime snapshot streams provide the corresponding taskless
presentation without polling. These streams and their projections are ephemeral;
prompt teardown cancels/drains observers. Admission fences reject late producers;
accepted buffered output still drains during close, unless a replacement prompt or
session owns the wire identity. Persistent taskless agents are re-observed at the
next prompt start, even without root tools. Runtime execution revisions identify
actual turns independently of historical output revisions; terminal rows are not
reopened. These revisions and projections are not persisted. Validation remains
a task state, not an inference from standby.

`OperationFileChangeRecorder` is a neutral, task-local, non-Codable ToolCore
contract. LocalToolsSupport captures bytes at the local mutation's commit boundary
and carries them through the offloaded I/O closure into the non-Codable
`DirectAgentToolResult`; no provider wire or saved-session DTO changes. Text write,
edit, replace, multi-edit, append, patch, delete and move use a shared synchronous
mutation critical section. Patch evidence is published only after all commits
succeed, never from parsed hunk text or after a successful rollback. Move evidence
is a source deletion plus destination write. Missing old files use null old text;
binary/unreadable content and directories have explanatory text instead of a
fabricated diff. Text summaries accompany actual operation evidence; ordinary tool
results retain their prior output-only content and `_meta`. ACP tool-call completions
also mirror every recorded changed path in standard `locations`, allowing clients to
expose each file artifact from a multi-file operation.

Capture runs only with an installed operation recorder and verifies regular-file
identity on the opened descriptor. Each text is limited to 64 KiB; snapshot reads
reserve a cumulative 256 KiB budget before reading, and emitted old/new texts share
a separate 256 KiB operation budget. Oversize, binary, special-file, or uncertain
evidence produces explanatory fallback, never a truncated diff.

Opaque foreground operations conservatively invalidate overlapping local evidence.
A launched `local.exec` background operation invalidates certainty for the rest of
that process: the return of its tool call is not proof that its writers stopped.
External processes not launched through this executor cannot be synchronized by
this in-process mechanism. Shell/Git/MCP effects themselves have text fallback,
not inferred per-operation patches. See `Docs/xcode.md` for host-rendering limits.

### Client-managed text files

When `initialize.clientCapabilities.fs` advertises boolean `readTextFile` and/or
`writeTextFile`, ACP injects a transient `ClientTextFileSystem` from ToolCore into
the prompt task. Child tasks inherit the root session's access and epoch fence;
no ACP types enter the neutral runtime and no new model, feature-process or
persisted DTO is introduced. DirectToolExecutor still enforces the existing tool
grants. Read capability routes `local.readFile` and `local.readFiles`; write
capability routes `local.writeFile`; both are required to route `local.editFile`,
`local.multiEdit` and `local.replace`. Their model-visible descriptions identify
them as client-editor tools. Unsupported operations retain the existing local
implementation; an RPC error never retries the same operation on disk. Directory
creation for client writes is delegated to the client. Other operations, including
append, applyPatch, move and delete, are not filesystem ACP operations.

ACP serializes its own client writes per absolute path, rereads a known preimage
before writing, and verifies the acknowledged text by rereading it. These are
client-observed comparisons, not the local commit-boundary evidence described
above: ACP v1 has no compare-and-swap or revision token, so external editor
changes cannot be excluded atomically. A read failure never implies file absence.
Only complete known preimages and matching postimages can become standard diff
content, subject to the existing 64 KiB/text and 256 KiB/emitted-operation budgets,
binary checks and opaque-operation uncertainty. A successful write with unknown
or unverifiable content stays successful with explanatory fallback. Timeouts,
cancellation and expired sessions never enable local fallback; a sent write may
already have taken effect. Transport shutdown releases outstanding requests.

## Terminal primary-screen ownership

During interactive chat, `TerminalPrimaryScreen` owns only the reserved tail
(prompt/status plus a dedicated modal area), not a replayable transcript.
`TerminalOutputSynchronization` serializes native transcript appends, owned-tail
receipts and surface commits. A receipt is returned inside its write transaction;
subsequent diagnostics or physical resize generations invalidate removal rights.

The real cursor is parked at column one of the chrome start between writes.
After physical reflow, only a successful CPR can authorize `J0` from that anchor.
`TerminalRawInput` remains the sole input reader; `TerminalCursorReport` separates
protocol replies from keys/paste and defers ordinary input during the handshake.
A query is refused if an input prefix is already buffered, without discarding or
splitting a possible paste delimiter. A reply is awaited for 2.5 s. A query
superseded by another physical resize does not trigger the fallback: geometry
commits are still recorded but write nothing, its reply is read and discarded,
and then exactly one new query is issued for the committed geometry, at once if
that geometry is already committed, otherwise at the next commit. At most one
query is outstanding, and a new one never precedes the read of the previous
reply. Timeout/cancellation quarantines only the already-started report prefix
for a bounded 750 ms grace period; new Escape keys retain ordinary polling
semantics. Callbacks never execute under the mux lock. No output transaction
waits for an input read, and input callbacks acquire output only after leaving
the raw-byte lock. Snapshot/output queues are transient and never persisted. A
failed/ambiguous handshake (timeout, rejection, cancellation, an invalid
position or a refused query), superseded or not, cancels modal results,
preserves the editor draft and latches append-only presentation without a fixed
footer. The fallback resets origin mode/margins and uses an emulator-clamped
bottom CUP plus CRLF, not cached geometry, so a taller physical terminal cannot
expose transcript to stale-coordinate writes. Stop and session preparation
drain queued output once, in order, without erasure when resize invalidates
ownership, including the debounce interval before a query exists.

Standalone menus retain their pre-existing alternate-screen lifecycle. The
isolated Swift test harness and independent validation requirements are described
in [terminal-cpr-validation.md](terminal-cpr-validation.md); a synthetic VT model
is not evidence that a real terminal's native history/reflow behavior has passed.
