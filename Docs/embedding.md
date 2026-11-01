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
4. Build the host, the consent authorizer, the session runner
   (`ChatSessionRuntimeFactory.makeSessionRunner(...)`), and the controller
   (`ChatSessionController(sessionID:managementRuntime:environment:workingDirectory:presenter:host:authorizer:)`).

```swift
import Foundation
import ZenCODECore

@MainActor
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
    let controller = ChatSessionController(
        sessionID: UUID().uuidString.lowercased(),
        managementRuntime: runner,
        environment: environment,
        workingDirectory: workspaceURL,
        presenter: presenter,
        host: host,
        authorizer: authorizer
    )

    let session = await AppSession(controller: controller, runner: runner, presenter: presenter)
    try await session.start()
    return session
}
```

`makeSessionRunner` uses `ChatSessionRuntimeFactory.productionBackendFactory`
unless the app passes another `backendFactory`. That property is the one place
of Core that chooses a backend; the app, like `zen`, is a composition root
that injects it.

## Isolation

`ChatSessionController` is isolated to the `ChatSessionActor` global actor.
Its initializers are `nonisolated`, so the app creates it from any context.
From the main actor or a nonisolated context, every other call to the
controller takes `await`. The companion and the protocols
`ChatSessionChannelHooks` and `TelegramCompanionChannel` are isolated to
`ChatSessionActor` too. Assign `channelHooks` and create the companion inside
a `@ChatSessionActor` context.

`ChatSessionPresenter` and `ChatInteractionHost` are `Sendable` protocols with
`async` requirements, so their implementations can live on the main actor.

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
requirement has a default. The controller holds the hooks weakly, so the app
keeps them.

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

The session object of the app owns the controller, the runner, the hooks,
and the companion. It is isolated to `ChatSessionActor`, so it reaches the
controller without hopping.

```swift
@ChatSessionActor
final class AppSession {
    let controller: ChatSessionController
    let runner: AgentCoreSessionRunner
    private let presenter: AppPresenter
    private let hooks: AppChannelHooks
    var companion: TelegramSessionCompanion?

    init(controller: ChatSessionController, runner: AgentCoreSessionRunner, presenter: AppPresenter) {
        self.controller = controller
        self.runner = runner
        self.presenter = presenter
        self.hooks = AppChannelHooks()
        hooks.session = self
        controller.channelHooks = hooks
    }

    /// Once, before the first turn: the launch agent's tools and skills,
    /// then the task-graph observer.
    func start() async throws {
        await controller.applyInitialAgentSelectionIfNeeded()
        try controller.applyInitialSkillSelectionIfNeeded()
        await controller.startTaskGraphObserver()
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
        await controller.stopTaskGraphObserver()
        await companion?.shutdown()
        await runner.shutdown()
    }
}
```

`applyInitialAgentSelectionIfNeeded()` applies the launch agent's profile, so
call it once: a second call resets the tool and skill selection to the
profile.

## Running a Line

A line goes through the controller in this order:

1. `handleCommandLine(_:context:)` for a slash command;
2. `pendingReplyAction(for:)` for any other line, so a reply the session is
   waiting for (the goal of `/plan approve`, a Planner question, a `/goal`
   workflow) is not sent as a new prompt; `nil` means the line is a prompt;
3. `turnSessionConfiguration(for:responseLanguageSection:)`, the
   configuration of one turn with its purpose, composed as the terminal
   composes it;
4. `runTurn(_:)` with a `ChatTurnRequest`.

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
                sessionConfiguration: configuration
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
- Run one turn at a time, as the terminal and ACP do. A line that arrives
  while a turn runs either runs at once, when
  `controller.commandRegistry.isAvailableDuringGeneration(line)` is `true`,
  or waits in the app's queue (`ChatPromptQueue`) until the turn ends.
- To stop a turn, call `cancelActiveTurn()` first, so the turn writes nothing
  back while it unwinds, then cancel the task that awaits `runTurn(_:)`. A
  failed or cancelled turn throws a `ChatTurnFailure`, which carries the file
  changes the turn still made.
- The session operations and selections are controller methods too
  (`chooseModel()`, `selectModel(id:)`, `selectTools(keys:)`,
  `startNewSession(newSessionID:)`, `saveSession(…)`, `loadSavedSession(…)`,
  `compactSession(maxTokensOverride:)`, and the others); they return a
  `ChatSelectionOutcome` or a `ChatSessionOperationOutcome`.

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
            sessionRunner: runner,
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
as the ACP bridge does.

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
  and `ChatCommandState` are internal.
