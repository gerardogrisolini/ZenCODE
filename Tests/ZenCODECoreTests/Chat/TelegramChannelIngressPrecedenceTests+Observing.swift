//
//  TelegramChannelIngressPrecedenceTests+Observing.swift
//  ZenCODE
//
//  The fixtures behind the Telegram ingress precedence tables: the linked
//  channel, the rows and the states they cross, what a row observes, and how
//  the observation is taken.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TelegramChannelIngressPrecedenceTests {
    /// The receipt the card seam answers with.
    private static let cardReceipt = 91
    /// The receipt of the ForceReply card a `commandArgumentReply` row
    /// answers.
    private nonisolated static let commandReceipt = 90
    /// The receipt of the live card from `planner` the reply rows quote.
    private nonisolated static let liveCardReceipt = 1
    /// A chat other than the one the table's messages come from (42).
    private nonisolated static let foreignChatID: Int64 = 99

    // MARK: - Observing

    /// Sends the message of `row` in `state` and returns what the chat
    /// observed: the question of `state` waits when the message arrives, the
    /// line a turn task answers is answered, and the state is restored for
    /// the next row (queue emptied, question refused, receipt forgotten).
    static func observe(
        _ row: IngressRow,
        state: IngressState,
        in fixture: Linked
    ) async throws -> Observation {
        let channel = fixture.channel
        let reader = try await installReader(state.reader, in: fixture)
        if state.reader == .foreignLine {
            // The question belongs to another chat: this chat's line is not
            // its answer, and the question stays where it was.
            #expect(
                channel.deliverPendingLine("probe", lease: fixture.lease) == false,
                "\(row) in \(state)"
            )
        }
        if row == .commandArgumentReply {
            channel.commandReplyBindings[
                TerminalTelegramCommandReplyKey(chatID: 42, receiptMessageID: commandReceipt)
            ] = TerminalTelegramCommandReplyBinding(command: "/plan", chatID: 42, lease: fixture.lease)
        }
        let textCount = fixture.texts.values.count
        let cardCount = fixture.cards.values.count
        let transcriptCount = await fixture.transcript().count

        let admitted = await channel.handleIncomingMessage(row.message)
        if let turn = channel.activeTurnTask {
            await turn.value
        }
        if state.reader == .foreignLine {
            #expect(channel.pendingLineReader != nil, "\(row) in \(state)")
        }

        var queue = channel.promptQueue
        var queued: [String] = []
        while let prompt = queue.dequeue() {
            queued.append(prompt.text)
        }
        channel.promptQueue = ChatPromptQueue()
        channel.cancelPendingReaders()
        let delivered = await reader?.value ?? nil
        channel.commandReplyBindings = [:]
        return Observation(
            admitted: admitted,
            texts: Array(fixture.texts.values.dropFirst(textCount)),
            cards: Array(fixture.cards.values.dropFirst(cardCount)),
            queued: queued,
            delivered: delivered,
            published: Array(await fixture.transcript().dropFirst(transcriptCount))
        )
    }

    /// Asks the question `reader` of the controller in the chat and returns
    /// its task once it waits; the texts it sends are not observed.
    private static func installReader(
        _ reader: IngressState.Reader,
        in fixture: Linked
    ) async throws -> Task<String?, Never>? {
        let channel = fixture.channel
        let task: Task<String?, Never>
        switch reader {
        case .none:
            return nil
        case .choice:
            task = Task { @ChatSessionActor in
                await channel.chooseOne(
                    title: "Pick",
                    items: [ChatChoiceItem(id: "a", title: "alpha"), ChatChoiceItem(id: "b", title: "beta")],
                    selectedID: nil
                )
            }
            try await Support.waitUntil { channel.pendingChoiceReader != nil }
            try #require(channel.pendingChoiceReader != nil)
        case .line:
            task = Task { @ChatSessionActor in
                await channel.readLine(prompt: "Name?")
            }
            try await Support.waitUntil { channel.pendingLineReader != nil }
            try #require(channel.pendingLineReader != nil)
        case .attachment:
            task = Task { @ChatSessionActor in
                await channel.pickAttachment(startingAt: FileManager.default.temporaryDirectory)?.lastPathComponent
            }
            try await Support.waitUntil { channel.pendingAttachmentReader != nil }
            try #require(channel.pendingAttachmentReader != nil)
        case .foreignLine:
            let foreign = TerminalTelegramRouteLease(
                key: .init(chatID: foreignChatID, userID: 7, topicID: nil, roomID: fixture.room),
                generation: 1,
                effectiveMessageThreadID: nil
            )
            task = Task { @ChatSessionActor in
                await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    channel.pendingLineReader = TelegramChannel.PendingReader(
                        id: UUID(), lease: foreign, continuation: continuation
                    )
                }
            }
            try await Support.waitUntil { channel.pendingLineReader != nil }
            try #require(channel.pendingLineReader != nil)
        }
        return task
    }

    /// The session of the slot and the questions waiting for the next
    /// message when a row's message arrives.
    struct IngressState: Hashable, Sendable, CaseIterable, CustomTestStringConvertible {
        enum Session: Hashable, Sendable {
            /// The session is free.
            case free
            /// The host holds a prompt reservation.
            case generating
            /// The host holds the reservation of a turn of the primary
            /// channel whose ending the channel presents
            /// (``TelegramChannel/isPresentingPrimaryTurnEnding``).
            case presentingTurnEnding
        }

        enum Reader: Hashable, Sendable {
            case none
            case choice
            case line
            case attachment
            /// A line question waiting for the next message of another chat
            /// than the one the messages come from.
            case foreignLine
        }

        let session: Session
        let reader: Reader

        static let free = IngressState(session: .free, reader: .none)
        static let generating = IngressState(session: .generating, reader: .none)
        static let presentingTurnEnding = IngressState(session: .presentingTurnEnding, reader: .none)
        static let choiceFree = IngressState(session: .free, reader: .choice)
        static let choiceGenerating = IngressState(session: .generating, reader: .choice)
        static let lineFree = IngressState(session: .free, reader: .line)
        static let lineGenerating = IngressState(session: .generating, reader: .line)
        static let attachmentFree = IngressState(session: .free, reader: .attachment)
        static let attachmentGenerating = IngressState(session: .generating, reader: .attachment)
        static let foreignLineFree = IngressState(session: .free, reader: .foreignLine)
        static let foreignLineGenerating = IngressState(session: .generating, reader: .foreignLine)

        static let allCases: [IngressState] = [
            .free, .generating, .presentingTurnEnding,
            .choiceFree, .choiceGenerating,
            .lineFree, .lineGenerating,
            .attachmentFree, .attachmentGenerating,
            .foreignLineFree, .foreignLineGenerating,
        ]

        var testDescription: String {
            "\(session) with \(reader) question"
        }
    }

    /// One message of the ingress table.
    enum IngressRow: CaseIterable {
        case artifactConsentTap
        case staleChoiceTap
        case staleSelectionTap
        case mentionPickerTap
        case unknownTap
        case permissionReply
        case status
        case statusAlias
        case statusWithArgument
        case help
        case helpWithBotMention
        case helpAlias
        case changes
        case changesAlias
        case chat
        case chatWithArgument
        case start
        case coordinatorCommand
        case unknownSlashCommand
        case liveCardReply
        case liveMention
        case plainText
        case blankText
        case attachment
        case voice
        case voiceLiveCardReply
        case commandArgumentReply

        var message: TerminalTelegramIncomingMessage {
            switch self {
            case .artifactConsentTap: make(callbackData: "zencode:artifact:cancel:offer-1")
            case .staleChoiceTap: make(callbackData: "zencode:choice:s:00000000:0")
            case .staleSelectionTap: make(callbackData: "zencode:think:s:00000000:0")
            case .mentionPickerTap: make(callbackData: "zencode:mention:planner")
            case .unknownTap: make(callbackData: "zencode:other:1")
            case .permissionReply: make("/allow")
            case .status: make("/status")
            case .statusAlias: make("status")
            case .statusWithArgument: make("/status now")
            case .help: make("/help")
            case .helpWithBotMention: make("/help@zencode_bot")
            case .helpAlias: make("help")
            case .changes: make("/changes")
            case .changesAlias: make("changes")
            case .chat: make("/chat")
            case .chatWithArgument: make("/chat later")
            case .start: make("/start")
            case .coordinatorCommand: make("/plan")
            case .unknownSlashCommand: make("/foo")
            case .liveCardReply: make("go ahead", replyTo: TelegramChannelIngressPrecedenceTests.liveCardReceipt)
            case .liveMention: make("@planner hi")
            case .plainText: make("hello there")
            case .blankText: make("   ")
            case .attachment: make(attachment: TerminalTelegramInboundAttachment(
                fileID: "file-1", fileUniqueID: "unique-1", kind: .document, mimeType: "text/plain",
                fileSize: 12, fileName: "notes.txt", messageID: 78
            ))
            case .voice: make(voice: Self.voiceNote)
            case .voiceLiveCardReply: make(
                replyTo: TelegramChannelIngressPrecedenceTests.liveCardReceipt, voice: Self.voiceNote
            )
            case .commandArgumentReply: make("list", replyTo: TelegramChannelIngressPrecedenceTests.commandReceipt)
            }
        }

        private static let voiceNote = TerminalTelegramVoiceAttachment(
            fileID: "voice-1", fileUniqueID: "voice-unique-1", duration: 2, mimeType: "audio/ogg", fileSize: 512
        )

        private func make(
            _ text: String? = nil,
            replyTo: Int? = nil,
            voice: TerminalTelegramVoiceAttachment? = nil,
            attachment: TerminalTelegramInboundAttachment? = nil,
            callbackData: String? = nil
        ) -> TerminalTelegramIncomingMessage {
            TelegramChannelIngressPrecedenceTests.message(
                text, replyTo: replyTo, voice: voice, attachment: attachment, callbackData: callbackData
            )
        }
    }

    /// What the chat observed of one message.
    struct Observation: Equatable, CustomStringConvertible {
        var admitted = false
        /// The system messages sent, in order.
        var texts: [String] = []
        /// The messages sent with a reply markup, in order, each followed
        /// by its markup (``describe(_:)``).
        var cards: [String] = []
        /// The prompts waiting in the channel's queue.
        var queued: [String] = []
        /// What the question waiting for the next message received.
        var delivered: String?
        /// The shared-chat messages sent, as `recipients: text`.
        var published: [String] = []

        static let nothing = Observation()

        static func texts(_ texts: String...) -> Observation {
            Observation(texts: texts)
        }

        static func cards(_ cards: String...) -> Observation {
            Observation(cards: cards)
        }

        static func admitted(
            texts: [String] = [], cards: [String] = [], published: [String] = []
        ) -> Observation {
            Observation(admitted: true, texts: texts, cards: cards, published: published)
        }

        static func queued(_ line: String) -> Observation {
            Observation(admitted: true, queued: [line])
        }

        static func delivered(_ answer: String) -> Observation {
            Observation(delivered: answer)
        }

        static func published(_ messages: String...) -> Observation {
            Observation(published: messages)
        }

        var description: String {
            "admitted: \(admitted), texts: \(texts), cards: \(cards), queued: \(queued), "
                + "delivered: \(delivered ?? "nil"), published: \(published)"
        }
    }

    struct Linked {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let runner: AgentCoreSessionRunner
        let room: String
        let lease: TerminalTelegramRouteLease
        let texts = TelegramTestRecorder<String>()
        let cards = TelegramTestRecorder<String>()

        /// The messages of the room, as `recipients: text`.
        func transcript() async -> [String] {
            await runner.sharedChatTranscriptMessages(rootSessionID: room).map {
                "\($0.recipientIDs.joined(separator: ",")): \($0.text)"
            }
        }
    }

    /// The Telegram channel of a terminal of session `room`, whose shared
    /// chat holds the coordinator and one active agent, `agent-1`
    /// ("planner"), linked by hand to chat 42 on the route of `room`. The
    /// channel reads the ingress, and the relay has forwarded one live card
    /// of `planner`, receipt ``liveCardReceipt``. No control service is
    /// started: the system messages and the cards are recorded through the
    /// seams.
    static func linked(room: String) async throws -> Linked {
        let backend = SharedChatRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: room, modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)

        let terminal = try Support.makeTerminal(
            transport: TelegramChannelTestTransport(botID: 1), sessionRunner: runner
        )
        terminal.sessionID = room
        let channel = terminal.telegramChannel
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: nil, roomID: room),
            generation: 1,
            effectiveMessageThreadID: nil
        )
        await channel.router.refresh(
            linkedChatID: 42, ownerUserID: 7,
            routes: [AgentTelegramRouteManifest(roomID: room, generation: 1)]
        )
        channel.linkedChatID = 42
        channel.linkedUserID = 7
        channel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID()
        )
        channel.activeRouteLease = lease
        let fixture = Linked(terminal: terminal, channel: channel, runner: runner, room: room, lease: lease)
        let (texts, cards, receipt) = (fixture.texts, fixture.cards, cardReceipt)
        channel.onTelegramSystemMessage = { text, _ in
            texts.append(text)
            return true
        }
        channel.onTelegramMentionPickerMessage = { text, _, markup in
            cards.append(text + "\n" + describe(markup))
            return receipt
        }

        let liveCards = TelegramRelayCardLog()
        channel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay(
            validateLease: { _ in true },
            send: { text, _, _ in await liveCards.record(text) }
        )
        channel.readsIngress = true
        await channel.rebindSharedChatRelay(roomID: room)
        await channel.forwardSharedChatMessages([
            AgentSharedChat.Message(
                roomID: room,
                sender: AgentSharedChat.Participant(id: "agent-1", name: "planner", kind: .agent),
                recipientIDs: [AgentSharedChat.operatorID(for: room)],
                text: "need a decision"
            ),
        ], roomID: room)
        await channel.sharedChatRelay.waitForPendingCards()
        try #require(await liveCards.texts.count == liveCardReceipt)
        return fixture
    }

    /// A reply markup as the table writes it: the buttons as
    /// `text→callback data`, or `force reply`.
    private nonisolated static func describe(_ markup: TerminalTelegramReplyMarkup) -> String {
        switch markup {
        case .forceReply:
            return "⟨force reply⟩"
        case let .inlineKeyboard(rows):
            let buttons = rows.joined().map { "\($0.text)→\($0.callbackData)" }
            return "⟨" + buttons.joined(separator: ", ") + "⟩"
        }
    }

    /// A message in chat 42 of `userID` (the owner by default), of any of
    /// the shapes the ingress reads.
    nonisolated static func message(
        _ text: String?,
        userID: Int64 = 7,
        chatKind: TerminalTelegramChatKind = .privateChat,
        replyTo: Int? = nil,
        voice: TerminalTelegramVoiceAttachment? = nil,
        attachment: TerminalTelegramInboundAttachment? = nil,
        callbackData: String? = nil,
        stoppedDraftID: Int? = nil
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: userID, topicID: nil, chatKind: chatKind,
            text: text, voice: voice, messageID: 78, chatTitle: "Test", username: "operator",
            replyToMessageID: replyTo,
            callbackQueryID: callbackData.map { _ in "callback-1" }, callbackData: callbackData,
            stoppedMessageGenerationDraftID: stoppedDraftID, attachment: attachment
        )
    }
}
