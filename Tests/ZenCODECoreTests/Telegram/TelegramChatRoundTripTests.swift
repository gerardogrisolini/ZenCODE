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

@ChatSessionActor
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
        terminal.telegramChannel.linkedChatID = linkedChatID
        terminal.telegramChannel.controlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: "zencode_bot",
            lastError: nil,
            lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        // No message leaves for the Bot API: a test that reads them installs
        // its own seam.
        terminal.telegramChannel.onTelegramSystemMessage = { _, _ in true }
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
            roomID: terminal.sessionID, generation: 1
        )
        await terminal.telegramChannel.router.refresh(
            linkedChatID: 42, ownerUserID: 7, routes: [route]
        )
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: terminal.sessionID), generation: 1
        )
        terminal.telegramChannel.activeRouteLease = lease
        return lease
    }

    /// The outbound channel is bound to the chat that asked: a reply must never
    /// be routed to a chat other than the linked one. The causal round-trip
    /// (`TelegramCausalRoundTripTests`) covers the full path for the linked
    /// chat, including generation and delivery through the control service.
    @Test
    func repliesAreOnlyRoutedToTheLinkedChat() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)

        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) != nil)
        // A route of another chat than the linked one is never sent to: the
        // reporter is built only for a lease, and a lease names the linked
        // chat by construction, so a message of chat 99 resolves no lease.
        let foreign = TerminalTelegramIncomingMessage(
            chatID: 99, userID: 7, text: "hello", voice: nil, messageID: 5,
            chatTitle: nil, username: nil
        )
        #expect(await terminal.telegramChannel.authorizedRoute(for: foreign) == nil)
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

        terminal.telegramChannel.recordSharedChatMessageLease(message.id, lease: lease)
        let routed = terminal.telegramChannel.takeSharedChatLease(for: [message])

        #expect(routed == lease)
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: routed!) != nil)
        #expect(terminal.telegramChannel.takeSharedChatLease(for: [message]) == nil)
    }

    /// Regression for the production ordering: publishing the operator message
    /// wakes the shared-chat coordinator while `ChatSessionActor` is suspended.
    /// The Telegram lease must already be correlated with the bus UUID when
    /// that trigger arrives, and the resulting synthetic response must use the
    /// same fenced outbound channel; a stale generation retires it.
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
        let channel = terminal.telegramChannel
        channel.linkedChatID = 42
        channel.controlState = TerminalTelegramControlState(
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
        let submission = Task { @ChatSessionActor in
            let action = await channel.lineAction(for: "@coordinator answer on Telegram", lease: lease)
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
        let routed = try #require(channel.takeSharedChatLease(for: resolvedTrigger.messages))
        #expect(routed == lease)
        #expect(!submitFinished.withLock { $0 })

        // Only now may the production send call return to the chat actor.
        // Recording the correlation after that return makes the assertion
        // above fail because the real wake-up has already delivered the
        // trigger.
        await backend.releaseSharedChatSend()
        #expect(await submission.value == .handled)

        let delivered = Mutex<[String]>([])
        channel.onDirectTelegramTurnMessage = { payload, chatID in
            #expect(chatID == 42)
            if case let .agentResponse(text) = payload {
                delivered.withLock { $0.append(text) }
            }
            return true
        }
        #expect(channel.makeTurnProgressReporter(for: routed) != nil)
        // The direct final-egress fallback on the same route: the reporter's
        // network closure is covered separately; this seam observes the
        // payload without touching Telegram's public network.
        channel.activeTurnLease = routed
        await channel.retireTurn(outcomePayload: .agentResponse("coordinator reply"), fileChangeSummary: nil)
        #expect(delivered.withLock { $0 } == ["coordinator reply"])
        #expect(try await channel.router.validate(lease) == ())

        // Advancing the route generation retires the route captured above. A
        // replayed/stale synthetic response must not escape to Telegram.
        await channel.router.refresh(
            linkedChatID: 42,
            ownerUserID: 7,
            routes: [AgentTelegramRouteManifest(roomID: sessionID, generation: 2)]
        )
        channel.activeTurnLease = routed
        await channel.retireTurn(outcomePayload: .agentResponse("stale coordinator reply"), fileChangeSummary: nil)
        #expect(delivered.withLock { $0 } == ["coordinator reply"])

        await runner.detachSharedChatObservation(subscription)
        await terminal.sessionHost.shutdown()
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
        terminal.telegramChannel.linkedChatID = 42
        terminal.telegramChannel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active",
            botUsername: "zencode_bot", lastError: nil, lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        terminal.sessionID = sessionID
        let lease = await Self.installRoute(on: terminal)
        let routedErrors = Mutex<[(String, Int64, Int?)]>([])
        terminal.telegramChannel.onTelegramRoutedSystemMessage = { message, chatID, topicID in
            routedErrors.withLock { $0.append((message, chatID, topicID)) }
            return true
        }

        let action = await terminal.telegramChannel.lineAction(for:
            "@coordinator this delivery fails",
            lease: lease
        )
        guard case .handled = action else {
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
        #expect(terminal.telegramChannel.takeSharedChatLease(for: [failedMessage]) == nil)
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
        terminal.telegramChannel.linkedChatID = 42
        terminal.telegramChannel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active",
            botUsername: "zencode_bot", lastError: nil, lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        terminal.sessionID = sessionID
        let staleLease = await Self.installRoute(on: terminal)
        let routedErrors = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramRoutedSystemMessage = { message, _, _ in
            routedErrors.withLock { $0.append(message) }
            return true
        }
        let submission = Task { @ChatSessionActor in
            await terminal.telegramChannel.lineAction(for:
                "@coordinator this route will be retired",
                lease: staleLease
            )
        }
        await backend.waitUntilSharedChatSendStarted()
        await terminal.telegramChannel.router.refresh(
            linkedChatID: 42,
            ownerUserID: 7,
            routes: [AgentTelegramRouteManifest(
                roomID: sessionID, generation: 2
            )]
        )
        await backend.releaseSharedChatSend()
        _ = await submission.value

        #expect(routedErrors.withLock { $0 }.isEmpty)
    }
}

private actor TelegramRuntimeTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
