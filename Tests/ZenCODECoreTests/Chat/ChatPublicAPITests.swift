//
//  ChatPublicAPITests.swift
//  ZenCODECoreTests
//
//  The public Chat API as a host app sees it: everything here is reached
//  through `import ZenCODECore` without `@testable`, so a symbol of the
//  composition path that is not public fails the build of this target.
//

import Foundation
import Testing
import ZenCODECore

@Suite(.serialized)
struct ChatPublicAPITests {
    @Test("A host app composes a session, runs a command and a turn, and builds a Telegram companion")
    func aHostAppComposesASessionThroughThePublicAPI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-public-api-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            // Composition: a hosted configuration, the environment without a
            // feature runtime (a sandboxed app starts no feature process), the
            // runner from the public factory, then the controller.
            let configuration = try AgentConfiguration(
                hostedModelID: "public-api-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(
                        id: "public-api-model",
                        kind: .remoteAPI,
                        modelID: "local/public-api-model"
                    ),
                ],
                workingDirectory: workspace,
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
            let backend = ScriptedACPCommandBackend()
            let runner = ChatSessionRuntimeFactory.makeSessionRunner(
                toolAuthorizationHandler: { request in await authorizer.authorize(request) },
                backendFactory: { _, _ in backend }
            )
            let controller = ChatSessionController(
                sessionID: "public-api-\(UUID().uuidString.lowercased())",
                managementRuntime: runner,
                environment: environment,
                workingDirectory: workspace,
                presenter: presenter,
                host: host,
                authorizer: authorizer
            )
            let hooks = AppChannelHooks()
            await Self.install(hooks, on: controller)

            // A shared command answers with notices the app renders itself.
            let help = await controller.handleCommandLine("/help", context: [])
            let helpNotice = try #require(help.notices.first { notice in
                if case .help = notice { return true }
                return false
            })
            #expect(!ChatSessionNoticeText.text(for: helpNotice).isEmpty)
            #expect(Self.kind(of: helpNotice) == "help")

            // A plain line nobody is waiting for is an ordinary prompt.
            #expect(await controller.pendingReplyAction(for: "Hello") == nil)

            // A turn, presented on the app's main-actor presenter.
            await controller.applyInitialAgentSelectionIfNeeded()
            let sessionConfiguration = await controller.turnSessionConfiguration(
                for: .normal,
                responseLanguageSection: nil
            )
            let result = try await controller.runTurn(ChatTurnRequest(
                prompt: "Hello",
                sessionConfiguration: sessionConfiguration
            ))
            #expect(result.response.text == "COORDINATOR INTERNAL QUESTION")
            #expect(await presenter.assistantContent.joined() == "COORDINATOR INTERNAL QUESTION")
            #expect(await controller.transcript.first?.content == "Hello")

            // The Telegram companion of the session, built from the public
            // factories; it stays detached until `attach()`.
            let channel = AppTelegramChannel()
            let companionIsActive = await Self.makeAndShutDownCompanion(
                controller: controller,
                runner: runner,
                channel: channel
            )
            #expect(!companionIsActive)

            // The mention parser of the shared chat.
            guard case let .route(route) = SharedChatMentionParser.parse(from: "@coordinator ciao") else {
                Issue.record("@coordinator was not parsed as a mention")
                return
            }
            #expect(route.destination == .coordinator)
            #expect(route.text == "ciao")

            await runner.shutdown()
        }
    }

    @Test("A host app observes a session through the reducer and answers its pending requests")
    func aHostAppObservesASessionThroughThePublicAPI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-public-api-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let configuration = try AgentConfiguration(
                hostedModelID: "public-api-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(
                        id: "public-api-model",
                        kind: .remoteAPI,
                        modelID: "local/public-api-model"
                    ),
                ],
                workingDirectory: workspace,
                appMode: true
            )
            let environment = ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: nil,
                userHomeDirectoryURL: nil
            )
            let backend = ScriptedACPCommandBackend()
            // The composition of Docs/embedding.md, with a scripted backend.
            let session = await makeObservedSession(
                environment: environment,
                workspaceURL: workspace,
                backendFactory: { _, _ in backend }
            )
            let viewModel = await SessionViewModel(host: session.host)
            let observation = Task { await viewModel.observe(session.reducer) }

            await session.controller.applyInitialAgentSelectionIfNeeded()
            let sessionConfiguration = await session.controller.turnSessionConfiguration(
                for: .normal,
                responseLanguageSection: nil
            )
            _ = try await session.controller.runTurn(ChatTurnRequest(
                prompt: "Hello",
                sessionConfiguration: sessionConfiguration,
                origin: .app
            ))

            let snapshot = await session.reducer.snapshot
            #expect(snapshot.transcript.map(\.kind) == [
                .userPrompt(text: "Hello", attachments: [], origin: .app),
                .assistantText("COORDINATOR INTERNAL QUESTION"),
            ])
            #expect(!snapshot.turn.isGenerating)
            #expect(snapshot.summary.title == "Hello")
            #expect(entries(after: 0, epoch: snapshot.epoch, in: snapshot) == snapshot.log)
            #expect(entries(after: 0, epoch: snapshot.epoch + 1, in: snapshot) == nil)
            #expect(snapshot.log.compactMap(Self.text(of:)) == ["Hello", "COORDINATOR INTERNAL QUESTION"])

            // A pending request, answered from the main actor.
            let line = Task { await session.host.readLine(prompt: "Name?") }
            var pending: ChatPendingRequest?
            for await update in await session.reducer.snapshots() where !update.pendingRequests.isEmpty {
                pending = update.pendingRequests.first
                break
            }
            let request = try #require(pending)
            #expect(request.kind == .readLine(prompt: "Name?"))
            await viewModel.answer(request, with: .text("zen"))
            #expect(await line.value == "zen")
            #expect(await session.reducer.snapshot.pendingRequests.isEmpty)

            observation.cancel()
            await session.runner.shutdown()
        }
    }

    // MARK: - Helpers

    /// A client's switch over a log entry, with a `default` for the kinds a
    /// minor release may add.
    private static func text(of entry: ChatTurnEntry) -> String? {
        switch entry.kind {
        case let .userPrompt(text, _, _):
            return text
        case let .assistantText(text):
            return text
        default:
            return nil
        }
    }

    /// A switch over a public Chat enum from a client: new cases may arrive in
    /// a minor release, so a client always has a `default`.
    private static func kind(of notice: ChatSessionNotice) -> String {
        switch notice {
        case .help:
            return "help"
        default:
            return "other"
        }
    }

    @ChatSessionActor
    private static func install(_ hooks: AppChannelHooks, on controller: ChatSessionController) {
        controller.channelHooks = hooks
    }

    @ChatSessionActor
    private static func makeAndShutDownCompanion(
        controller: ChatSessionController,
        runner: AgentCoreSessionRunner,
        channel: AppTelegramChannel
    ) async -> Bool {
        let companion = TelegramSessionCompanion(
            controller: controller,
            sessionRunner: runner,
            router: TelegramCompanionRuntimeFactory.makeRouter(settings: nil),
            controlService: TelegramCompanionRuntimeFactory.makeControlService(),
            channel: channel,
            configuration: TelegramSessionCompanion.Configuration(
                primaryChannelDescription: "app",
                policy: .mirrorOnly,
                consentLocationDescription: "the app"
            )
        )
        let isActive = companion.isActive
        await companion.shutdown()
        return isActive
    }
}

// MARK: - A host app's channel types

/// The app's presenter lives on the main actor; the controller reaches it
/// with `await`. Every presentation it does not implement has a default.
@MainActor
private final class AppPresenter: ChatSessionPresenter {
    private(set) var assistantContent: [String] = []
    private(set) var sessionNotices: [ChatSessionNotice] = []

    func presentAssistantContent(_ content: String) async {
        assistantContent.append(content)
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        sessionNotices.append(notice)
    }
}

/// An app host without menus or tool consent: what it cannot ask is answered
/// by the defaults, and gated tools are refused without asking.
@MainActor
private final class AppInteractionHost: ChatInteractionHost {
    nonisolated let capabilities: ChatChannelCapabilities = []

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        nil
    }
}

/// The app's steps between the steps of a selection operation, on the
/// controller's isolation domain.
@ChatSessionActor
private final class AppChannelHooks: ChatSessionChannelHooks {
    private(set) var startedSessions = 0

    func sessionDidStartNew() async {
        startedSessions += 1
    }
}

/// The app as the primary channel of a mirror-only Telegram companion.
@ChatSessionActor
private final class AppTelegramChannel: TelegramCompanionChannel {
    let primaryChannelDescription = "app"
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

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {}
}

// MARK: - Observing a session

/// The observed session of `Docs/embedding.md`.
private struct ObservedSession: Sendable {
    let controller: ChatSessionController
    let runner: AgentCoreSessionRunner
    let reducer: ChatSessionStateReducer
    let host: ChatPendingRequestHost
}

/// The composition of `Docs/embedding.md`: the reducer is the presenter and
/// the pending-request host is the host. `backendFactory` replaces the
/// production backend for the test.
@MainActor
private func makeObservedSession(
    environment: ChatSessionEnvironment,
    workspaceURL: URL,
    backendFactory: @escaping AgentRuntimeBackendFactory
) -> ObservedSession {
    let sessionID = UUID().uuidString.lowercased()
    let reducer = ChatSessionStateReducer(
        sessionID: sessionID,
        workingDirectory: workspaceURL,
        defaultOrigin: .app
    )
    let host = ChatPendingRequestHost(
        reducer: reducer,
        capabilities: [.toolConsent, .singleChoice, .multipleChoice, .textInput],
        gatesWorkspaceAccess: true
    )
    let authorizer = ChatToolConsentAuthorizer(host: host)
    let runner = ChatSessionRuntimeFactory.makeSessionRunner(
        toolAuthorizationHandler: { await authorizer.authorize($0) },
        backendFactory: backendFactory
    )
    let controller = ChatSessionController(
        sessionID: sessionID,
        managementRuntime: runner,
        environment: environment,
        workingDirectory: workspaceURL,
        presenter: reducer,
        host: host,
        authorizer: authorizer
    )
    return ObservedSession(controller: controller, runner: runner, reducer: reducer, host: host)
}

/// The view model of `Docs/embedding.md`, on the main actor.
@MainActor
private final class SessionViewModel {
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

/// The catch-up of `Docs/embedding.md`.
private func entries(
    after lastSeen: Int,
    epoch: UInt64,
    in snapshot: ChatSessionSnapshot
) -> [ChatTurnEntry]? {
    guard snapshot.epoch == epoch, lastSeen + 1 >= snapshot.firstRetainedSequence else {
        return nil
    }
    return snapshot.log.filter { $0.sequence > lastSeen }
}
