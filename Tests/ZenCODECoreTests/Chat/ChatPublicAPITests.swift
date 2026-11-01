//
//  ChatPublicAPITests.swift
//  ZenCODECoreTests
//
//  The public Chat API as a host app sees it: everything here is reached
//  through `import ZenCODECore` without `@testable`, so a symbol of the
//  composition path that is not public fails the build of this target. The
//  composition is the one of Docs/embedding.md: a `ChatSessionHost` over the
//  runner, a slot per window, and the incarnation the slot runs.
//

import Foundation
import Testing
import ZenCODECore

@Suite(.serialized)
struct ChatPublicAPITests {
    @Test("A host app composes a session, runs a command and a turn, and reads the slot's channel state")
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
            // runner from the public factory, the host over it, then a slot
            // with its first session.
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
            let sessionHost = ChatSessionHost(
                runner: runner,
                environment: environment,
                sleepAssertionReason: "Chat public API test"
            )
            let hooks = AppChannelHooks()
            let slotID = try await sessionHost.openSlot(ChatSlotDescriptor(
                identity: .window("main"),
                workingDirectory: workspace,
                presenter: presenter,
                interaction: .host(host),
                authorizer: authorizer,
                channelHooks: hooks,
                publishesState: false
            ))
            let incarnation = try await sessionHost.newSession(
                in: slotID,
                sessionID: "public-api-\(UUID().uuidString.lowercased())"
            )
            let controller = incarnation.controller
            #expect(await sessionHost.incarnation(in: slotID)?.epoch == incarnation.epoch)

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

            // A turn, under the host's reservation, presented on the app's
            // main-actor presenter.
            await controller.applyInitialAgentSelectionIfNeeded()
            let reservation = try await sessionHost.reservePrompt(in: slotID)
            #expect(await sessionHost.holdsPrompt(reservation))
            let sessionConfiguration = await controller.turnSessionConfiguration(
                for: .normal,
                responseLanguageSection: nil
            )
            let result = try await controller.runTurn(ChatTurnRequest(
                prompt: "Hello",
                sessionConfiguration: sessionConfiguration,
                origin: .app
            ))
            #expect(await sessionHost.releasePrompt(reservation))
            #expect(result.response.text == "COORDINATOR INTERNAL QUESTION")
            #expect(await presenter.assistantContent.joined() == "COORDINATOR INTERNAL QUESTION")
            #expect(await controller.transcript.first?.content == "Hello")

            // A cancel drops a reservation in one step with the fence.
            let cancelled = try await sessionHost.reservePrompt(in: slotID)
            #expect(await sessionHost.cancelPrompt(in: slotID) == cancelled.promptID)
            #expect(await sessionHost.holdsPrompt(cancelled) == false)

            // `/sessions new` on the slot's controller is a new incarnation,
            // with the slot's hooks around it.
            let started = await controller.handleCommandLine("/sessions new", context: [])
            #expect(started.notices.count == 1)
            let next = try #require(await sessionHost.incarnation(in: slotID))
            #expect(next.epoch > incarnation.epoch)
            #expect(next.controller !== controller)
            #expect(await next.controller.transcript.isEmpty)
            #expect(await hooks.startedSessions == 1)

            // The slot's channel state: the app drives the slot until a
            // `/telegram on` hands it to the slot's Telegram channel, which
            // does not exist yet, and every line is admitted meanwhile.
            #expect(await sessionHost.activeChannel(in: slotID) == .primary)
            #expect(await sessionHost.telegramChannel(in: slotID) == nil)
            #expect(await sessionHost.admitLine("hello", in: slotID) == .admitted)
            #expect(await sessionHost.deactivateTelegram(in: slotID) == nil)

            // The mention parser of the shared chat.
            guard case let .route(route) = SharedChatMentionParser.parse(from: "@coordinator ciao") else {
                Issue.record("@coordinator was not parsed as a mention")
                return
            }
            #expect(route.destination == .coordinator)
            #expect(route.text == "ciao")

            await sessionHost.shutdown()
            #expect(await sessionHost.isShutDown)
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
            // The composition of Docs/embedding.md, with a scripted backend: a
            // slot that publishes state and asks with pending requests.
            let session = try await makeObservedSession(
                environment: environment,
                workspaceURL: workspace,
                backendFactory: { _, _ in backend }
            )
            let viewModel = await SessionViewModel(host: session.host)
            let observation = Task { await viewModel.observe(session.reducer) }
            // The slot's incarnations: the current one at once.
            var incarnations = await session.sessionHost.incarnations(in: session.slotID).makeAsyncIterator()
            let current = try #require(await incarnations.next())
            #expect(current?.controller === session.controller)
            #expect(await session.reducer.snapshot.epoch == current?.epoch)

            await session.controller.applyInitialAgentSelectionIfNeeded()
            let reservation = try await session.sessionHost.reservePrompt(in: session.slotID)
            let sessionConfiguration = await session.controller.turnSessionConfiguration(
                for: .normal,
                responseLanguageSection: nil
            )
            _ = try await session.controller.runTurn(ChatTurnRequest(
                prompt: "Hello",
                sessionConfiguration: sessionConfiguration,
                origin: .app
            ))
            #expect(await session.sessionHost.releasePrompt(reservation))

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

            // A request still open when the slot runs a new incarnation is
            // refused, and the new incarnation has a reducer of its own.
            let refused = Task { await session.host.readLine(prompt: "Again?") }
            for await update in await session.reducer.snapshots() where !update.pendingRequests.isEmpty {
                break
            }
            let next = try await session.sessionHost.newSession(in: session.slotID, sessionID: "next")
            #expect(await refused.value == nil)
            #expect(next.reducer !== session.reducer)
            #expect(await next.reducer?.snapshot.epoch == next.epoch)
            #expect(try #require(await incarnations.next())?.epoch == next.epoch)

            observation.cancel()
            await session.sessionHost.shutdown()
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

// MARK: - Observing a session

/// The observed session of `Docs/embedding.md`.
private struct ObservedSession: Sendable {
    let sessionHost: ChatSessionHost
    let slotID: ChatSlotID
    let controller: ChatSessionController
    let reducer: ChatSessionStateReducer
    let host: ChatPendingRequestHost
}

/// The composition of `Docs/embedding.md`: a slot that publishes state and
/// asks with pending requests, so each incarnation has a reducer and a
/// pending-request host. `backendFactory` replaces the production backend for
/// the test.
@ChatSessionActor
private func makeObservedSession(
    environment: ChatSessionEnvironment,
    workspaceURL: URL,
    backendFactory: @escaping AgentRuntimeBackendFactory
) async throws -> ObservedSession {
    let runner = ChatSessionRuntimeFactory.makeSessionRunner(
        toolAuthorizationHandler: nil,
        backendFactory: backendFactory
    )
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
