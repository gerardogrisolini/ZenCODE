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
   per process: it owns the runner, the Telegram router and poller every
   companion shares, the sleep assertion, and the epochs of every session.
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
companion and the protocols `ChatSessionChannelHooks` and
`TelegramCompanionChannel` are isolated to `ChatSessionActor` too. Open the
slots and create the companion inside a `@ChatSessionActor` context.

`ChatSessionPresenter` and `ChatInteractionHost` are `Sendable` protocols with
`async` requirements, so their implementations can live on the main actor.

Every session and every companion presenter of the app share the single
`ChatSessionActor` executor, and the controller's `ChatFanOutPresenter`
awaits each companion before the primary presenter. A presenter that blocks
therefore delays every session: return quickly from each call, for example by
enqueuing the output and rendering it elsewhere.

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
operation, for example after `/sessions new` started a session. Every
requirement has a default. The slot and the controllers hold the hooks
weakly, so the app keeps them.

```swift
@ChatSessionActor
final class AppChannelHooks: ChatSessionChannelHooks {
    weak var session: AppSession?

    func sessionDidStartNew() async {
        await session?.sessionDidChange()
    }
}
```

`responseLanguageSection()` is the response-language section of the system
prompt that a selection operation composes; the app returns the same value it
passes as `responseLanguageSection` to a turn.

### Session

The session object of the app owns the hooks and the companion, and follows
its slot in the host: `controller` is the controller of the slot's current
incarnation. It is isolated to `ChatSessionActor`, so it reaches the host and
the controller without hopping.

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
    var companion: TelegramSessionCompanion?
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
    /// Telegram topic to it.
    func sessionDidChange() async {
        await controller.startTaskGraphObserver()
        await companion?.rebind(
            sessionID: controller.sessionID,
            displayName: controller.savedSessionState.savedSessionName ?? controller.sessionID
        )
    }

    func close() async {
        incarnationObservation?.cancel()
        await controller.stopTaskGraphObserver()
        await companion?.shutdown()
        await sessionHost.closeSlot(slotID)
    }
}
```

`applyInitialAgentSelectionIfNeeded()` applies the launch agent's profile, so
call it once per incarnation: a second call resets the tool and skill
selection to the profile. `sessionDidStartNew()` runs on the new controller,
after the host replaced the incarnation, so `controller` is already the new
one there. When the last window closes, `sessionHost.shutdown()` ends every
slot and the runner.

## Running a Line

A line goes through the controller in this order:

1. `handleCommandLine(_:context:)` for a slash command;
2. `pendingReplyAction(for:)` for any other line, so a reply the session is
   waiting for (the goal of `/plan approve`, a Planner question, a `/goal`
   workflow) is not sent as a new prompt; `nil` means the line is a prompt;
3. `reservePrompt(in:)` on the host, which reserves the right to run one
   prompt on the slot's current incarnation in the same step as it checks
   that none runs (`ChatSessionHostError.sessionBusy` otherwise);
4. `turnSessionConfiguration(for:responseLanguageSection:)`, the
   configuration of one turn with its purpose, composed as the terminal
   composes it;
5. `runTurn(_:)` with a `ChatTurnRequest`, then `releasePrompt(_:)`.

```swift
extension AppSession {
    func submit(_ line: String) async throws {
        var prompt = line
        var purpose = ChatTurnPurpose.normal
        var typedByOperator = true

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
        await companion?.beginTurn(origin: .primary)
        do {
            let result = try await controller.runTurn(ChatTurnRequest(
                prompt: prompt,
                attachments: typedByOperator ? controller.consumePendingAttachments() : [],
                purpose: purpose,
                sessionConfiguration: configuration,
                origin: .app
            ))
            await companion?.finishTurn(
                outcome: .completed(result.response.text),
                fileChangeSummary: result.fileChangeSummary
            )
        } catch let failure as ChatTurnFailure {
            let outcome: TelegramSessionCompanion.Outcome = failure.isCancellation
                ? .cancelled
                : .failed(failure.underlying.localizedDescription)
            await companion?.finishTurn(outcome: outcome, fileChangeSummary: failure.fileChangeSummary)
            throw failure
        }
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
`controller.attachCompanionPresenter(reducer)` next to a presenter of the
app's own (the convenience `ChatSessionStateReducer(controller:defaultOrigin:)`
reads the session, the working directory, and the selection from the
controller).

The reducer and the host are isolated to `ChatSessionActor`. Each call of
`snapshots()` returns a new stream that starts with the current snapshot and
keeps only the newest one not yet delivered: a slow view skips snapshots, never
receives them out of order, and always ends on the latest. Answer a request with
`resolve(_:answer:)`; `nil` refuses it, an answer of another kind is refused
and leaves the request open, and cancelling the task that waits refuses it too.
`cancelPendingRequests()` refuses every open request, for a view that goes
away; the host does it when the incarnation ends. A view follows the slot with
`sessionHost.incarnations(in:)` and observes the reducer of each incarnation
(`sessionHost.reducer(in:)` reads the current one).

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
  transcript, with `ChatTurnOrigin.unknown` prompts. Sequences are never reused.
- The log has the byte budget of the session transcript and drops its oldest
  entries whole; `firstRetainedSequence` tells which entries it still holds.
  `notices` keeps the latest `ChatSessionStateReducer.maximumNoticeCount` (64).
- The log and the snapshot are transient: they are never saved with a session
  nor copied into a checkpoint.
- Switch over `ChatTurnEntry.Kind` and `ChatPendingRequest.Kind` with a
  `default` case, as over every public Chat enum.

## Telegram Companion

A `TelegramSessionCompanion` mirrors the session to the Telegram chat that
setup linked; `TelegramCompanionRuntimeFactory.makeRouter()` reads that link
from `settings.json` in the support directory. Create the companion on
`ChatSessionActor`, with the router and the control service of
`TelegramCompanionRuntimeFactory`:

```swift
extension AppSession {
    func makeCompanion(channel: AppTelegramChannel) -> TelegramSessionCompanion {
        let companion = TelegramSessionCompanion(
            controller: controller,
            sessionRunner: sessionHost.runner,
            router: TelegramCompanionRuntimeFactory.makeRouter(),
            controlService: TelegramCompanionRuntimeFactory.makeControlService(),
            channel: channel,
            configuration: TelegramSessionCompanion.Configuration(
                primaryChannelDescription: channel.primaryChannelDescription,
                policy: .mirrorOnly,
                consentLocationDescription: "the app"
            )
        )
        channel.companion = companion
        self.companion = companion
        return companion
    }
}
```

The companion holds the channel weakly, so the app keeps it. A process that
runs several sessions builds one router and shares it among their companions,
as the ACP bridge does. A companion follows the controller it was created
with: when the slot runs a new incarnation (`/sessions new`, a loaded
session), end it with `shutdown()` and create one for the new controller.

```swift
@ChatSessionActor
final class AppTelegramChannel: TelegramCompanionChannel {
    let primaryChannelDescription = "app"
    weak var companion: TelegramSessionCompanion?
    private(set) var notices: [String] = []

    func commandContext() -> ChatCommandContext {
        []
    }

    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        notices.append(text)
    }

    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        .refused
    }

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        guard let companion, companion.activeTurnOrigin?.lease == lease else { return }
        await companion.routeWasInvalidated(lease)
        await companion.detach()
    }
}
```

`overviewMirrorBarrier()`, `sharedChatPanelDidChange()`, and
`isSessionGenerating()` have defaults.

Lifecycle:

- The companion registers its presenter in the controller when it is created,
  and stays detached until `attach()`.
- To link the session, call `try await companion.attach()`, which throws a
  `TelegramCompanionAttachError` with a `failureText`, then
  `companion.startConsuming()`, because the app has no loop of its own that
  reads Telegram. `detach()` unlinks it, and `shutdown()` ends it with the
  session. `isActive` and `statusText()` report the link.
- Mark every turn with `beginTurn(origin: .primary)` and
  `finishTurn(outcome:fileChangeSummary:)`, as in [Running a Line](#running-a-line).
- After a new or loaded session, call `rebind(sessionID:displayName:)` with
  the name of the session's topic, for example the saved session's name.

Policy:

- With `.mirrorOnly` the linked chat mirrors the session and can consult it
  (`/status`, `/changes`, `/diff`, `/chat`), but it cannot drive it: the
  companion refuses prompts, voice notes, `/plan`, `/goal`, `/review`,
  replies to pending questions, and `/undo` with `mirrorOnlyRefusalText`. It
  never hands a prompt to the channel. Use it when the app does not run
  prompts from Telegram.
- With `.full` the companion hands prompts to
  `enqueueTelegramPrompt(_:lease:mode:)`, and the app manages the prompt
  queue itself: it queues the prompt, for example in a `ChatPromptQueue`,
  answers `.queued` or `.queueFull`, and runs it as a turn with
  `beginTurn(origin: .telegram(lease))`. A `.submittedLine` is classified
  again (command, reply, or prompt) when it leaves the queue. When the route
  of the turn in progress is invalidated, the channel stops that turn before
  it calls `routeWasInvalidated(_:)`.

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
[Compatibility Contract](architecture.md#compatibility-contract)):

- additions arrive in minor releases, and breaking changes only in major
  releases;
- public enums are not `@frozen`: a minor release may add cases, so switch
  over them with a `default` case (`ChatCommandAction`, `ChatSessionNotice`,
  and the others);
- the `@ChatSessionActor` isolation is part of the contract;
- `TerminalChatActor` is deprecated: use `ChatSessionActor`. It is removed in
  the next major release;
- `LocalExecPermissionAuthorizer` and `ACPPermissionBroker` are not
  deprecated: they are the terminal's and ACP's adapters over
  `ChatToolConsentAuthorizer`, which an app uses directly;
- `ChatCommandFence`, `ChatPlanningCommandPolicy`, `ChatSessionStateStore`,
  and `ChatCommandState` are internal;
- `ChatSessionHost` and its types (`ChatSlotDescriptor`, `ChatSlotIdentity`,
  `ChatSlotInteraction`, `ChatSlotID`, `ChatSessionIncarnation`,
  `ChatSessionOperationState`, `ChatPromptReservation`,
  `ChatSessionHostError`) are public from the release that introduces the
  host; `ChatSessionHostError` is a public enum like the others.
