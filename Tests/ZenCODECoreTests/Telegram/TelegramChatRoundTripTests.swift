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
            roomID: terminal.sessionID, generation: 1
        )
        await terminal.telegramSessionRouter.refresh(
            linkedChatID: 42, ownerUserID: 7, routes: [route]
        )
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: terminal.sessionID), generation: 1
        )
        terminal.telegramActiveRouteLease = lease
        return lease
    }

    @Test
    func chatCommandOpensPickerDuringGenerationWithCoordinatorAndActiveAgentButtons() async throws {
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
        _ = await Self.installRoute(on: terminal)
        let captured = Mutex<[TerminalTelegramReplyMarkup]>([])
        terminal.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 90
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()
        await terminal.handleTelegramMessage(
            Self.message("/chat"), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry(),
            isSessionGenerating: true
        )
        #expect(queuedPrompts.isEmpty)
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
        terminal.onTelegramMentionPickerMessage = { _, _, markup in
            captured.withLock { $0.append(markup) }
            return 90
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("@"), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(captured.withLock { $0.isEmpty })
        #expect(queuedPrompts.dequeue()?.text == "@")
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
            transcriptions: TerminalVoiceTranscriptionRegistry(), isSessionGenerating: true
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
    func bareParameterizedMenuCommandUsesForceReplyAndQueuesCompletedCommand() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let cards = Mutex<[(String, TerminalTelegramReplyMarkup)]>([])
        terminal.onTelegramMentionPickerMessage = { text, _, markup in
            cards.withLock {
                $0.append((text, markup))
                return 89 + $0.count
            }
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("/plan"), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.isEmpty)
        #expect(cards.withLock { $0.map(\.1) } == [.forceReply])
        #expect(cards.withLock { $0.first?.0.contains("/plan") } == true)

        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "route all frontends", voice: nil,
                messageID: 2, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.dequeue()?.text == "/plan route all frontends")
        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "ordinary follow-up", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(queuedPrompts.dequeue()?.text == "ordinary follow-up")

        await terminal.handleTelegramMessage(
            Self.message("/goal@zencode_bot", messageID: 4), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(queuedPrompts.isEmpty)
        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "implement parity", voice: nil,
                messageID: 5, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 91
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(cards.withLock { $0.map(\.1) } == [.forceReply, .forceReply])
        #expect(queuedPrompts.dequeue()?.text == "/goal implement parity")
    }

    @Test
    func unknownOrWrongRouteForceReplyDoesNotCaptureOrdinaryPrompt() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let staleKey = TerminalTelegramCommandReplyKey(chatID: 42, receiptMessageID: 90)
        terminal.telegramCommandReplyBindings[staleKey] = TerminalTelegramCommandReplyBinding(
            command: "/goal", chatID: 42,
            lease: .init(key: lease.key, generation: lease.generation + 1)
        )
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "ordinary reply", voice: nil,
                messageID: 2, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "unknown reply", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 99
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.dequeue()?.text == "ordinary reply")
        #expect(queuedPrompts.dequeue()?.text == "unknown reply")
        #expect(terminal.telegramCommandReplyBindings[staleKey]?.lease != lease)
    }

    @Test
    func commandReplyReceiptsAreScopedByChatAndReplacePriorRouteBinding() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        let lease = await Self.installRoute(on: terminal)
        let cards = Mutex<Int>(0)
        terminal.onTelegramMentionPickerMessage = { _, _, _ in
            cards.withLock { count in
                count += 1
                return 89 + count
            }
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("/plan"), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        await terminal.handleTelegramMessage(
            Self.message("/goal", messageID: 2), queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(terminal.telegramCommandReplyBindings.count == 1)
        #expect(terminal.telegramCommandReplyBindings[
            .init(chatID: 42, receiptMessageID: 91)
        ]?.command == "/goal")
        terminal.telegramCommandReplyBindings[
            .init(chatID: 43, receiptMessageID: 91)
        ] = TerminalTelegramCommandReplyBinding(command: "/plan", chatID: 43, lease: lease)
        #expect(terminal.telegramCommandReplyBindings.count == 2)

        await terminal.handleTelegramMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "old reply", voice: nil,
                messageID: 3, chatTitle: "Gerardo", username: "gerardo", replyToMessageID: 90
            ), queuedPrompts: &queuedPrompts, eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )
        #expect(queuedPrompts.dequeue()?.text == "old reply")
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
        terminal.onTelegramSystemMessage = { text, chatID in
            #expect(chatID == 42)
            notices.withLock { $0.append(text) }
            return true
        }
        terminal.onTelegramMentionPickerMessage = { _, _, _ in
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
        var queuedPrompts = TerminalQueuedPromptBuffer()
        for message in work {
            let didQueue = await terminal.handleTelegramRuntimeMessage(
                message, eventQueue: TerminalChatEventQueue(),
                queuedPrompts: &queuedPrompts,
                transcriptions: TerminalVoiceTranscriptionRegistry(),
                isSessionGenerating: true
            )
            #expect(!didQueue)
        }

        #expect(queuedPrompts.isEmpty)
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

    /// Drives the production panel FIFO: a local turn enters generation, three
    /// Telegram work shapes arrive while that state is live, and cancellation
    /// completion clears the gate. The same call-site spies are then exercised
    /// positively, proving that the busy assertions are not disconnected mocks.
    @Test
    func interactiveRuntimeRejectsTelegramEffectsUntilGenerationCompletes() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let queue = TerminalChatEventQueue()
        terminal.interactiveRuntimeEventQueueForTesting = queue
        terminal.bypassInteractivePanelInputForTesting = true

        let generationGate = TelegramRuntimeTestGate()
        terminal.onGenerateResponseForTesting = { _ in
            await generationGate.enterAndWait()
            throw CancellationError()
        }
        let (states, stateContinuation) = AsyncStream.makeStream(of: Bool.self)
        terminal.onInteractiveGenerationStateForTesting = { state in
            stateContinuation.yield(state)
        }
        let (notices, noticeContinuation) = AsyncStream.makeStream(of: String.self)
        terminal.onTelegramSystemMessage = { message, _ in
            noticeContinuation.yield(message)
            return true
        }
        let effects = Mutex<[TerminalChat.TelegramWorkEffectForTesting]>([])
        let (effectEvents, effectContinuation) = AsyncStream.makeStream(
            of: TerminalChat.TelegramWorkEffectForTesting.self
        )
        terminal.onTelegramWorkEffectForTesting = { effect in
            effects.withLock { $0.append(effect) }
            effectContinuation.yield(effect)
            return true
        }

        let loop = Task { try await terminal.runInteractivePanelLoop() }
        var stateIterator = states.makeAsyncIterator()
        var noticeIterator = notices.makeAsyncIterator()
        var effectIterator = effectEvents.makeAsyncIterator()
        queue.send(.input(.submitted("hold generation open")))
        #expect(await stateIterator.next() == true)
        await generationGate.waitUntilEntered()

        let attachment = TerminalTelegramInboundAttachment(
            fileID: "busy-download", fileUniqueID: nil, kind: .document,
            mimeType: "text/plain", fileSize: 4, fileName: "busy.txt", messageID: 31
        )
        let busyWork: [TerminalTelegramIncomingMessage] = [
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 31,
                chatTitle: nil, username: nil, attachment: attachment
            ),
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil,
                voice: TerminalTelegramVoiceAttachment(
                    fileID: "busy-voice", fileUniqueID: nil, duration: 1,
                    mimeType: "audio/ogg", fileSize: 4
                ),
                messageID: 32, chatTitle: nil, username: nil
            ),
            Self.message("@coordinator busy publication", messageID: 33),
        ]
        for message in busyWork { queue.send(.telegramMessage(message)) }
        for _ in busyWork {
            #expect(await noticeIterator.next()?.contains("was not queued") == true)
        }
        #expect(effects.withLock { $0 }.isEmpty)

        await generationGate.release()
        #expect(await stateIterator.next() == false)
        for message in busyWork { queue.send(.telegramMessage(message)) }
        var observedEffects: [TerminalChat.TelegramWorkEffectForTesting] = []
        for _ in busyWork {
            if let effect = await effectIterator.next() { observedEffects.append(effect) }
        }
        #expect(observedEffects.count == 3)
        #expect(effects.withLock { $0 }.count == 3)

        queue.send(.input(.endOfInput))
        try await loop.value
        stateContinuation.finish()
        noticeContinuation.finish()
        effectContinuation.finish()
    }

    @Test
    func busyNoticeDoesNotLeakAcrossUnauthorizedRoutes() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        _ = await Self.installRoute(on: terminal)
        let notices = Mutex<[String]>([])
        terminal.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()

        _ = await terminal.handleTelegramRuntimeMessage(
            Self.message("foreign", chatID: 99), eventQueue: TerminalChatEventQueue(),
            queuedPrompts: &queuedPrompts,
            transcriptions: TerminalVoiceTranscriptionRegistry(),
            isSessionGenerating: true
        )

        #expect(queuedPrompts.isEmpty)
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
            await terminal.telegramControlService.offerArtifactConsent(
                artifact: TerminalTelegramArtifact(
                    fileURL: artifactURL, filename: artifactURL.lastPathComponent
                ),
                chatID: 42, userID: 7, routeLease: lease
            )
        )
        let notices = Mutex<[String]>([])
        terminal.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()

        let didQueue = await terminal.handleTelegramRuntimeMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 7,
                chatTitle: nil, username: nil, callbackQueryID: "callback-consent",
                callbackData: "zencode:artifact:cancel:\(offerID)"
            ),
            eventQueue: TerminalChatEventQueue(), queuedPrompts: &queuedPrompts,
            transcriptions: TerminalVoiceTranscriptionRegistry(),
            isSessionGenerating: true
        )

        #expect(!didQueue)
        #expect(queuedPrompts.isEmpty)
        #expect(await terminal.telegramControlService.pendingConsentArtifact(
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
            linkedChatID: 42,
            ownerUserID: 7,
            routes: [AgentTelegramRouteManifest(
                roomID: sessionID, generation: 2
            )]
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
