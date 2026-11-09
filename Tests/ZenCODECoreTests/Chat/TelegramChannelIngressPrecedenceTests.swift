//
//  TelegramChannelIngressPrecedenceTests.swift
//  ZenCODE
//
//  Characterization of the precedence of the Telegram ingress
//  (``TelegramChannel/handleIncomingMessage(_:)``): one table of message ×
//  state → what the chat observes (the system messages and the cards sent,
//  in order, whether a prompt was admitted, what waits in the queue, what a
//  pending question received, and what reached the shared chat). The states
//  cross the session (free, generating, generating while the primary channel
//  presents the ending of its turn) with the questions of the controller
//  waiting for the next message (a menu, a line, an attachment, and a line
//  of another chat, which this chat's messages do not answer). A second
//  table fixes what a line answers when it leaves the queue
//  (``TelegramChannel/lineAction(for:lease:)``), the remote commands
//  included, and a third the messages the ingress drops without a word. The
//  channel is linked by hand to chat 42, as in the other ingress tests: no
//  control service is started, and the system messages and the cards are
//  recorded through the seams.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel ingress precedence", .serialized, .timeLimit(.minutes(3)))
struct TelegramChannelIngressPrecedenceTests {
    private typealias Support = TelegramChannelTestSupport

    /// The receipt the card seam answers with.
    private static let cardReceipt = 91
    /// The receipt of the ForceReply card a `commandArgumentReply` row
    /// answers.
    private nonisolated static let commandReceipt = 90
    /// The receipt of the live card from `planner` the reply rows quote.
    private nonisolated static let liveCardReceipt = 1
    /// A chat other than the one the table's messages come from (42).
    private nonisolated static let foreignChatID: Int64 = 99

    // MARK: - Texts

    private static let busy =
        "ZenCODE is busy generating a response in this session. This Telegram request was not queued; wait for the current response to finish and send it again."
    private static let choicePending = "Choose an option from the menu above."
    private static let alreadyLinked =
        "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
    private static let choiceOutOfDate = "ZenCODE: this menu is out of date."
    private static let thinkOutOfDate = "ZenCODE: this menu is out of date. Run /think again."
    private static let fileSendCancelled = "ZenCODE message: file send cancelled."
    private static let noPendingPermission = "No permission request is pending."
    private static let attachmentNotReceived = "ZenCODE message: the attachment could not be received."
    private static let voiceOff =
        "Voice-message transcription is off. Run zen --setup and open the Telegram section again (you can keep the current pairing) to turn it on."
    private static let voiceReply =
        "ZenCODE message: replies to a live message must be text. Send your answer as text, or record a voice note without replying to run it as an ordinary prompt."
    private static let statusArgument = "ZenCODE: /status does not accept arguments."
    private static let chatArgument = "ZenCODE: /chat does not accept arguments."
    private static let picker =
        "Choose who to message. After selecting, reply to the next card with your message.\n⟨@coordinator→zencode:mention:coordinator, @planner→zencode:mention:planner⟩"
    private static let writingToPlanner =
        "Writing to @planner. Reply to this message with the content to send; it will not be treated as a normal prompt.\n⟨force reply⟩"
    private static let planArgument =
        "Enter the goal or subcommand for /plan (save, load, list, delete, status, approve, clear). Reply to this message; it will not be treated as a normal prompt.\n⟨force reply⟩"

    // MARK: - Ingress table

    /// The ingress answers each message by the precedence of
    /// ``TelegramChannel/handleIncomingMessage(_:)``, in every state, as the
    /// table says.
    @Test(arguments: IngressState.allCases)
    func ingressAnswersEveryMessageByItsPrecedence(_ state: IngressState) async throws {
        try await Support.withSupport {
            let fixture = try await Self.linked(room: "ingress-precedence-\(UUID().uuidString)")
            var reservation: ChatPromptReservation?
            if state.session != .free {
                reservation = try fixture.terminal.sessionHost.reservePrompt(
                    in: fixture.terminal.terminalSlotID
                )
            }
            fixture.channel.isPresentingPrimaryTurnEnding = state.session == .presentingTurnEnding
            let texts = Texts(
                status: fixture.channel.remoteStatusText(),
                help: fixture.channel.remoteHelpText(),
                changes: fixture.channel.remoteChangesText(),
                unknown: "ZenCODE: unknown command '/foo'. Available commands: \(TelegramChannel.remoteCommandList())"
            )
            for row in IngressRow.allCases {
                let expected = try #require(Self.expectations(for: row, texts: texts)[state])
                let observed = try await Self.observe(row, state: state, in: fixture)
                #expect(observed == expected, "\(row) in \(state)")
            }
            if let reservation {
                _ = fixture.terminal.sessionHost.releasePrompt(reservation)
            }
            await fixture.terminal.sessionHost.shutdown()
        }
    }

    /// What `row` observes in each state.
    private static func expectations(for row: IngressRow, texts: Texts) -> [IngressState: Observation] {
        let busy = Observation.texts(Self.busy)
        let pending = Observation.texts(Self.choicePending)
        switch row {
        case .artifactConsentTap:
            return .same(.texts(Self.fileSendCancelled))
        case .staleChoiceTap:
            return .same(.texts(Self.choiceOutOfDate))
        case .staleSelectionTap:
            return .table(
                free: .texts(Self.thinkOutOfDate), generating: busy, presentingTurnEnding: busy,
                choiceFree: .texts(Self.thinkOutOfDate), choiceGenerating: busy,
                lineFree: .texts(Self.thinkOutOfDate), lineGenerating: busy,
                attachmentFree: .texts(Self.thinkOutOfDate), attachmentGenerating: busy
            )
        case .mentionPickerTap:
            return .same(.cards(Self.writingToPlanner))
        case .unknownTap:
            return .table(
                free: .nothing, generating: busy, presentingTurnEnding: busy,
                choiceFree: .nothing, choiceGenerating: busy,
                lineFree: .nothing, lineGenerating: busy,
                attachmentFree: .nothing, attachmentGenerating: busy
            )
        case .permissionReply:
            return .table(
                free: .texts(Self.noPendingPermission),
                generating: .texts(Self.noPendingPermission),
                presentingTurnEnding: .texts(Self.noPendingPermission),
                choiceFree: .texts(Self.noPendingPermission),
                choiceGenerating: .texts(Self.noPendingPermission),
                lineFree: .delivered("/allow"),
                lineGenerating: .texts(Self.noPendingPermission),
                attachmentFree: .texts(Self.noPendingPermission),
                attachmentGenerating: .texts(Self.noPendingPermission)
            )
        case .status:
            return .table(
                free: .admitted(texts: [texts.status]),
                generating: .texts(texts.status), presentingTurnEnding: .texts(texts.status),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/status"), lineGenerating: .delivered("/status"),
                attachmentFree: .admitted(texts: [texts.status]),
                attachmentGenerating: .texts(texts.status)
            )
        case .statusAlias:
            return .table(
                free: .admitted(texts: [texts.status]),
                generating: .texts(texts.status), presentingTurnEnding: .texts(texts.status),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("status"), lineGenerating: .delivered("status"),
                attachmentFree: .admitted(texts: [texts.status]),
                attachmentGenerating: .texts(texts.status)
            )
        case .statusWithArgument:
            return .table(
                free: .admitted(texts: [Self.statusArgument]),
                generating: busy, presentingTurnEnding: .queued("/status now"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/status now"), lineGenerating: .delivered("/status now"),
                attachmentFree: .admitted(texts: [Self.statusArgument]),
                attachmentGenerating: busy
            )
        case .help:
            return .table(
                free: .admitted(texts: [texts.help]),
                generating: .texts(texts.help), presentingTurnEnding: .texts(texts.help),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/help"), lineGenerating: .delivered("/help"),
                attachmentFree: .admitted(texts: [texts.help]),
                attachmentGenerating: .texts(texts.help)
            )
        case .helpWithBotMention:
            return .table(
                free: .admitted(texts: [texts.help]),
                generating: .texts(texts.help), presentingTurnEnding: .texts(texts.help),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/help@zencode_bot"), lineGenerating: .delivered("/help@zencode_bot"),
                attachmentFree: .admitted(texts: [texts.help]),
                attachmentGenerating: .texts(texts.help)
            )
        case .helpAlias:
            return .table(
                free: .admitted(texts: [texts.help]),
                generating: busy, presentingTurnEnding: .queued("help"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("help"), lineGenerating: .delivered("help"),
                attachmentFree: .admitted(texts: [texts.help]),
                attachmentGenerating: busy
            )
        case .changes:
            return .table(
                free: .admitted(texts: [texts.changes]),
                generating: .texts(texts.changes), presentingTurnEnding: .texts(texts.changes),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/changes"), lineGenerating: .delivered("/changes"),
                attachmentFree: .admitted(texts: [texts.changes]),
                attachmentGenerating: .texts(texts.changes)
            )
        case .changesAlias:
            return .table(
                free: .admitted(texts: [texts.changes]),
                generating: busy, presentingTurnEnding: .queued("changes"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("changes"), lineGenerating: .delivered("changes"),
                attachmentFree: .admitted(texts: [texts.changes]),
                attachmentGenerating: busy
            )
        case .chat:
            return .table(
                free: .cards(Self.picker),
                generating: .cards(Self.picker), presentingTurnEnding: .cards(Self.picker),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/chat"), lineGenerating: .delivered("/chat"),
                attachmentFree: .cards(Self.picker), attachmentGenerating: .cards(Self.picker)
            )
        case .chatWithArgument:
            return .table(
                free: .admitted(texts: [Self.chatArgument]),
                generating: busy, presentingTurnEnding: .queued("/chat later"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/chat later"), lineGenerating: .delivered("/chat later"),
                attachmentFree: .admitted(texts: [Self.chatArgument]),
                attachmentGenerating: busy
            )
        case .start:
            return .table(
                free: .texts(Self.alreadyLinked),
                generating: busy, presentingTurnEnding: .texts(Self.alreadyLinked),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/start"), lineGenerating: .delivered("/start"),
                attachmentFree: .texts(Self.alreadyLinked), attachmentGenerating: busy
            )
        case .coordinatorCommand:
            return .table(
                free: .cards(Self.planArgument),
                generating: busy, presentingTurnEnding: .cards(Self.planArgument),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/plan"), lineGenerating: .delivered("/plan"),
                attachmentFree: .cards(Self.planArgument), attachmentGenerating: busy
            )
        case .unknownSlashCommand:
            return .table(
                free: .admitted(texts: [texts.unknown]),
                generating: busy, presentingTurnEnding: .queued("/foo"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("/foo"), lineGenerating: .delivered("/foo"),
                attachmentFree: .admitted(texts: [texts.unknown]),
                attachmentGenerating: busy
            )
        case .liveCardReply:
            let published = Observation.published("agent-1: go ahead")
            return .table(
                free: published, generating: published, presentingTurnEnding: published,
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("go ahead"), lineGenerating: .delivered("go ahead"),
                attachmentFree: published, attachmentGenerating: published
            )
        case .liveMention:
            let published = Observation.published("agent-1: hi")
            let admitted = Observation.admitted(published: ["agent-1: hi"])
            return .table(
                free: admitted, generating: published, presentingTurnEnding: .queued("@planner hi"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("@planner hi"), lineGenerating: .delivered("@planner hi"),
                attachmentFree: admitted, attachmentGenerating: published
            )
        case .plainText:
            return .table(
                free: .admitted(), generating: busy, presentingTurnEnding: .queued("hello there"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("hello there"), lineGenerating: .delivered("hello there"),
                attachmentFree: .admitted(), attachmentGenerating: busy
            )
        case .blankText:
            return .table(
                free: .nothing, generating: busy, presentingTurnEnding: .nothing,
                choiceFree: .nothing, choiceGenerating: .nothing,
                lineFree: .nothing, lineGenerating: busy,
                attachmentFree: .nothing, attachmentGenerating: busy
            )
        case .attachment:
            let notReceived = Observation.texts(Self.attachmentNotReceived)
            return .table(
                free: notReceived, generating: busy, presentingTurnEnding: notReceived,
                choiceFree: pending, choiceGenerating: pending,
                lineFree: notReceived, lineGenerating: busy,
                attachmentFree: notReceived, attachmentGenerating: notReceived
            )
        case .voice:
            let off = Observation.texts(Self.voiceOff)
            return .table(
                free: off, generating: busy, presentingTurnEnding: off,
                choiceFree: pending, choiceGenerating: pending,
                lineFree: off, lineGenerating: busy,
                attachmentFree: off, attachmentGenerating: busy
            )
        case .voiceLiveCardReply:
            let reply = Observation.texts(Self.voiceReply)
            return .table(
                free: reply, generating: busy, presentingTurnEnding: reply,
                choiceFree: pending, choiceGenerating: pending,
                lineFree: reply, lineGenerating: busy,
                attachmentFree: reply, attachmentGenerating: busy
            )
        case .commandArgumentReply:
            return .table(
                free: .admitted(texts: [Self.noSavedPlans]),
                generating: busy, presentingTurnEnding: .queued("/plan list"),
                choiceFree: pending, choiceGenerating: pending,
                lineFree: .delivered("list"), lineGenerating: .delivered("list"),
                attachmentFree: .admitted(texts: [Self.noSavedPlans]),
                attachmentGenerating: busy
            )
        }
    }

    /// What `/plan list` answers in a session without saved plans.
    private static let noSavedPlans =
        "ZenCODE: no saved plan is available for this project. Use /plan save first."

    // MARK: - Lines

    /// A line that leaves the queue is answered as the table says: the
    /// remote commands with their texts or menus, an argument refused, an
    /// unknown slash command listed, the live mentions published, and
    /// anything else passed on as a prompt.
    @Test
    func aLineLeavingTheQueueIsAnsweredAsTheTableSays() async throws {
        try await Support.withSupport {
            let fixture = try await Self.linked(room: "line-precedence-\(UUID().uuidString)")
            let channel = fixture.channel
            let status = channel.remoteStatusText()
            let help = channel.remoteHelpText()
            let changes = channel.remoteChangesText()
            let noDiff = "ZenCODE message: no diff is available for this session yet."
            let undo = "Use /undo in the TUI after /telegram off to revert file changes."
            let rows: [(line: String, action: TelegramLineAction, observed: Observation)] = [
                ("/start", .handled, .texts(Self.alreadyLinked)),
                ("/start 233B0EC4", .handled, .texts(Self.alreadyLinked)),
                ("/help", .handled, .texts(help)),
                ("/help@zencode_bot", .handled, .texts(help)),
                ("help", .handled, .texts(help)),
                ("/status", .handled, .texts(status)),
                ("status", .handled, .texts(status)),
                ("/chat", .handled, .cards(Self.picker)),
                ("/changes", .handled, .texts(changes)),
                ("changes", .handled, .texts(changes)),
                ("/undo", .handled, .texts(undo)),
                ("undo", .handled, .texts(undo)),
                ("/diff", .handled, .texts(noDiff)),
                ("diff", .handled, .texts(noDiff)),
                ("/sessions", .handled, Self.sessionsMenu),
                ("/models", .handled, Self.modelsMenu),
                ("/think", .handled, Self.thinkMenu),
                ("/agents", .handled, Self.agentsMenu),
                ("/status now", .handled, .texts(Self.statusArgument)),
                ("/chat later", .handled, .texts(Self.chatArgument)),
                ("/help me", .handled, .texts("ZenCODE: /help does not accept arguments.")),
                ("/foo bar", .handled, .texts(
                    "ZenCODE: unknown command '/foo'. Available commands: \(TelegramChannel.remoteCommandList())"
                )),
                ("@planner hi", .handled, .published("agent-1: hi")),
                ("@planner", .handled, .texts("ZenCODE message: add a message after the live mention.")),
                ("status report", .runPrompt("status report"), .nothing),
                ("ordinary prompt", .runPrompt("ordinary prompt"), .nothing),
                ("/allow", .runPrompt("/allow"), .nothing),
            ]
            for row in rows {
                let textCount = fixture.texts.values.count
                let cardCount = fixture.cards.values.count
                let transcriptCount = await fixture.transcript().count
                let action = await channel.lineAction(for: row.line, lease: fixture.lease)
                let observed = Observation(
                    texts: Array(fixture.texts.values.dropFirst(textCount)),
                    cards: Array(fixture.cards.values.dropFirst(cardCount)),
                    published: Array(await fixture.transcript().dropFirst(transcriptCount))
                )
                #expect(action == row.action, "\(row.line)")
                #expect(observed == row.observed, "\(row.line)")
            }
            await fixture.terminal.sessionHost.shutdown()
        }
    }

    /// The menus `/sessions` and `/agents` send in the fixture's session, and
    /// what `/models` and `/think` answer there, without configured models.
    private static let sessionsMenu = Observation.cards(
        "Sessions\nChoose an action.\n⟨Load→zencode:sessions:a:load, New→zencode:sessions:a:new, "
            + "Save→zencode:sessions:a:save, Compact→zencode:sessions:a:compact, "
            + "Delete→zencode:sessions:a:delete, Restore checkpoint→zencode:sessions:a:restore⟩"
    )
    private static let modelsMenu = Observation.texts(Self.noModels)
    private static let thinkMenu = Observation.texts(Self.noModels)
    /// One button per default profile, in their order, tagged with the token
    /// of their IDs; the developer, the default agent, is the active one.
    private static let agentsMenu: Observation = {
        let profiles = AgentProfileStore.defaultProfiles()
        let token = TelegramChannel.selectionMenuToken(
            itemIDs: profiles.map(ChatSessionController.agentChoiceID)
        )
        let buttons = profiles.enumerated().map { index, profile in
            (index == 0 ? "✓ " : "") + "\(profile.displayName)→zencode:agents:p:\(token):\(index)"
        }
        return .cards("Agents\nTap the agent to make active.\n⟨" + buttons.joined(separator: ", ") + "⟩")
    }()
    private static let noModels =
        "ZenCODE: No models are configured for ZenCODE. Configure local or remote models in ZenCODE first."

    // MARK: - Dropped messages

    /// A stop-generation update, a message while the link is inactive, a
    /// message of another user or of a group, and a message without a wire
    /// lifecycle are dropped without a word, before the busy gate and the
    /// callbacks.
    @Test
    func theIngressDropsWithoutAWordWhatItDoesNotAuthorize() async throws {
        try await Support.withSupport {
            let fixture = try await Self.linked(room: "ingress-dropped-\(UUID().uuidString)")
            let channel = fixture.channel
            let dropped: [(String, TerminalTelegramIncomingMessage)] = [
                ("stop draft", Self.message("/status", stoppedDraftID: 5)),
                ("foreign user", Self.message("/status", userID: 8)),
                ("group chat", Self.message("/status", chatKind: .unsupported)),
                ("foreign tap", Self.message(nil, userID: 8, callbackData: "zencode:artifact:cancel:offer-1")),
            ]
            for (name, message) in dropped {
                #expect(await channel.handleIncomingMessage(message) == false, "\(name)")
            }
            let epoch = channel.controlState.wireLifecycleEpoch
            channel.controlState.wireLifecycleEpoch = nil
            #expect(await channel.handleIncomingMessage(Self.message("/status")) == false)
            #expect(await channel.handleIncomingMessage(
                Self.message(nil, callbackData: "zencode:artifact:cancel:offer-1")
            ) == false)
            channel.controlState.wireLifecycleEpoch = epoch
            channel.controlState.isActive = false
            #expect(await channel.handleIncomingMessage(Self.message("/status")) == false)
            channel.controlState.isActive = true
            #expect(fixture.texts.values.isEmpty)
            #expect(fixture.cards.values.isEmpty)
            #expect(channel.promptQueue.isEmpty)
            #expect(channel.activeTurnTask == nil)
            await fixture.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Observing

    /// Sends the message of `row` in `state` and returns what the chat
    /// observed: the question of `state` waits when the message arrives, the
    /// line a turn task answers is answered, and the state is restored for
    /// the next row (queue emptied, question refused, receipt forgotten).
    private static func observe(
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

    // MARK: - Support

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
    private enum IngressRow: CaseIterable {
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

    /// The dynamic texts of the fixture's session.
    private struct Texts {
        let status: String
        let help: String
        let changes: String
        let unknown: String
    }

    private struct Linked {
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
    private static func linked(room: String) async throws -> Linked {
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
    private nonisolated static func message(
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

private extension Dictionary where Key == TelegramChannelIngressPrecedenceTests.IngressState,
    Value == TelegramChannelIngressPrecedenceTests.Observation {
    /// The same observation in every state.
    static func same(_ observation: Value) -> Self {
        Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0, observation) })
    }

    /// One observation per state, in the columns of the table. A line
    /// question of another chat is no question of this one: its states, free
    /// and generating, observe what the states without a question do (the
    /// question is not delivered a line, and so ends refused).
    static func table(
        free: Value, generating: Value, presentingTurnEnding: Value,
        choiceFree: Value, choiceGenerating: Value,
        lineFree: Value, lineGenerating: Value,
        attachmentFree: Value, attachmentGenerating: Value
    ) -> Self {
        [
            .free: free, .generating: generating, .presentingTurnEnding: presentingTurnEnding,
            .choiceFree: choiceFree, .choiceGenerating: choiceGenerating,
            .lineFree: lineFree, .lineGenerating: lineGenerating,
            .attachmentFree: attachmentFree, .attachmentGenerating: attachmentGenerating,
            .foreignLineFree: free, .foreignLineGenerating: generating,
        ]
    }
}
