# Embedding ZenCODECore in a Host App

This guide is for an app that drives ZenCODE chat sessions through the
`ZenCODECore` library, for example the macOS app, which lives in a separate
repository and depends on a release tag. The app is one more channel of the
shared chat session, next to the terminal, ACP, and the headless runner (see
the shared chat session controller under
[Compatibility Contract](architecture.md#compatibility-contract)).

Every symbol used here is public. The examples use the same composition path
as `Tests/ZenCODECoreTests/Chat/ChatPublicAPITests.swift`, which compiles it
without `@testable`.

## Dependency

The Chat API is public from version 3.3.0. Release tags follow the `vX.Y.Z`
contract of [release.md](release.md).

```swift
// Package.swift of the app
.package(url: "https://github.com/gerardogrisolini/ZenCODE.git", from: "3.3.0"),
// in the target
.product(name: "ZenCODECore", package: "ZenCODE"),
```

The package uses Swift tools 6.4 and requires macOS 26.

## Composition

Compose a session in this order.

1. Set the support directory with
   `AppStorageDirectory.configureSupportDirectoryURL(_:)` before anything
   reads the settings. Without it the core uses `~/.zencode` in the real home
   folder instead of the sandbox container. Tests use the task-scoped
   `AppStorageDirectory.withSupportDirectoryURL(_:operation:)` instead.
2. Build an `AgentConfiguration`. A hosted configuration,
   `AgentConfiguration(hostedModelID:availableAgents:availableModels:workingDirectory:appMode:)`,
   carries the app's models and agent profiles as `hostedModels` and
   `hostedAgentProfiles`. A configuration from arguments,
   `AgentConfiguration(arguments:appModeOverride:)`, reads the models and
   agents that setup saved in the support directory.
3. Build the `ChatSessionEnvironment` from the configuration.
4. Build the `ChatSessionHost`, the container of the chat sessions of the
   process, over the session runner
   (`ChatSessionHost(runner:environment:sleepAssertionReason:)`, with the
   runner from `ChatSessionRuntimeFactory.makeSessionRunner(...)`, the
   low-level construction point of the runtime), or let it build the runner
   (`ChatSessionHost(configuration:toolAuthorizationHandler:...)`). One host
   per process: it owns the runner, the Telegram router and poller the
   Telegram channel of every slot shares (two hosts on one bot would run two
   long polls, which Telegram refuses with HTTP 409), the sleep assertion, and
   the epochs of every session.
5. Open a *slot* for each place the app runs sessions in (a window) with a
   `ChatSlotDescriptor`: the host, the consent authorizer, the presenter, the
   hooks, and the commands of the window, which the slot keeps across its
   sessions. Then start its session with `newSession(in:sessionID:)`, which
   returns the *incarnation*: the session id, the controller, and its epoch.

```swift
import Foundation
import ZenCODECore

@ChatSessionActor
func makeSession(
    supportDirectoryURL: URL,
    workspaceURL: URL,
    modelID: String,
    models: [AgentSettingsModelManifest]
) async throws -> AppSession {
    AppStorageDirectory.configureSupportDirectoryURL(supportDirectoryURL)

    let configuration = try AgentConfiguration(
        hostedModelID: modelID,
        availableAgents: AgentProfileStore.defaultProfiles(),
        availableModels: models,
        workingDirectory: workspaceURL,
        appMode: true
    )
    let environment = ChatSessionEnvironment(
        configuration: configuration,
        featureRuntime: nil,
        userHomeDirectoryURL: nil
    )

    let presenter = AppPresenter()
    let host = AppInteractionHost()
    let authorizer = ChatToolConsentAuthorizer(host: host)
    let runner = ChatSessionRuntimeFactory.makeSessionRunner(
        toolAuthorizationHandler: { await authorizer.authorize($0) }
    )
    let sessionHost = ChatSessionHost(
        runner: runner,
        environment: environment,
        sleepAssertionReason: "My app chat session active"
    )
    let hooks = AppChannelHooks()
    let slotID = try sessionHost.openSlot(ChatSlotDescriptor(
        identity: .window("main"),
        workingDirectory: workspaceURL,
        presenter: presenter,
        interaction: .host(host),
        authorizer: authorizer,
        channelHooks: hooks,
        publishesState: false
    ))
    let incarnation = try await sessionHost.newSession(
        in: slotID,
        sessionID: UUID().uuidString.lowercased()
    )

    let session = AppSession(
        sessionHost: sessionHost,
        incarnation: incarnation,
        presenter: presenter,
        hooks: hooks
    )
    try await session.start()
    return session
}
```

`makeSessionRunner` uses `ChatSessionRuntimeFactory.productionBackendFactory`
unless the app passes another `backendFactory`. That property is the one place
of Core that chooses a backend; the app, like `zen`, is a composition root
that injects it. A `ChatSessionController` can still be built by hand with
`ChatSessionController(sessionID:managementRuntime:environment:workingDirectory:presenter:host:authorizer:)`
over the same runner, as the headless runner does: such a controller runs on
its own, outside any slot, and switches session in place.

The host runs one incarnation per slot. `/sessions new`, a saved session
loaded or restored from a checkpoint, `newSession(in:sessionID:)`, and
`loadSavedSession(in:name:checkpointEntryID:)` replace it: the previous
controller is fenced, its pending requests refused, and a new controller
starts from the launch profile (a loaded session restores the selection saved
with it), with the slot's presenter, host, hooks, and commands; selection,
plan, workflow, and transcript never carry over. Follow the slot with
`incarnations(in:)`, which yields the current incarnation at once and then
each new one, or read it with `incarnation(in:)`. `closeSession(in:)` ends a
slot's session, `closeSlot(_:)` ends the slot, and `shutdown()` ends every
slot and the runner.

## Isolation

`ChatSessionHost` and `ChatSessionController` are isolated to the
`ChatSessionActor` global actor. Their initializers are `nonisolated`, so the
app creates them from any context. From the main actor or a nonisolated
context, every other call to the host or the controller takes `await`. The
`TelegramChannel` and the protocol `ChatSessionChannelHooks` are isolated to
`ChatSessionActor` too. Open the slots inside a `@ChatSessionActor` context.

`ChatSessionPresenter` and `ChatInteractionHost` are `Sendable` protocols with
`async` requirements, so their implementations can live on the main actor.

Every session and every observer of the app share the single
`ChatSessionActor` executor, and the controller awaits each observer
(`ChatSessionObserver`, see [Observing a Session](#observing-a-session))
before the presenter of the channel that drives the slot. A presenter that
blocks therefore delays every session: return quickly from each call, for
example by enqueuing the output and rendering it elsewhere.

### Presenter

The controller calls the presenter in event order and awaits each call.
Every requirement has a no-op default: implement only what the app renders.

```swift
@MainActor
final class AppPresenter: ChatSessionPresenter {
    private(set) var assistantContent: [String] = []
    private(set) var notices: [String] = []

    func presentAssistantContent(_ content: String) async {
        assistantContent.append(content)
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        notices.append(ChatSessionNoticeText.text(for: notice))
    }
}
```

`ChatSessionNoticeText.text(for:)` is the text the terminal writes for a
notice. An app that renders notices its own way switches over
`ChatSessionNotice` with a `default` case.

### Host

The host declares what it can do in `capabilities`. `requestToolConsent(_:)`
is the only requirement without a default. The controller asks for a menu,
a text line, an external open, or an attachment only when the matching
capability is declared (`.singleChoice`, `.multipleChoice`,
`.focusedMultipleChoice`, `.textInput`, `.externalOpen`,
`.attachmentPicker`); otherwise a `choose…` operation returns the
non-interactive output of its command. A `nil` answer is a refusal.

```swift
@MainActor
final class AppInteractionHost: ChatInteractionHost {
    nonisolated let capabilities: ChatChannelCapabilities = []

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        nil
    }
}
```

### Channel hooks

`ChatSessionChannelHooks` are the app's own steps between the steps of an
operation. Every requirement has a default. The slot and the controllers hold
the hooks weakly, so the app keeps them.

The steps of a session that changes are one hook,
`incarnationDidChange(reason:)`, whose `ChatIncarnationChange` names the step
and carries what it hands the channel: `.newSessionWillStart` and
`.newSessionDidStart` around `/sessions new`; `.savedSessionWillLoad`,
`.savedSessionWillRestore`, and
`.savedSessionDidRestore(transcript:contextWindow:)` of the load of a saved
session, the last one where a channel replays the restored conversation; and
`.sessionDidCompact(contextWindow:)` after `/sessions compact`. The first step
of `/sessions new` and of a load runs on the controller being replaced, the
later ones on the new controller. The other hooks are the steps of a selection
that creates the session again (`agentDidChange(_:)`,
`sessionWillCreate(reason:)`, `sessionDidCreate(reason:)`,
`modelPreloadDidEmit(_:)`, and `modelDidPreload(_:reason:)`, with a
`ChatSessionRecreationReason`) and of a selection command
(`selectionDidApply(_:command:)`, with a `ChatSelectionCommand`), the values
the channel knows (`responseLanguageSection()` and `commandContextWindow()`),
the lock of the response language before the turn of an approved plan
(`responseLanguageShouldLock()`), and the composition and environment of a turn
the slot's Telegram channel runs (`turnSessionConfiguration(for:controller:)`
and `runTurnFromAnotherChannel(controller:_:)`, see
[Telegram Channel](#telegram-channel)).

```swift
@ChatSessionActor
final class AppChannelHooks: ChatSessionChannelHooks {
    weak var session: AppSession?

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        switch reason {
        case .newSessionDidStart, .savedSessionDidRestore:
            await session?.sessionDidChange()
        default:
            break
        }
    }
}
```

`responseLanguageSection()` is the response-language section of the system
prompt that a selection operation composes; the app returns the same value it
passes as `responseLanguageSection` to a turn. The id of the session
`/sessions new` starts is the slot's: its `ChatSlotDescriptor.sessionIDPrefix`
(`ChatSlotDescriptor.defaultSessionIDPrefix`, `chat`, unless the app names
another), a dash, and a new lowercased UUID.

### Session

The session object of the app owns the hooks and follows its slot in the
host: `controller` is the controller of the slot's current incarnation. It is
isolated to `ChatSessionActor`, so it reaches the host and the controller
without hopping. The slot's Telegram channel belongs to the host (see
[Telegram Channel](#telegram-channel)); the app never owns it.

```swift
@ChatSessionActor
final class AppSession {
    let sessionHost: ChatSessionHost
    let slotID: ChatSlotID
    /// The controller of the slot's current incarnation: a new one after
    /// `/sessions new` or a loaded session.
    private(set) var controller: ChatSessionController
    private(set) var epoch: UInt64
    private let presenter: AppPresenter
    private let hooks: AppChannelHooks
    private var incarnationObservation: Task<Void, Never>?

    init(
        sessionHost: ChatSessionHost,
        incarnation: ChatSessionIncarnation,
        presenter: AppPresenter,
        hooks: AppChannelHooks
    ) {
        self.sessionHost = sessionHost
        slotID = incarnation.slotID
        controller = incarnation.controller
        epoch = incarnation.epoch
        self.presenter = presenter
        self.hooks = hooks
        hooks.session = self
    }

    /// Once, before the first turn: the launch agent's tools and skills,
    /// the task-graph observer, then the slot's next incarnations.
    func start() async throws {
        await controller.applyInitialAgentSelectionIfNeeded()
        try controller.applyInitialSkillSelectionIfNeeded()
        await controller.startTaskGraphObserver()
        let incarnations = sessionHost.incarnations(in: slotID)
        incarnationObservation = Task { [weak self] in
            for await incarnation in incarnations {
                guard let incarnation, let self, incarnation.epoch != self.epoch else { continue }
                self.controller = incarnation.controller
                self.epoch = incarnation.epoch
            }
        }
    }

    /// After a new or loaded session: observe its task graph, and move the
    /// Telegram topic to it (nothing happens without a topic).
    func sessionDidChange() async {
        await controller.startTaskGraphObserver()
        await sessionHost.telegramChannel(in: slotID)?.rebind(
            sessionID: controller.sessionID,
            displayName: controller.savedSessionState.savedSessionName ?? controller.sessionID
        )
    }

    /// Closing the slot shuts its Telegram channel down with it.
    func close() async {
        incarnationObservation?.cancel()
        await controller.stopTaskGraphObserver()
        await sessionHost.closeSlot(slotID)
    }
}
```

`applyInitialAgentSelectionIfNeeded()` applies the launch agent's profile, so
call it once per incarnation: a second call resets the tool and skill
selection to the profile. `.newSessionDidStart` and `.savedSessionDidRestore`
reach the hooks on the new controller, after the host replaced the
incarnation, so `controller` is already the new one there. When the last
window closes, `sessionHost.shutdown()` ends every slot and the runner.

## Running a Line

A line goes through the controller in this order:

1. `admitLine(_:in:)` on the host, which tells whether the app may run the
   line now: while Telegram drives the slot the app is dormant and runs only
   `/telegram`, `/telegram off`, and `/exit`
   (`ChatSlotAdmission.admitted`); every other line gets
   `.refused(ChatSlotAdmission.dormantRefusalText)`, which the app shows
   instead of running it;
2. `handleCommandLine(_:context:)` for a slash command;
3. `pendingReplyAction(for:)` for any other line, so a reply the session is
   waiting for (the goal of `/plan approve`, a Planner question, a `/goal`
   workflow) is not sent as a new prompt; `nil` means the line is a prompt;
4. `reservePrompt(in:)` on the host, which reserves the right to run one
   prompt on the slot's current incarnation in the same step as it checks
   that none runs (`ChatSessionHostError.sessionBusy` otherwise);
5. `turnSessionConfiguration(for:responseLanguageSection:)`, the
   configuration of one turn with its purpose, composed as the terminal
   composes it;
6. `runTurn(_:)` with a `ChatTurnRequest`, then `releasePrompt(_:)`.

```swift
extension AppSession {
    func submit(_ line: String) async throws {
        var prompt = line
        var purpose = ChatTurnPurpose.normal
        var typedByOperator = true

        if case let .refused(text) = sessionHost.admitLine(line, in: slotID) {
            presenter.show(text)
            return
        }
        let outcome: ChatCommandOutcome?
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
            outcome = await controller.handleCommandLine(line, context: [])
        } else {
            outcome = await controller.pendingReplyAction(for: line)
        }
        if let outcome {
            for notice in outcome.notices {
                await presenter.presentSessionNotice(notice)
            }
            switch outcome.action {
            case let .startTurn(commandPrompt, commandPurpose, locksResponseLanguage):
                prompt = commandPrompt
                purpose = commandPurpose
                typedByOperator = locksResponseLanguage
            default:
                // `.none`: the command is complete. `.channelCommand`: a
                // command the app runs itself, or one it does not offer.
                return
            }
        }

        // One prompt per incarnation; the reservation names the epoch it
        // runs under and is dropped with a cancel or a new session.
        let reservation = try sessionHost.reservePrompt(in: slotID)
        defer { sessionHost.releasePrompt(reservation) }
        let configuration = await controller.turnSessionConfiguration(
            for: purpose,
            responseLanguageSection: nil
        )
        let result = try await controller.runTurn(ChatTurnRequest(
            prompt: prompt,
            attachments: typedByOperator ? controller.consumePendingAttachments() : [],
            purpose: purpose,
            sessionConfiguration: configuration,
            origin: .app
        ))
        presenter.showEnding(of: result)
    }

    /// Stops the prompt that runs: the controller's turn is fenced and the
    /// reservation dropped in one step, so the next prompt can be reserved
    /// at once; the task that awaits `runTurn(_:)` is then cancelled.
    func cancel(_ turnTask: Task<Void, Error>?) {
        sessionHost.cancelPrompt(in: slotID)
        turnTask?.cancel()
    }
}
```

Notes on the flow:

- What a command shows while it runs reaches the presenter as it happens; the
  outcome carries only the closing notices, which the channel presents.
- `ChatCommandAction.startTurn` carries the prompt and the purpose of the turn
  a command starts (`/plan`, `/goal`, `/review`, an approved plan).
  `locksResponseLanguage` is `true` for a prompt the operator typed, which
  takes the attachments staged by `/attach`, and `false` for a prompt the
  command built.
- `context` holds the facts that decide which commands the operator sees
  (`ChatCommandContext`).
- Route live `@mentions` before `pendingReplyAction(for:)`:
  `SharedChatMentionParser.parse(from:)` reads them, and they are never a
  reply.
- Run one turn at a time, as the terminal and ACP do: `reservePrompt(in:)`
  refuses a second one with `.sessionBusy`, and so do `/sessions new` and a
  load while a prompt is reserved. A line that arrives while a turn runs
  either runs at once, when
  `controller.commandRegistry.isAvailableDuringGeneration(line)` is `true`,
  or waits in the app's queue (`ChatPromptQueue`) until the turn ends.
- To stop a turn, call `cancelPrompt(in:)` on the host, which fences the
  controller's turn (`cancelActiveTurn()`) and drops the reservation in one
  step, so the turn writes nothing back while it unwinds, then cancel the
  task that awaits `runTurn(_:)`. A failed or cancelled turn throws a
  `ChatTurnFailure`, which carries the file changes the turn still made.
  Work that suspended checks its reservation again before it writes
  (`holdsPrompt(_:)`, `withReservedIncarnation(_:_:)`); a replaced or closed
  incarnation never matches.
- The session operations and selections are controller methods too
  (`chooseModel()`, `selectModel(id:)`, `selectTools(keys:)`,
  `startNewSession(newSessionID:)`, `saveSession(…)`, `loadSavedSession(…)`,
  `compactSession(maxTokensOverride:)`, and the others); they return a
  `ChatSelectionOutcome` or a `ChatSessionOperationOutcome`. On a controller
  the host runs, `startNewSession(newSessionID:)` and `loadSavedSession(…)`
  replace the incarnation, as `newSession(in:sessionID:)` and
  `loadSavedSession(in:name:checkpointEntryID:)` of the host do.

## Overviews

The task-graph and sub-agent overviews reach the presenter as values
(`ChatTaskGraphOverview`, `ChatSubAgentOverview`); the text is the app's.

- `startTaskGraphObserver()` binds the observer to the current session, and
  `stopTaskGraphObserver()` stops it. Start it again after the session
  changes. The controller then calls
  `presentTaskGraphOverview(_:origin:publication:)`, debounced. Do not show an
  `.automatic` overview whose `isSignificant` is `false`; an `.explicit` one,
  from `/tasks`, is always shown.
- `publishSubAgentOverviewIfChanged(relatedToolName:presenter:)` publishes the
  sub-agent overview around an `agent.*` tool call. While a blocking `agent.*`
  call runs, `startSubAgentOverviewRefreshIfNeeded(presenter:)` refreshes it
  every 2 s, and `stopSubAgentOverviewRefresh(presenter:)` stops the refresh
  and publishes once. The terminal calls them from its presenter's
  `presentToolCallStarted` and `presentToolCallSettled`. The presenter
  receives `presentSubAgentOverview(_:origin:publication:)`.
- `reserveTaskGraphOverviewPublication()` and
  `reserveSubAgentOverviewPublication()` let the presenter drop a publication
  that a later one overtook. The default `nil` presents them as they come.

## Observing a Session

`ChatSessionStateReducer` is a presenter that keeps the observable state of a
session, so the app renders a value instead of keeping state of its own. It
records what the controller presents in one ordered log per session
(`ChatTurnEntry`, with a strictly increasing `sequence`) and publishes a
`ChatSessionSnapshot` after every change. The snapshot's `transcript`
(prompts and closed assistant blocks), `activity` (tool calls), `notices`, and
`fileChanges.artifactHistory` are projections of the `log`. The other members
are sub-states of their own: `turn` (phase, the text still streaming in
`liveAssistantText` and `liveThought`, metrics, context window, usage),
`taskGraph`, `subAgents`, `fileChanges.turnSummary`, `selection`,
`savedSession`, `pendingRequests`, and `summary`. Assistant text reaches the
log in blocks, closed where the session transcript closes them.

`ChatPendingRequestHost` is a host that publishes every interaction the
controller asks for (tool consent, menus, a text line, an attachment, and
workspace access when `gatesWorkspaceAccess` is `true`) in the snapshot's
`pendingRequests`, and waits until the app answers it. A slot opened with
`publishesState: true` gives every incarnation a reducer, attached to the
controller before anything is presented, and a slot that asks with
`.pendingRequests(capabilities:gatesWorkspaceAccess:openExternal:)` gives
every incarnation a pending-request host bound to that reducer, which refuses
the requests still open when the incarnation ends:

```swift
struct ObservedSession: Sendable {
    let sessionHost: ChatSessionHost
    let slotID: ChatSlotID
    let controller: ChatSessionController
    let reducer: ChatSessionStateReducer
    let host: ChatPendingRequestHost
}

@ChatSessionActor
func makeObservedSession(
    environment: ChatSessionEnvironment,
    workspaceURL: URL
) async throws -> ObservedSession {
    let runner = ChatSessionRuntimeFactory.makeSessionRunner(toolAuthorizationHandler: nil)
    let sessionHost = ChatSessionHost(runner: runner, environment: environment)
    let slotID = try sessionHost.openSlot(ChatSlotDescriptor(
        identity: .window("main"),
        workingDirectory: workspaceURL,
        presenter: AppPresenter(),
        interaction: .pendingRequests(
            capabilities: [.toolConsent, .singleChoice, .multipleChoice, .textInput],
            gatesWorkspaceAccess: true
        ),
        authorizer: ChatToolConsentAuthorizer(host: AppInteractionHost()),
        defaultOrigin: .app,
        publishesState: true
    ))
    let incarnation = try await sessionHost.newSession(
        in: slotID,
        sessionID: UUID().uuidString.lowercased()
    )
    // Both exist for a slot that publishes state and asks with pending requests.
    guard let reducer = incarnation.reducer, let host = incarnation.pendingRequestHost else {
        throw CancellationError()
    }
    return ObservedSession(
        sessionHost: sessionHost,
        slotID: slotID,
        controller: incarnation.controller,
        reducer: reducer,
        host: host
    )
}
```

The slot's `presenter` is the app's primary presenter, which receives the
same calls as the reducer; a slot that renders from the snapshot only passes
a presenter that implements nothing. The slot's `authorizer` is the consent
policy of the gated tools, built over the host it asks for consent; the
menus, text lines, attachments, and workspace access of the operations go to
the incarnation's pending-request host. The `defaultOrigin` is the origin of
the turns the app starts without naming one (`ChatTurnRequest(…, origin:)`). The
closing notices of an operation, which the app presents itself (see
[Running a Line](#running-a-line)), go to `reducer.presentSessionNotice(_:)`
like any other presentation. The reducer and the pending-request host can
also be composed by hand, below the host:
`ChatSessionStateReducer(sessionID:workingDirectory:defaultOrigin:)`,
`ChatPendingRequestHost(reducer:capabilities:gatesWorkspaceAccess:)`, and the
controller initializer with the reducer as presenter, or
`controller.addObserver(reducer)` next to a presenter of the app's own: the
reducer is a `ChatSessionObserver`, a presenter that sees every event of the
controller before the channel's presenter, whatever channel drives the slot,
and `removeObserver(_:)` detaches it (the convenience
`ChatSessionStateReducer(controller:defaultOrigin:)` reads the session, the
working directory, and the selection from the controller).

The reducer and the host are isolated to `ChatSessionActor`. Each call of
`snapshots()` returns a new stream that starts with the current snapshot and
keeps only the newest one not yet delivered: a slow view skips snapshots, never
receives them out of order, and always ends on the latest. Answer a request with
`resolve(_:answer:)`; `nil` refuses it, an answer of another kind is refused
and leaves the request open, and cancelling the task that waits refuses it too.
`cancelPendingRequests()` refuses every open request, for a view that goes
away; the host does it when the incarnation ends. A view follows the slot with
`sessionHost.incarnations(in:)` and observes the reducer of each incarnation
(`sessionHost.reducer(in:)` reads the current one); the stream of a reducer
the host created ends, after its last snapshot, when its incarnation ends.

```swift
@MainActor
final class SessionViewModel {
    private(set) var snapshot: ChatSessionSnapshot?
    private let host: ChatPendingRequestHost

    init(host: ChatPendingRequestHost) {
        self.host = host
    }

    /// Runs until the task that calls it is cancelled.
    func observe(_ reducer: ChatSessionStateReducer) async {
        for await snapshot in await reducer.snapshots() {
            self.snapshot = snapshot
        }
    }

    func answer(_ request: ChatPendingRequest, with answer: ChatPendingRequest.Answer?) async {
        await host.resolve(request.id, answer: answer)
    }
}
```

A view that keeps the last sequence it rendered catches up from the log while
the epoch is the same and no entry it misses was dropped; otherwise it rebuilds
from the snapshot:

```swift
func entries(
    after lastSeen: Int,
    epoch: UInt64,
    in snapshot: ChatSessionSnapshot
) -> [ChatTurnEntry]? {
    guard snapshot.epoch == epoch, lastSeen + 1 >= snapshot.firstRetainedSequence else {
        return nil
    }
    return snapshot.log.filter { $0.sequence > lastSeen }
}
```

Notes:

- The epoch of a reducer the host created is the epoch of its incarnation:
  it changes, and the log starts again, when the slot runs a new incarnation
  (`/sessions new`, a saved session loaded or restored from a checkpoint,
  `newSession(in:sessionID:)`); `adoptSessionID(_:in:)` keeps it. A reducer
  composed by hand advances its own epoch when its controller switches
  session in place. The log of a loaded session is rebuilt from its
  transcript, with `ChatTurnOrigin.unknown` prompts; a tool result completes
  its call by id, and a result without an id the oldest call without an id
  still open in its turn, so no restored call stays running. Sequences are
  never reused.
- The log has the byte budget of the session transcript and drops its oldest
  entries whole; `firstRetainedSequence` tells which entries it still holds.
  `notices` keeps the latest `ChatSessionStateReducer.maximumNoticeCount` (64).
- The log and the snapshot are transient: they are never saved with a session
  nor copied into a checkpoint.
- Switch over `ChatTurnEntry.Kind` and `ChatPendingRequest.Kind` with a
  `default` case, as over every public Chat enum.

## Observing the Host

A shell of the app (its sidebar, its window list) renders the
`ChatShellSnapshot` of the host instead of keeping a list of its own:
`sessions`, the `ChatSessionSummary` of the session each open slot runs, by
`ChatSlotID`; `savedSessions`, the `ChatSavedSessionSummary` values of each
workspace an open slot runs sessions in, most recently saved first, by the
standardized URL of the workspace (`summary.workspace.standardizedFileURL`);
and `telegram`, a `ChatShellTelegramState` with `isConfigured` (setup configured
Telegram, by the rule the terminal offers `/telegram` with), `isPolling` (the
host's poller runs a long poll), and `drivenSlots` (the slots the linked chat
drives). `shellSnapshot` is the current value; each call of
`shellSnapshots()` returns a stream that starts with it, keeps only the
newest snapshot not yet delivered, and ends at `shutdown()` or when the host
is released:

```swift
@MainActor
final class ShellViewModel {
    private(set) var shell: ChatShellSnapshot?

    /// Runs until the host shuts down or the task that calls it is cancelled.
    func observe(_ sessionHost: ChatSessionHost) async {
        for await shell in await sessionHost.shellSnapshots() {
            self.shell = shell
        }
    }
}
```

Notes:

- The shell only aggregates what the sessions summarize and creates no
  reducer. A slot that publishes state, or that Telegram drives, shows its
  reducer's `summary`; any other slot shows a summary built from its
  incarnation with the same rules: its workspace, the saved session's name or
  one derived from the first prompt, `isGenerating` while a prompt is
  reserved, the origin of the turn generating, and a `pendingRequestCount` of
  0, since only a reducer publishes pending requests. A new or loaded session
  is one snapshot, with the new session: the slot is never shown without
  session in between.
- The saved sessions and the Telegram settings are on disk, so they are read
  only while a shell observes the host, from the first `shellSnapshots()` or
  `refreshShellSnapshot()` until the last stream ends, and off the chat
  actor; the store is only listed, never migrated, so a save in progress is
  never moved. The saved sessions of a workspace are read again when a slot
  of it starts another session and when a session of the host is saved or
  deleted, the settings and the poller together when a slot hands itself to
  Telegram, takes itself back, or closes; the poller tells nobody when a
  poll ends on its own, which shows at the next read. Nothing is read on a
  timer; `refreshShellSnapshot()` reads everything again, for example for a
  session another process saved.
- The shell snapshot is transient, like the session snapshot.

## Telegram Channel

Telegram is a channel of the slot, not a mirror of it: `/telegram on` hands
the slot to the Telegram chat that setup linked, which drives the session from
then on, and `/telegram off` takes it back. The host owns the slot's
`TelegramChannel`, created on the first activation on the router and poller
every slot shares and kept, attached or not, for the life of the slot; the app
never builds it. The router and the poller are one per `ChatSessionHost`, so an
app runs one host per process: two hosts on the same bot would run two long
polls, and Telegram would answer the second with HTTP 409.

```swift
extension AppSession {
    /// `/telegram on`: hands the slot to the linked chat. Throws a
    /// `TelegramChannelAttachError` with a `failureText` when the session
    /// cannot be linked, leaving the app in charge.
    func startTelegram() async throws {
        try await sessionHost.activateTelegram(in: slotID, primaryChannelDescription: "app")
        presenter.show("Session driven from Telegram.")
    }

    /// `/telegram off`: takes the slot back and shows what the app missed,
    /// before anything more of the turn in progress.
    func stopTelegram() async {
        _ = await sessionHost.deactivateTelegram(in: slotID) { [presenter] catchUp in
            presenter.showCatchUp(catchUp)
        }
    }

    var isDrivenFromTelegram: Bool {
        sessionHost.activeChannel(in: slotID) == .telegram
    }
}
```

What happens at the handover:

- `activateTelegram(in:primaryChannelDescription:)` attaches the channel (a
  repeated call restarts the link), names the app in the texts sent to the
  chat, sends the chat the last `TelegramChannel.handoverContextEntryCount`
  (6) prompts and responses of the session as context, switches the slot's
  presenter and interaction host to the channel, and starts reading the
  chat. From then on the chat runs prompts, voice notes, `/plan`, `/goal`,
  `/review`, and replies to pending questions, with the composition the
  slot's hooks give (`ChatSessionChannelHooks.turnSessionConfiguration(for:controller:)`,
  by default the controller's own) and inside the environment they give the
  turn (`ChatSessionChannelHooks.runTurnFromAnotherChannel(controller:_:)`,
  by default none: the turn runs as it is; a hook that throws refuses the
  turn, which is released without starting), answers `/start`, `/help`, `/status`,
  `/changes`, `/diff`, and `/chat`, and decides the gated tools with
  `/allow`, `/always`, and `/deny`; `/undo` is refused and names the app. A
  question the session had open on the app (a tool consent, a line of text,
  an attachment) is withdrawn there and asked again in the chat, and the
  other way round at `/telegram off`. A turn in progress moves with the slot:
  the chat receives the block already streaming as context and the rest of
  the turn, and its ending is presented by whoever drives the slot when it
  ends; a turn still running from Telegram at `/telegram off` goes on
  presented to the app.
- During a turn the chat drives, the slot's presenter hands the channel what
  the controller presents, and the channel sends the chat, with no setting:
  each response, each completed reasoning block as a `💭 Thinking` message,
  the root tool calls as the lines of one activity message edited in place
  (the call's title and its outcome, never its arguments or result), the
  task-graph card, and the sub-agent overview as one `🤖 Sub-agent` message
  per turn. The channel asks the controller for the sub-agent overview itself.
  What the sub-agents already showed when the chat takes the slot, in the app,
  is not sent: their responses present then stay out of the chat, and an
  overview unchanged since then creates no message; each response that comes
  later is sent once, for the life of the channel, not once per turn.
  The task-graph card comes from the controller's task-graph observer (see
  [Overviews](#overviews)): the channel starts it only for the slot of an ACP
  session, so an app starts it for its window as it does for itself. On that
  slot the channel stops it at the end of every turn it presents, publishes the
  latest graph to the turn that ends, and runs it again once the turn is
  closed, as the terminal does.
- While Telegram drives the slot the app is dormant: `admitLine(_:in:)`
  admits only `/telegram`, `/telegram off`, and `/exit`
  (see [Running a Line](#running-a-line)), and a `reservePrompt(in:)` of the
  app meets `.sessionBusy` while a turn from Telegram runs.
- `deactivateTelegram(in:presentingCatchUp:)` returns the catch-up, a `ChatTelegramCatchUp`:
  the `entries` of the session's log with a sequence greater than the last
  one the app saw (`ChatTurnEntry`, oldest first; render them as a restored
  transcript, `ChatTurnEntry.transcriptMessages(from:)` turns them into
  runtime messages), the `liveAssistantText` of a response still streaming,
  `incarnationChanged` when the app started another session in the slot
  (`newSession(in:sessionID:)` or a load) while Telegram drove it (the
  entries are then the whole log of the new session), and
  `omittedOlderEntries` when the log's bound dropped entries. It is `nil`
  when Telegram did not drive the slot; the link, if any, is stopped all
  the same. Given `presentingCatchUp`, the host calls it with the catch-up
  right after the switch and before the link stops, and holds what the turn
  in progress presents until it returns, so the rest of the turn reaches
  the app after the catch-up, in order and whole; without it the app shows
  the returned catch-up itself, after what the turn presented meanwhile. A
  slot that publishes no state gets a reducer for the handover, detached once
  the catch-up is read; the log is transient either way.
- The texts the channel has for the app (the activation text, a poll-health
  notice, a failure) arrive through `telegramChannel(in:)?.noticeSink`, with
  their `ChatSessionNoticeChannel`; without a sink they are dropped. Install
  it before the first activation to receive the activation text.
- `telegramStatusText(in:)` is the `/telegram` status; `isActive`,
  `linkedChatTitle`, and `sessionTopic` of the channel report the link.
- The link belongs to the slot: a new or loaded session keeps the channel and
  the handover, and `rebind(sessionID:displayName:)` moves the session's
  topic to it. `closeSlot(_:)` and `shutdown()` shut the channel down.
- An *Always* given in the chat is recorded in the slot's consent authorizer
  and covers the session on every channel afterwards.

## Sandbox Contract

A sandboxed app uses the existing API as follows; there is no separate sandbox
switch.

- **Support directory.** Configure it before anything reads the settings
  (see [Composition](#composition)).
- **Hosted models and agent profiles.** With a hosted configuration the model
  catalog lists `hostedModels` instead of `settings.json`, and
  `availableAgents()` returns `hostedAgentProfiles` instead of `agents.json`.
  Keep `cacheAgentProfiles` at its default `true`, which sets
  `hostedAgentProfiles`. No model or thinking choice is written to the
  settings (`ChatSessionEnvironment.persistsSelections` is `false`).
- **No `local.exec`.** Leave the `shell` tool group (`local.exec` and
  `exec.job`) out of the tools of the hosted agent profiles and out of
  `selectTools(keys:)`.
- **No feature runtime.** Pass `featureRuntime: nil` to
  `ChatSessionEnvironment`: the tool catalog lists no optional feature.
- **No tool consent.** Declare a host without `.toolConsent`. The host is then
  never asked, and `ChatToolConsentAuthorizer` refuses the gated tools
  (`ChatToolConsentAuthorizer.gatedToolNames`: `local.exec` and the
  destructive direct tools) with a diagnostic.
- **Channel commands.** `/setup`, `/voice`, `/ds4`, the optional features
  (`/feature`), ZenCRON, and `/cron` are commands of the terminal channel,
  outside the API. With the default `commandRegistry`
  (`ChatCommandRegistry.sharedDescriptors`) those lines answer as unknown
  commands, and `/tools logs` answers `.channelCommand`. The Chat layer
  starts no process.

## Compatibility

The public API of `Sources/ZenCODECore/Chat` follows semantic versioning (see
[Compatibility Contract](architecture.md#compatibility-contract)). From 3.3.0
it comprises:

- the session host: `ChatSessionHost` (with `RuntimeSessionDisposition`),
  `ChatSlotDescriptor`, `ChatSlotIdentity`, `ChatSlotInteraction`,
  `ChatSlotID`, `ChatSessionIncarnation`, `ChatSessionOperationState`,
  `ChatPromptReservation`, and `ChatSessionHostError`, with the shell
  (`ChatShellSnapshot` and `ChatShellTelegramState`);
- the controller, `ChatSessionController`, and its contracts:
  `ChatSessionEnvironment`, `ChatSessionPresenter`, `ChatSessionObserver`,
  `ChatInteractionHost` with `ChatChannelCapabilities`,
  `ChatSessionChannelHooks` with `ChatIncarnationChange`,
  `ChatSessionRecreationReason`, and `ChatSelectionCommand`,
  `ChatToolConsentAuthorizer`, `ChatSessionRuntime`, and
  `ChatSessionManagementRuntime`; the turn (`ChatTurnRequest`,
  `ChatTurnResult`, `ChatTurnFailure`, and `ChatTurnPurpose`); the notices
  (`ChatSessionNotice` with its payloads, and `ChatSessionNoticeText`); the
  outcomes (`ChatCommandOutcome`, `ChatSelectionOutcome`,
  `ChatSessionOperationOutcome`, and the others); the overviews
  (`ChatTaskGraphOverview` and `ChatSubAgentOverview`); `ChatModelCatalog`;
  `ChatCommandRegistry`, `ChatCommandDescriptor`, and `ChatCommandContext`;
  `ChatPromptQueue` and `ChatQueuedPrompt`; `SharedChatMentionParser`; and
  `ChatSessionRuntimeFactory`;
- the observable state: `ChatSessionStateReducer`, `ChatSessionSnapshot` with
  `ChatTurnState`, `ChatFileChangesState`, and `ChatSessionSummary`,
  `ChatTurnEntry` with `ChatTurnOrigin` and `ChatTurnPhase`,
  `ChatPendingRequestHost`, and `ChatPendingRequest`;
- the Telegram channel: `TelegramChannel` (with `SessionTopic`),
  `TelegramChannelAttachError`, `ChatSlotChannel`, `ChatSlotAdmission`, and
  `ChatTelegramCatchUp`, with the host's
  `activateTelegram(in:primaryChannelDescription:)`,
  `deactivateTelegram(in:presentingCatchUp:)`, `telegramStatusText(in:)`,
  `activeChannel(in:)`, `telegramChannel(in:)`, and `admitLine(_:in:)`; the
  channel's `stoppedNoticeText`.

The rules:

- additions arrive in minor releases, and breaking changes only in major
  releases;
- public enums are not `@frozen`: a minor release may add cases, so switch
  over them with a `default` case (`ChatCommandAction`, `ChatSessionNotice`,
  `ChatIncarnationChange`, `ChatSessionHostError`, and the others);
- the `@ChatSessionActor` isolation is part of the contract;
- `TerminalChatActor` is deprecated: use `ChatSessionActor`. It is removed in
  the next major release;
- `LocalExecPermissionAuthorizer` and `ACPPermissionBroker` are not
  deprecated: they are the terminal's and ACP's adapters over
  `ChatToolConsentAuthorizer`, which an app uses directly;
- `ChatCommandFence`, `ChatPlanningCommandPolicy`, `ChatSessionStateStore`,
  and `ChatCommandState` are internal.
