//
//  TelegramChannelTests.swift
//  ZenCODE
//
//  The Telegram channel of a slot as its exclusive channel: the handover of
//  the slot (`/telegram on`) and the way back (`/telegram off`) with the
//  catch-up by sequence, the catch-up after a new session started while
//  Telegram drove the slot, the dormant primary channel and the lines it may
//  still run, the pending requests asked again on the channel that drives
//  the slot, a turn that moves between the channels while it runs with its
//  streaming block, the turns the chat starts through the host, the line
//  still answered at `/telegram off` that starts nothing, the channel's
//  queue resumed when a turn it did not start ends, two concurrent
//  activations, the reducer of a slot that publishes state, and the link
//  that survives a new session. Telegram is a scripted Bot API; every test
//  runs in a UUID-named support directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// A runtime backend whose turns follow a script per prompt: streamed
/// content, a pause until the test releases it, a gated tool asked through
/// the runner's authorization, and the reply.
private actor TelegramChannelTestBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        case content(String)
        case pause
        case askPermission(command: String)
    }

    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    private(set) var permissionDecisions: [Bool] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedCount = 0
    private var releasedCount = 0
    private let authorization = Mutex<AgentToolAuthorizationHandler?>(nil)

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] configuration, _ in
            authorization.withLock { $0 = configuration.toolAuthorizationHandler }
            return self
        }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    /// Whether a turn waits at a `.pause` step.
    var isPaused: Bool {
        pausedCount > releasedCount
    }

    /// Lets the turn waiting at a `.pause` step go on.
    func release() {
        releasedCount += 1
        if !pauseWaiters.isEmpty {
            pauseWaiters.removeFirst().resume()
        }
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.content("Answer to: \(prompt)")] : scripts.removeFirst()
        var text = ""
        for (index, step) in steps.enumerated() {
            switch step {
            case let .content(content):
                text += content
                await onEvent(.content(content))
            case .pause:
                pausedCount += 1
                if releasedCount < pausedCount {
                    await withCheckedContinuation { pauseWaiters.append($0) }
                }
            case let .askPermission(command):
                let handler = authorization.withLock { $0 }
                let request = AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: "exec-\(index)",
                    toolName: "local.exec",
                    title: "Run \(command)",
                    kind: "execute",
                    command: command,
                    workingDirectory: sessions[sessionID]?.workingDirectoryPath ?? "/tmp"
                )
                let approved = await handler?(request) ?? false
                permissionDecisions.append(approved)
            }
        }
        if var snapshot = sessions[sessionID] {
            snapshot = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID, modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt, cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: text),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
            sessions[sessionID] = snapshot
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

/// The primary channel of the tests: a presenter that records the turn
/// output it receives and presents the endings of the turns, and an
/// interaction host that records what it is asked and answers what the test
/// scripted.
@ChatSessionActor
private final class PrimaryChannelPresenter: ChatSlotChannelPresenter {
    private(set) var assistantText = ""
    private(set) var movedTurns: [ChatMovedTurn] = []
    private(set) var endings: [ChatTurnEnding] = []
    private(set) var turnStarts = 0

    init() {}

    func turnWillStart(_ request: ChatTurnRequest) async {
        turnStarts += 1
    }

    func presentAssistantContent(_ content: String) async {
        assistantText += content
    }

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {
        movedTurns.append(turn)
    }

    func presentTurnEnding(_ ending: ChatTurnEnding) async {
        endings.append(ending)
    }
}

@ChatSessionActor
@Suite("Telegram channel", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let backend = TelegramChannelTestBackend()
        let transport: ACPTelegramScriptedTransport

        init(root: URL, hasTopicsEnabled: Bool = false, createdTopicIDs: [Int] = []) throws {
            self.root = root
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            transport = ACPTelegramScriptedTransport(
                botID: ACPTelegramTestSupport.uniqueBotID(),
                hasTopicsEnabled: hasTopicsEnabled,
                createdTopicIDs: createdTopicIDs
            )
        }

        /// A host over a runner on ``backend``, whose default consent is the
        /// slot authorizer's, as the terminal wires it; the host's Telegram
        /// channels use ``transport``.
        @ChatSessionActor
        func makeHost(authorizer: ChatToolConsentAuthorizer) throws -> ChatSessionHost {
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: workspace
            )
            let runner = AgentCoreSessionRunner(
                defaultToolAuthorizationHandler: { request in await authorizer.authorize(request) },
                backendFactory: backend.factory,
                taskGraphStore: nil
            )
            let host = ChatSessionHost(
                runner: runner,
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE Telegram channel test"
            )
            let transport = transport
            host.telegramTransportFactory = { transport }
            return host
        }
    }

    /// A slot of the primary channel with its first session: the presenter
    /// and the scripted host of the tests, publishing no state (the terminal's
    /// case) unless `publishesState`.
    @ChatSessionActor
    private struct Slot {
        let host: ChatSessionHost
        let id: ChatSlotID
        let presenter: PrimaryChannelPresenter
        let interactionHost: ScriptedChatInteractionHost
        let authorizer: ChatToolConsentAuthorizer

        var incarnation: ChatSessionIncarnation {
            host.incarnation(in: id)!
        }

        var controller: ChatSessionController {
            incarnation.controller
        }
    }

    @ChatSessionActor
    private static func openSlot(
        in environment: Environment,
        decisions: [ChatConsentDecision?] = [],
        pendingRequests: Bool = false
    ) throws -> Slot {
        let presenter = PrimaryChannelPresenter()
        let interactionHost = ScriptedChatInteractionHost(
            capabilities: [.toolConsent, .textInput], decisions: decisions
        )
        let authorizer = ChatToolConsentAuthorizer(host: interactionHost)
        let host = try environment.makeHost(authorizer: authorizer)
        var descriptor = ChatSlotDescriptor(
            identity: .window("telegram-channel-test"),
            workingDirectory: environment.workspace,
            presenter: presenter,
            interaction: pendingRequests
                ? .pendingRequests(capabilities: [.toolConsent, .textInput])
                : .host(interactionHost),
            authorizer: authorizer,
            defaultOrigin: .app,
            publishesState: pendingRequests
        )
        descriptor.presentTurnEnding = { ending in
            await presenter.presentTurnEnding(ending)
        }
        let incarnation = try host.openSlot(descriptor, sessionID: "channel-test-\(UUID().uuidString)")
        _ = incarnation
        return Slot(host: host, id: incarnation.slotID, presenter: presenter,
                    interactionHost: interactionHost, authorizer: authorizer)
    }

    /// Runs `body` on the chat actor in a UUID support directory holding the
    /// paired Telegram settings, with a fresh environment.
    private nonisolated func withEnvironment(
        hasTopicsEnabled: Bool = false,
        createdTopicIDs: [Int] = [],
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let environment = try Environment(
                root: root, hasTopicsEnabled: hasTopicsEnabled, createdTopicIDs: createdTopicIDs
            )
            try await Task(name: "ZenCODE.Tests.telegram-channel") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    /// Runs one turn of the primary channel on the slot, as a channel does:
    /// reserved in the host, run on the controller with the slot's presenter,
    /// its ending presented by whoever drives the slot when it ends.
    private static func runPrimaryTurn(_ prompt: String, on slot: Slot) async throws {
        let reservation = try slot.host.reservePrompt(in: slot.id)
        let controller = slot.controller
        let request = ChatTurnRequest(
            prompt: prompt,
            sessionConfiguration: await controller.turnSessionConfiguration(
                for: .normal, responseLanguageSection: nil
            )
        )
        let ending: ChatTurnEnding
        do {
            ending = ChatTurnEnding(result: try await controller.runTurn(request))
        } catch {
            ending = ChatTurnEnding(error: error)
        }
        slot.host.releasePrompt(reservation)
        await slot.host.presentTurnEnding(ending, in: slot.id)
    }

    private static func waitUntil(_ condition: @ChatSessionActor () async -> Bool) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// The transcript of `entries` as "origin: text" lines.
    private static func lines(of entries: [ChatTurnEntry]) -> [String] {
        entries.compactMap { entry in
            switch entry.kind {
            case let .userPrompt(text, _, origin):
                "\(origin): \(text)"
            case let .assistantText(text):
                "assistant: \(text)"
            default:
                nil
            }
        }
    }

    // MARK: - Handover and catch-up

    /// `/telegram on` hands the slot to the channel: the incarnation gets a
    /// reducer seeded with the transcript, the chat receives the context,
    /// the primary channel is dormant, and a prompt from the chat runs
    /// through the host with the origin `.telegram`, presented in the chat
    /// only. `/telegram off` takes the slot back with exactly the entries
    /// whose sequence follows the last one the primary channel saw, and
    /// detaches the reducer it created.
    @Test
    nonisolated func handoverSwitchesTheSlotAndTakesItBackWithTheCatchUpBySequence() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment)
            try await Self.runPrimaryTurn("first question", on: slot)
            #expect(slot.presenter.assistantText == "Answer to: first question")
            #expect(slot.presenter.endings.count == 1)
            #expect(slot.incarnation.reducer == nil)

            try await slot.host.activateTelegram(in: slot.id)
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            #expect(channel.isActive)
            #expect(slot.host.activeChannel(in: slot.id) == .telegram)
            let reducer = try #require(slot.incarnation.reducer)
            #expect(Self.lines(of: reducer.snapshot.transcript)
                == ["unknown: first question", "assistant: Answer to: first question"])
            #expect(slot.controller.observers.count == 1)
            // The context: the last transcript entries, compact.
            let context = try #require(await environment.transport.sentTexts.last)
            #expect(context.contains("Last 2 messages of the session:"))
            #expect(context.contains("👤 first question"))
            #expect(context.contains("🤖 Answer to: first question"))
            let lastSeen = try #require(reducer.snapshot.log.last?.sequence)

            // The primary channel is dormant.
            #expect(slot.host.admitLine("hello", in: slot.id) == .refused(ChatSlotAdmission.dormantRefusalText))
            #expect(slot.host.admitLine("/telegram off", in: slot.id) == .admitted)

            // A prompt from the chat runs through the host.
            let sentBefore = await environment.transport.sentMessages.count
            try await environment.transport.deliver("second question")
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await environment.backend.prompts == ["first question", "second question"])
            let completion = try #require(await environment.transport.sentTexts.dropFirst(sentBefore)
                .first { $0.contains("ZenCODE completed") })
            #expect(completion.contains("Answer to: second question"))
            // Presented in the chat only: the primary presenter saw nothing more.
            #expect(slot.presenter.assistantText == "Answer to: first question")
            #expect(slot.presenter.endings.count == 1)
            #expect(await Self.waitUntil { slot.incarnation.activePromptID == nil })

            // The way back: the catch-up is what followed `lastSeen`.
            let catchUp = try #require(await slot.host.deactivateTelegram(in: slot.id))
            #expect(slot.host.activeChannel(in: slot.id) == .primary)
            #expect(!channel.isActive)
            #expect(!catchUp.incarnationChanged)
            #expect(!catchUp.omittedOlderEntries)
            #expect(catchUp.entries.allSatisfy { $0.sequence > lastSeen })
            #expect(Self.lines(of: catchUp.entries)
                == ["telegram: second question", "assistant: Answer to: second question"])
            #expect(catchUp.liveAssistantText.isEmpty)
            #expect(slot.incarnation.reducer == nil)
            #expect(slot.controller.observers.isEmpty)
            // Nothing to catch up with, and the link only stops, the next time.
            #expect(await slot.host.deactivateTelegram(in: slot.id) == nil)
            #expect(slot.host.admitLine("hello", in: slot.id) == .admitted)
            await slot.host.shutdown()
        }
    }

    // MARK: - Dormant channel

    /// While Telegram drives the slot the primary channel runs only the lines
    /// that take it back; the refusal names `/telegram off`.
    @Test
    nonisolated func theDormantPrimaryChannelRunsOnlyTheLinesThatTakeTheSlotBack() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment)
            for line in ["hello", "/help", "/sessions new", "@coordinator hi", "/telegram on"] {
                #expect(slot.host.admitLine(line, in: slot.id) == .admitted)
            }
            try await slot.host.activateTelegram(in: slot.id)
            for line in ["/telegram", "/telegram off", "/exit", " /TELEGRAM OFF "] {
                #expect(slot.host.admitLine(line, in: slot.id) == .admitted, "\(line)")
            }
            for line in ["hello", "/help", "/sessions new", "@coordinator hi", "/telegram on", "/telegram status", "/telegram foo"] {
                #expect(slot.host.admitLine(line, in: slot.id)
                    == .refused("ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.\n"), "\(line)")
            }
            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(slot.host.admitLine("hello", in: slot.id) == .admitted)
            await slot.host.shutdown()
        }
    }

    // MARK: - Pending requests

    /// A question the controller asked is asked again on the channel that
    /// drives the slot when the slot changes hands, in both directions: a
    /// line asked of the app's pending requests moves to the chat, where the
    /// next message answers it; a line asked in the chat moves back to the
    /// pending requests, where the app answers it.
    @Test
    nonisolated func pendingRequestsMoveToTheChannelThatDrivesTheSlot() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment, pendingRequests: true)
            let reducer = try #require(slot.incarnation.reducer)
            let controllerHost = slot.controller.host

            // Asked of the app, then handed to the chat.
            let firstAnswer = Task { @ChatSessionActor in
                await controllerHost.readLine(prompt: "Your name?")
            }
            #expect(await Self.waitUntil { reducer.snapshot.pendingRequests.count == 1 })
            try await slot.host.activateTelegram(in: slot.id)
            #expect(await Self.waitUntil { reducer.snapshot.pendingRequests.isEmpty })
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.hasPrefix("Your name?") }
            })
            try await environment.transport.deliver("Alice")
            #expect(await firstAnswer.value == "Alice")

            // Asked in the chat, then handed back to the app.
            let secondAnswer = Task { @ChatSessionActor in
                await controllerHost.readLine(prompt: "Your city?")
            }
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.hasPrefix("Your city?") }
            })
            #expect(reducer.snapshot.pendingRequests.isEmpty)
            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(await Self.waitUntil { reducer.snapshot.pendingRequests.count == 1 })
            let request = try #require(reducer.snapshot.pendingRequests.first)
            guard case .readLine(let prompt) = request.kind else {
                Issue.record("Expected the line request, got \(request.kind)")
                return
            }
            #expect(prompt == "Your city?")
            #expect(slot.incarnation.pendingRequestHost?.resolve(request.id, answer: .text("Rome")) == true)
            #expect(await secondAnswer.value == "Rome")
            await slot.host.shutdown()
        }
    }

    // MARK: - Turns that move between the channels

    /// `/telegram off` in the middle of a turn from the chat: the consent the
    /// turn asked in the chat is withdrawn there and asked again on the
    /// primary channel, which decides it; the block streaming so far is in
    /// the catch-up; the rest of the turn and its ending are presented by
    /// the primary channel.
    @Test
    nonisolated func aTurnFromTelegramMovesToThePrimaryChannelWithItsPendingConsent() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment, decisions: [.allowOnce])
            try await slot.host.activateTelegram(in: slot.id)
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            await environment.backend.enqueue([
                .content("Hello "),
                .askPermission(command: "echo hi"),
                .content("world"),
            ])

            try await environment.transport.deliver("run it")
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("Request ID: ") }
            })
            #expect(await slot.interactionHost.requests.isEmpty)

            let catchUp = try #require(await slot.host.deactivateTelegram(in: slot.id))
            #expect(Self.lines(of: catchUp.entries) == ["telegram: run it"])
            #expect(catchUp.liveAssistantText == "Hello ")
            #expect(slot.presenter.movedTurns.count == 1)
            #expect(slot.presenter.movedTurns.first?.liveAssistantText == "Hello ")

            // The consent moved: the primary host decided it, the chat's
            // request was withdrawn, and the turn went on.
            #expect(await Self.waitUntil { await !slot.interactionHost.requests.isEmpty })
            #expect(await Self.waitUntil { slot.presenter.endings.count == 1 })
            #expect(await environment.backend.permissionDecisions == [true])
            #expect(slot.presenter.assistantText == "world")
            guard case let .completed(response)? = slot.presenter.endings.first?.outcome else {
                Issue.record("Expected a completed ending")
                return
            }
            #expect(response.text == "Hello world")
            #expect(!channel.isActive)
            #expect(await Self.waitUntil { slot.incarnation.activePromptID == nil })
            await slot.host.shutdown()
        }
    }

    /// `/telegram on` in the middle of a turn of the primary channel: the
    /// chat receives the block streaming so far as context and the rest of
    /// the turn, with its ending, as the turn moved onto the channel.
    @Test
    nonisolated func aPrimaryTurnMovesToTelegramWithItsStreamingBlock() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment)
            await environment.backend.enqueue([
                .content("Half "),
                .pause,
                .content("done"),
            ])
            let turn = Task { @ChatSessionActor in
                try await Self.runPrimaryTurn("long one", on: slot)
            }
            #expect(await Self.waitUntil { await environment.backend.isPaused })
            #expect(slot.presenter.assistantText == "Half ")

            try await slot.host.activateTelegram(in: slot.id)
            let context = try #require(await environment.transport.sentTexts.last)
            #expect(context.contains("👤 long one"))
            #expect(context.contains("🤖 (in progress) Half"))

            await environment.backend.release()
            try await turn.value
            // The ending went to the chat, not to the primary presenter.
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(slot.presenter.endings.isEmpty)
            #expect(slot.presenter.assistantText == "Half ")
            // The reducer the handover created saw the turn from its move: its
            // prompt, which the primary channel had seen (so it is before the
            // last seen sequence), and the whole block, the part streamed
            // before the move included, which it had not.
            let catchUp = try #require(await slot.host.deactivateTelegram(in: slot.id))
            #expect(Self.lines(of: catchUp.entries) == ["assistant: Half done"])
            #expect(slot.incarnation.reducer == nil)
            await slot.host.shutdown()
        }
    }

    // MARK: - After `/telegram off`, and the channel's queue

    /// The host refuses a turn of the channel while the channel does not
    /// drive the slot, before anything is reserved or presented.
    @Test
    nonisolated func theHostRefusesATelegramTurnWhileTheChannelDoesNotDriveTheSlot() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment)
            _ = try #require(slot.host.telegramChannelCreatingIfNeeded(in: slot.id))
            do {
                try await slot.host.runTelegramTurn(in: slot.id, prompt: "not now")
                Issue.record("The host ran a turn of a channel that does not drive the slot")
            } catch let refusal as ChatTelegramTurnRefusal {
                #expect(refusal == .channelDoesNotDriveSlot)
            } catch {
                Issue.record("Expected the refusal, got \(error)")
            }
            #expect(slot.incarnation.activePromptID == nil)
            #expect(slot.presenter.endings.isEmpty)
            #expect(await environment.backend.prompts.isEmpty)
            await slot.host.shutdown()
        }
    }

    // MARK: - Consent remembered

    /// An *Always* given in the chat is recorded in the consent authorizer
    /// of the slot, which every channel of the slot asks: it still covers
    /// the session after `/telegram off`, where the primary channel is not
    /// asked again.
    @Test
    nonisolated func anAlwaysGivenInTheChatCoversTheSessionAfterTelegramOff() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment, decisions: [.denyOnce])
            try await slot.host.activateTelegram(in: slot.id)
            await environment.backend.enqueue([.askPermission(command: "echo hi"), .content("ran")])

            try await environment.transport.deliver("run it")
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("Request ID: ") }
            })
            let card = try #require(await environment.transport.sentTexts.last { $0.contains("Request ID: ") })
            let requestID = String(try #require(card.components(separatedBy: "Request ID: ").last)
                .prefix { !$0.isWhitespace })
            try await environment.transport.deliver("/always \(requestID)")
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await environment.backend.permissionDecisions == [true])
            #expect(await Self.waitUntil { slot.incarnation.activePromptID == nil })
            let request = AgentToolAuthorizationRequest(
                sessionID: slot.incarnation.sessionID, toolCallID: "exec-later", toolName: "local.exec",
                title: "Run echo hi", kind: "execute", command: "echo hi",
                workingDirectory: environment.workspace.path
            )
            #expect(await slot.authorizer.isAlreadyAuthorized(request))

            // Back on the primary channel the same command runs unasked: the
            // scripted host would deny it.
            _ = await slot.host.deactivateTelegram(in: slot.id)
            await environment.backend.enqueue([.askPermission(command: "echo hi"), .content("again")])
            try await Self.runPrimaryTurn("run it again", on: slot)
            #expect(await environment.backend.permissionDecisions == [true, true])
            #expect(await slot.interactionHost.requests.isEmpty)
            await slot.host.shutdown()
        }
    }

    // MARK: - A slot that publishes state

    /// A slot that publishes state (an app) keeps its own reducer through the
    /// handover: the turns Telegram runs are recorded there (the prompt with
    /// the origin `.telegram`, the blocks, the phases, all in one turn), the
    /// catch-up is read from it, and after `/telegram off` it is neither
    /// detached nor replaced, so the turns of the app follow in the same log.
    @Test
    nonisolated func aSlotThatPublishesStateRecordsTheTelegramTurnsAndKeepsItsReducer() async throws {
        try await withEnvironment { environment in
            let slot = try Self.openSlot(in: environment, pendingRequests: true)
            let reducer = try #require(slot.incarnation.reducer)
            try await Self.runPrimaryTurn("from the app", on: slot)
            let lastSeen = try #require(reducer.snapshot.log.last?.sequence)

            try await slot.host.activateTelegram(in: slot.id)
            #expect(slot.incarnation.reducer === reducer)
            #expect(slot.controller.observers.count == 1)
            await environment.backend.enqueue([.content("Telegram "), .content("answer")])
            try await environment.transport.deliver("from the chat")
            #expect(await Self.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await Self.waitUntil {
                slot.incarnation.activePromptID == nil && reducer.snapshot.turn.phase == .finishing
            })

            let fromTelegram = reducer.snapshot.log.filter { $0.sequence > lastSeen }
            #expect(Self.lines(of: fromTelegram) == ["telegram: from the chat", "assistant: Telegram answer"])
            let phases = fromTelegram.compactMap { entry -> ChatTurnPhase? in
                guard case let .turnPhase(phase) = entry.kind else { return nil }
                return phase
            }
            #expect(phases.first == .started)
            #expect(phases.last == .finishing)
            #expect(phases.contains(.modelReturned))
            #expect(Set(fromTelegram.map(\.turnID)).count == 1)
            #expect(fromTelegram.first?.turnID != nil)
            #expect(!reducer.snapshot.turn.isGenerating)

            let catchUp = try #require(await slot.host.deactivateTelegram(in: slot.id))
            #expect(!catchUp.incarnationChanged)
            #expect(!catchUp.omittedOlderEntries)
            #expect(catchUp.entries == fromTelegram)
            // Neither detached nor replaced.
            #expect(slot.incarnation.reducer === reducer)
            #expect(slot.controller.observers.count == 1)
            #expect(slot.controller.observers.first === reducer)

            // The turns of the app follow in the same, coherent log.
            try await Self.runPrimaryTurn("back on the app", on: slot)
            let lastFromTelegram = try #require(fromTelegram.last?.sequence)
            #expect(Self.lines(of: reducer.snapshot.log.filter { $0.sequence > lastFromTelegram })
                == ["app: back on the app", "assistant: Answer to: back on the app"])
            #expect(Self.lines(of: reducer.snapshot.transcript) == [
                "app: from the app", "assistant: Answer to: from the app",
                "telegram: from the chat", "assistant: Telegram answer",
                "app: back on the app", "assistant: Answer to: back on the app",
            ])
            let sequences = reducer.snapshot.log.map(\.sequence)
            #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
            #expect(reducer.snapshot.firstRetainedSequence == 1)
            #expect(reducer.snapshot.summary.activeChannel == .app)
            await slot.host.shutdown()
        }
    }
}
