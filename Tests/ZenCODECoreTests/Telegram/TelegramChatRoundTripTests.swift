//
//  TelegramChatRoundTripTests.swift
//  ZenCODE
//
//  Bidirectional coverage of the Telegram chat flow: an incoming Telegram
//  message must be routed to the shared prompt queue, and the reply of that turn
//  must leave through the ordered outbound channel of the same chat.
//
//  Nothing here touches the network: ingress is driven with the same value the
//  control service yields, and egress is observed through the turn reporter's
//  injected delivery closure.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TelegramChatRoundTripTests {
    private static func makeTerminal(linkedChatID: Int64?) throws -> TerminalChat {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(
                    fileURLWithPath: "/tmp/telegram-round-trip-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            stdinIsTerminal: false
        )
        terminal.telegramLinkedChatID = linkedChatID
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: "zencode_bot",
            lastError: nil,
            lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        return terminal
    }

    private static func message(
        _ text: String,
        chatID: Int64 = 42,
        messageID: Int = 1
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: chatID,
            userID: 7,
            text: text,
            voice: nil,
            messageID: messageID,
            chatTitle: "Gerardo",
            username: "gerardo"
        )
    }

    private static func installRoute(on terminal: TerminalChat) async -> TerminalTelegramRouteLease {
        let route = AgentTelegramRouteManifest(
            chatID: 42, ownerUserID: 7, roomID: terminal.sessionID,
            chatKind: .privateChat, generation: 1
        )
        await terminal.telegramSessionRouter.refresh(routes: [route], groupsEnabled: false)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: terminal.sessionID), generation: 1
        )
        terminal.telegramActiveRouteLease = lease
        return lease
    }

    @Test
    func standaloneMentionOpensPickerWithCoordinatorAndActiveAgentButtons() async throws {
        let buttons = TerminalChat.telegramMentionPickerButtons(from: [
            .init(command: "@coordinator ", summary: "message coordinator"),
            .init(command: "@all ", summary: "broadcast"),
            .init(command: "@developer ", summary: "message agent")
        ])
        #expect(buttons.map(\.text) == ["@coordinator", "@developer"])
        #expect(buttons.map(\.callbackData) == [
            "zencode:mention:coordinator", "zencode:mention:developer"
        ])

        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 90
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()
        await terminal.handleTelegramMessage(
            Self.message("@"), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(queuedPrompts.isEmpty)
        guard case let .inlineKeyboard(rows) = captured.withLock({ $0.first }) else {
            Issue.record("Expected an inline keyboard")
            return
        }
        #expect(rows.flatMap { $0 }.map(\.text) == ["@coordinator"])
    }

    @Test
    func callbackCoordinatorCreatesForceReplyCardAndSafeReplyTarget() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        await terminal.rebindTelegramSharedChatRelay(roomID: terminal.sessionID)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 91
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()
        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 90,
                chatTitle: "Gerardo", username: "gerardo", callbackQueryID: "callback-1",
                callbackData: "zencode:mention:coordinator"
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(queuedPrompts.isEmpty)
        #expect(captured.withLock({ $0 }) == [.forceReply])
        let target = await terminal.telegramSharedChatRelay.replyTarget(
            forTelegramMessageID: 91, chatID: 42,
            lease: try #require(terminal.telegramActiveRouteLease)
        )
        #expect(target?.senderKind == .coordinator)
        #expect(target?.senderID == AgentSharedChat.coordinatorID(for: terminal.sessionID))
        #expect(target?.replyDestination == .coordinator)
    }

    @Test
    func pickerReplyTargetsPreserveCoordinatorAndAgentDestinations() {
        let coordinator = TerminalChat.telegramMentionPickerReplyTarget(
            destination: .coordinator, roomID: "room", chatID: 42, handle: "coordinator"
        )
        let agent = TerminalChat.telegramMentionPickerReplyTarget(
            destination: .direct(["agent-9"]), roomID: "room", chatID: 42, handle: "developer"
        )
        #expect(coordinator.senderKind == .coordinator)
        #expect(coordinator.senderID == AgentSharedChat.coordinatorID(for: "room"))
        #expect(coordinator.replyDestination == .coordinator)
        #expect(agent.senderKind == .agent)
        #expect(agent.senderID == "agent-9")
        #expect(agent.replyDestination == .direct(["agent-9"]))
    }

    /// Ingress is closed while Telegram is off: a message that arrives after the
    /// service was stopped must not become a prompt.
    @Test
    func messageIsIgnoredWhileTelegramIsNotActive() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        terminal.telegramControlState.isActive = false
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("questo non deve partire"),
            queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.isEmpty)
    }

    /// A blank message carries no prompt, so it must not occupy a queue slot.
    @Test
    func blankMessageIsNotQueued() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("   \n  "),
            queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.isEmpty)
    }

    /// The outbound channel is bound to the chat that asked: a reply must never
    /// be routed to a chat other than the linked one. The causal round-trip
    /// (`TelegramCausalRoundTripTests`) covers the full path for the linked
    /// chat, including generation and delivery through the control service.
    @Test
    func repliesAreOnlyRoutedToTheLinkedChat() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)

        #expect(terminal.makeTelegramTurnProgressReporter(
            for: .telegramLease(lease)
        ) != nil)
        #expect(terminal.makeTelegramTurnProgressReporter(
            for: .telegram(chatID: 99)
        ) == nil)
    }

    /// A Telegram live mention enters the shared-chat bus before it causes the
    /// Core coordinator's synthetic turn. That turn must keep the remote origin
    /// or its otherwise visible response is rendered only in the TUI.
    @Test
    func telegramSharedChatTriggerRetainsTelegramResponseOrigin() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let message = AgentSharedChat.Message(
            roomID: terminal.sessionID,
            sender: AgentSharedChat.Participant(
                id: AgentSharedChat.operatorID(for: terminal.sessionID),
                name: "operator",
                kind: .operator
            ),
            recipientIDs: [AgentSharedChat.coordinatorID(for: terminal.sessionID)],
            text: "please respond"
        )

        terminal.recordTelegramSharedChatMessageOrigin(message.id, origin: .telegramLease(lease))
        let origin = terminal.takeTelegramSharedChatOrigin(for: [message])

        #expect(origin == .telegramLease(lease))
        #expect(terminal.makeTelegramTurnProgressReporter(for: origin!) != nil)
        #expect(terminal.takeTelegramSharedChatOrigin(for: [message]) == nil)
    }

    /// Regression for the production ordering: publishing the operator message
    /// wakes the shared-chat coordinator while `TerminalChatActor` is suspended.
    /// The Telegram lease must already be correlated with the bus UUID when that
    /// trigger arrives, and the resulting synthetic response must use the same
    /// fenced outbound channel.
    @Test
    func telegramMentionRoundTripsThroughSharedChatTriggerAndEgress() async throws {
        let sessionID = "telegram-shared-chat-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend(blocksSharedChatSend: true)
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let coreConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        try await runner.createSession(configuration: coreConfiguration)
        _ = try await runner.preloadModel(configuration: coreConfiguration, onEvent: { _ in })

        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        terminal.sessionID = sessionID
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: "zencode_bot",
            lastError: nil,
            lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        let lease = await Self.installRoute(on: terminal)
        let subscription = await runner.attachSharedChatObservation(rootSessionID: sessionID)
        var events = subscription.events.makeAsyncIterator()

        let submitFinished = Mutex(false)
        let submission = Task { @TerminalChatActor in
            let action = await terminal.submittedTelegramLineAction(
                "@coordinator answer on Telegram",
                origin: .telegramLease(lease)
            )
            submitFinished.withLock { $0 = true }
            return action
        }

        var trigger: AgentSharedChatAutoTrigger?
        while trigger == nil, let event = await events.next() {
            if case let .autoTrigger(candidate) = event {
                trigger = candidate
            }
        }
        let resolvedTrigger = try #require(trigger)
        let origin = try #require(
            terminal.takeTelegramSharedChatOrigin(for: resolvedTrigger.messages)
        )
        #expect(origin == .telegramLease(lease))
        #expect(!submitFinished.withLock { $0 })

        // Only now may the production send call return to the TerminalChat actor.
        // Recording the correlation after that return makes the assertion above
        // fail because the real wake-up has already delivered the trigger.
        await backend.releaseSharedChatSend()
        guard case .continueChat = await submission.value else {
            Issue.record("Expected the mention to be routed without a root prompt")
            return
        }

        let delivered = Mutex<[String]>([])
        terminal.onDirectTelegramTurnMessage = { payload, chatID in
            #expect(chatID == 42)
            if case let .agentResponse(text) = payload {
                delivered.withLock { $0.append(text) }
            }
            return true
        }
        #expect(terminal.makeTelegramTurnProgressReporter(for: origin) != nil)
        // Exercise the direct final-egress fallback with the same origin. The
        // reporter's network closure is covered separately; this seam observes
        // the payload without touching Telegram's public network.
        terminal.activeTelegramTurnOrigin = origin
        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("coordinator reply")
        )
        #expect(delivered.withLock { $0 } == ["coordinator reply"])
        #expect(try await terminal.telegramSessionRouter.validate(lease) == ())

        // Advancing the route generation retires the origin captured above. A
        // replayed/stale synthetic response must not escape to Telegram.
        await terminal.telegramSessionRouter.refresh(
            routes: [AgentTelegramRouteManifest(
                chatID: 42, ownerUserID: 7, roomID: sessionID,
                chatKind: .privateChat, generation: 2
            )],
            groupsEnabled: false
        )
        terminal.activeTelegramTurnOrigin = origin
        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("stale coordinator reply")
        )
        #expect(delivered.withLock { $0 } == ["coordinator reply"])

        await runner.detachSharedChatObservation(subscription)
    }

    @Test
    func failedTelegramMentionReportsOnceOnItsValidatedRouteAndClearsCorrelation() async throws {
        let sessionID = "telegram-shared-chat-failure-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend(failsSharedChatSend: true)
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID, modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })

        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active",
            botUsername: "zencode_bot", lastError: nil, lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        terminal.sessionID = sessionID
        let lease = await Self.installRoute(on: terminal)
        let routedErrors = Mutex<[(String, Int64, Int?)]>([])
        terminal.onTelegramRoutedSystemMessage = { message, chatID, topicID in
            routedErrors.withLock { $0.append((message, chatID, topicID)) }
            return true
        }

        let action = await terminal.submittedTelegramLineAction(
            "@coordinator this delivery fails",
            origin: .telegramLease(lease)
        )
        guard case .continueChat = action else {
            Issue.record("Expected failed mention delivery to be handled inline")
            return
        }
        let errors = routedErrors.withLock { $0 }
        #expect(errors.count == 1)
        #expect(errors.first?.0.hasPrefix("ZenCODE message: ") == true)
        #expect(errors.first?.1 == 42)
        #expect(errors.first?.2 == nil)

        let messageID = try #require(await backend.recordedSharedChatMessageID())
        let failedMessage = AgentSharedChat.Message(
            id: messageID,
            roomID: sessionID,
            sender: .init(
                id: AgentSharedChat.operatorID(for: sessionID),
                name: "operator", kind: .operator
            ),
            recipientIDs: [AgentSharedChat.coordinatorID(for: sessionID)],
            text: "this delivery fails"
        )
        #expect(terminal.takeTelegramSharedChatOrigin(for: [failedMessage]) == nil)
    }

    @Test
    func failedTelegramMentionDoesNotReportThroughAStaleGeneration() async throws {
        let sessionID = "telegram-shared-chat-stale-failure-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend(
            blocksSharedChatSend: true,
            failsSharedChatSend: true
        )
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID, modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })

        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active",
            botUsername: "zencode_bot", lastError: nil, lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        terminal.sessionID = sessionID
        let staleLease = await Self.installRoute(on: terminal)
        let routedErrors = Mutex<[String]>([])
        terminal.onTelegramRoutedSystemMessage = { message, _, _ in
            routedErrors.withLock { $0.append(message) }
            return true
        }
        let submission = Task { @TerminalChatActor in
            await terminal.submittedTelegramLineAction(
                "@coordinator this route will be retired",
                origin: .telegramLease(staleLease)
            )
        }
        await backend.waitUntilSharedChatSendStarted()
        await terminal.telegramSessionRouter.refresh(
            routes: [AgentTelegramRouteManifest(
                chatID: 42, ownerUserID: 7, roomID: sessionID,
                chatKind: .privateChat, generation: 2
            )],
            groupsEnabled: false
        )
        await backend.releaseSharedChatSend()
        _ = await submission.value

        #expect(routedErrors.withLock { $0 }.isEmpty)
    }
}
