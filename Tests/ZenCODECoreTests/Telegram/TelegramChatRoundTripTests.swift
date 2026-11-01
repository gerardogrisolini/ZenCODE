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

    /// Records, instead of running, the turns the channel starts for the
    /// prompts it admits: what the terminal's queue used to receive, as the
    /// prompt the turn runs with and its purpose (a `/plan` or `/goal`
    /// completed through its ForceReply runs the command's hidden prompt).
    private static func recordAdmittedPrompts(on terminal: TerminalChat) -> AdmittedPrompts {
        let admitted = AdmittedPrompts()
        terminal.telegramChannel.onRunTurnForTesting = { prompt, _, purpose in
            admitted.append(prompt, purpose: purpose)
        }
        return admitted
    }

    /// The turns the channel started, recorded by
    /// ``recordAdmittedPrompts(on:)``.
    private final class AdmittedPrompts: Sendable {
        private let storage = Mutex<[(prompt: String, purpose: ChatTurnPurpose)]>([])

        func append(_ prompt: String, purpose: ChatTurnPurpose) {
            storage.withLock { $0.append((prompt, purpose)) }
        }

        var prompts: [String] {
            storage.withLock { $0.map(\.prompt) }
        }

        var purposes: [ChatTurnPurpose] {
            storage.withLock { $0.map(\.purpose) }
        }
    }

    /// The prompts `recordAdmittedPrompts(on:)` recorded so far, once every
    /// turn task of the channel, the queued ones included, settled.
    private static func admittedPrompts(
        _ admitted: AdmittedPrompts, on terminal: TerminalChat
    ) async -> [String] {
        await settleTurns(of: terminal)
        return admitted.prompts
    }

    private static func settleTurns(of terminal: TerminalChat) async {
        while let task = terminal.telegramChannel.activeTurnTask {
            await task.value
            await Task.yield()
        }
    }

    /// Runs `body` while the session holds a prompt reservation, so the
    /// channel sees it generating.
    @discardableResult
    private static func whileGenerating<T>(
        _ terminal: TerminalChat, _ body: () async throws -> T
    ) async throws -> T {
        let reservation = try terminal.sessionHost.reservePrompt(in: terminal.terminalSlotID)
        defer { terminal.sessionHost.releasePrompt(reservation) }
        return try await body()
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

    @Test
    func chatCommandOpensPickerDuringGenerationWithCoordinatorAndActiveAgentButtons() async throws {
        let buttons = TelegramChannel.mentionPickerButtons(from: [
            .init(handle: "coordinator", target: .coordinator),
            .init(handle: "all", target: .all),
            .init(handle: "developer", target: .agent(name: "developer"))
        ])
        #expect(buttons.map(\.text) == ["@coordinator", "@developer"])
        #expect(buttons.map(\.callbackData) == [
            "zencode:mention:coordinator", "zencode:mention:developer"
        ])

        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.telegramChannel.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 90
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)
        try await Self.whileGenerating(terminal) {
            await terminal.telegramChannel.handleIncomingMessage(
                Self.message("/chat")
            )
        }
        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        guard case let .inlineKeyboard(rows) = captured.withLock({ $0.first }) else {
            Issue.record("Expected an inline keyboard")
            return
        }
        #expect(rows.flatMap { $0 }.map(\.text) == ["@coordinator"])
    }

    @Test
    func standaloneAtSignIsNoLongerATelegramPickerTrigger() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.telegramChannel.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 90
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(Self.message("@"))

        #expect(captured.withLock { $0.isEmpty })
        #expect(await Self.admittedPrompts(admitted, on: terminal).first == "@")
    }

    @Test
    func callbackCoordinatorCreatesForceReplyCardAndSafeReplyTarget() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        await terminal.telegramChannel.rebindSharedChatRelay(roomID: terminal.sessionID)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.telegramChannel.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 91
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)
        try await Self.whileGenerating(terminal) {
            await terminal.telegramChannel.handleIncomingMessage(
                TerminalTelegramIncomingMessage(
                    chatID: 42, userID: 7, text: nil, voice: nil, messageID: 90,
                    chatTitle: "Gerardo", username: "gerardo", callbackQueryID: "callback-1",
                    callbackData: "zencode:mention:coordinator"
                )
            )
        }
        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        #expect(captured.withLock({ $0 }) == [.forceReply])
        let target = await terminal.telegramChannel.sharedChatRelay.replyTarget(
            forTelegramMessageID: 91, chatID: 42,
            lease: try #require(terminal.telegramChannel.activeRouteLease)
        )
        #expect(target?.senderKind == .coordinator)
        #expect(target?.senderID == AgentSharedChat.coordinatorID(for: terminal.sessionID))
        #expect(target?.replyDestination == .coordinator)
    }

    @Test
    func bareParameterizedMenuCommandUsesForceReplyAndQueuesCompletedCommand() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        terminal.selectedToolKeys.insert("sub-agents")
        try await terminal.sessionRunner.taskOrchestrator.registerSession(
            id: terminal.sessionID,
            workingDirectory: terminal.chatSession.workingDirectory
        )
        let cards = Mutex<[(String, TerminalTelegramReplyMarkup)]>([])
        terminal.telegramChannel.onTelegramMentionPickerMessage = { text, _, markup in
            cards.withLock {
                $0.append((text, markup))
                return 89 + $0.count
            }
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(Self.message("/plan"))

        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        #expect(cards.withLock { $0.map(\.1) } == [.forceReply])
        #expect(cards.withLock { $0.first?.0.contains("/plan") } == true)

        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "route all frontends", voice: nil,
                messageID: 2, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            )
        )

        // The completed `/plan` ran through the controller: the turn it
        // starts is the planning turn of the goal the reply gave.
        await Self.settleTurns(of: terminal)
        #expect(admitted.purposes == [.plan(originalGoal: "route all frontends")])
        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "ordinary follow-up", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            )
        )
        // The receipt was consumed: the follow-up is an ordinary prompt, or
        // the reply the planning discussion waits for.
        #expect(await Self.admittedPrompts(admitted, on: terminal).count == 2)
        #expect(admitted.prompts.last?.contains("ordinary follow-up") == true)

        await terminal.telegramChannel.handleIncomingMessage(
            Self.message("/goal@zencode_bot", messageID: 4)
        )
        #expect(await Self.admittedPrompts(admitted, on: terminal).count == 2)
        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "implement parity", voice: nil,
                messageID: 5, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 91
            )
        )
        #expect(cards.withLock { $0.map(\.1) } == [.forceReply, .forceReply])
        // The reply completed the command and consumed its receipt: the
        // completed `/goal` ran through the controller (which answers it in
        // the chat while the planning discussion is still open).
        await Self.settleTurns(of: terminal)
        #expect(terminal.telegramChannel.commandReplyBindings.isEmpty)
    }

    @Test
    func unknownOrWrongRouteForceReplyDoesNotCaptureOrdinaryPrompt() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let staleKey = TerminalTelegramCommandReplyKey(chatID: 42, receiptMessageID: 90)
        terminal.telegramChannel.commandReplyBindings[staleKey] = TerminalTelegramCommandReplyBinding(
            command: "/goal", chatID: 42,
            lease: .init(key: lease.key, generation: lease.generation + 1)
        )
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "ordinary reply", voice: nil,
                messageID: 2, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            )
        )
        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "unknown reply", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 99
            )
        )

        #expect(await Self.admittedPrompts(admitted, on: terminal) == ["ordinary reply", "unknown reply"])
        #expect(terminal.telegramChannel.commandReplyBindings[staleKey]?.lease != lease)
    }

    @Test
    func commandReplyReceiptsAreScopedByChatAndReplacePriorRouteBinding() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let cards = Mutex<Int>(0)
        terminal.telegramChannel.onTelegramMentionPickerMessage = { _, _, _ in
            cards.withLock { count in
                count += 1
                return 89 + count
            }
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(
            Self.message("/plan")
        )
        await terminal.telegramChannel.handleIncomingMessage(
            Self.message("/goal", messageID: 2)
        )

        #expect(terminal.telegramChannel.commandReplyBindings.count == 1)
        #expect(terminal.telegramChannel.commandReplyBindings[
            .init(chatID: 42, receiptMessageID: 91)
        ]?.command == "/goal")
        terminal.telegramChannel.commandReplyBindings[
            .init(chatID: 43, receiptMessageID: 91)
        ] = TerminalTelegramCommandReplyBinding(command: "/plan", chatID: 43, lease: lease)
        #expect(terminal.telegramChannel.commandReplyBindings.count == 2)

        await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "old reply", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            )
        )
        #expect(await Self.admittedPrompts(admitted, on: terminal).first == "old reply")
    }

    @Test
    func pickerReplyTargetsPreserveCoordinatorAndAgentDestinations() {
        let coordinator = TelegramChannel.mentionPickerReplyTarget(
            destination: .coordinator, roomID: "room", chatID: 42, handle: "coordinator"
        )
        let agent = TelegramChannel.mentionPickerReplyTarget(
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
        terminal.telegramChannel.controlState.isActive = false
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(
            Self.message("questo non deve partire")
        )

        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
    }

    /// A blank message carries no prompt, so it must not occupy a queue slot.
    @Test
    func blankMessageIsNotQueued() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        await terminal.telegramChannel.handleIncomingMessage(
            Self.message("   \n  ")
        )

        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
    }

    /// Busy admission is decided by the serialized TUI runtime, not by a global
    /// bot flag. Work-producing Telegram shapes are rejected on their own
    /// authorized route before they can enqueue, download, transcribe or publish.
    /// Read-only `/status` and recipient-selection callbacks remain allowed.
    @Test
    func busySessionRejectsTelegramWorkBeforeDispatch() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let notices = Mutex<[String]>([])
        let pickerCards = Mutex<Int>(0)
        terminal.telegramChannel.onTelegramSystemMessage = { text, chatID in
            #expect(chatID == 42)
            notices.withLock { $0.append(text) }
            return true
        }
        terminal.telegramChannel.onTelegramMentionPickerMessage = { _, _, _ in
            pickerCards.withLock { $0 += 1 }
            return 91
        }
        let attachment = TerminalTelegramInboundAttachment(
            fileID: "must-not-download", fileUniqueID: nil, kind: .document,
            mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 3
        )
        let work: [TerminalTelegramIncomingMessage] = [
            Self.message("ordinary prompt", messageID: 1),
            Self.message("/status", messageID: 2),
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 3,
                chatTitle: "Gerardo", username: "gerardo", attachment: attachment
            ),
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil,
                voice: TerminalTelegramVoiceAttachment(
                    fileID: "must-not-transcribe", fileUniqueID: nil,
                    duration: 1, mimeType: "audio/ogg", fileSize: 4
                ),
                messageID: 4, chatTitle: "Gerardo", username: "gerardo"
            ),
            Self.message("@coordinator do work", messageID: 5),
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 6,
                chatTitle: "Gerardo", username: "gerardo",
                callbackQueryID: "callback-1", callbackData: "zencode:mention:coordinator"
            ),
        ]
        let admitted = Self.recordAdmittedPrompts(on: terminal)
        for message in work {
            let didQueue = try await Self.whileGenerating(terminal) {
            await terminal.telegramChannel.handleIncomingMessage(
                message
            )
        }
            #expect(!didQueue)
        }

        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        #expect(pickerCards.withLock { $0 } == 1)
        let delivered = notices.withLock { $0 }
        #expect(delivered.count == work.count - 1)
        #expect(delivered.filter {
            $0.contains("busy generating a response in this session")
                && $0.contains("was not queued")
        }.count == work.count - 2)
        #expect(delivered.contains {
            $0.contains("Session active.") && !$0.contains("was not queued")
        })
    }

    @Test
    func busyNoticeDoesNotLeakAcrossUnauthorizedRoutes() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let notices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        _ = try await Self.whileGenerating(terminal) {
            await terminal.telegramChannel.handleIncomingMessage(
                Self.message("foreign", chatID: 99)
            )
        }

        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        #expect(notices.withLock { $0 }.isEmpty)
    }

    @Test
    func busySessionStillAcceptsArtifactConsentCancellation() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let artifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("busy-consent-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: artifactURL)
        defer { try? FileManager.default.removeItem(at: artifactURL) }
        let offerID = try #require(
            await terminal.telegramChannel.controlService.offerArtifactConsent(
                artifact: TerminalTelegramArtifact(
                    fileURL: artifactURL, filename: artifactURL.lastPathComponent
                ),
                chatID: 42, userID: 7, routeLease: lease
            )
        )
        let notices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }
        let admitted = Self.recordAdmittedPrompts(on: terminal)

        let didQueue = try await Self.whileGenerating(terminal) {
            await terminal.telegramChannel.handleIncomingMessage(
                TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 7,
                chatTitle: nil, username: nil, callbackQueryID: "callback-consent",
                callbackData: "zencode:artifact:cancel:\(offerID)"
            )
            )
        }

        #expect(!didQueue)
        #expect(await Self.admittedPrompts(admitted, on: terminal).isEmpty)
        #expect(await terminal.telegramChannel.controlService.pendingConsentArtifact(
            offerID: offerID, chatID: 42
        ) == nil)
        #expect(notices.withLock { $0 } == ["ZenCODE message: file send cancelled."])
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
