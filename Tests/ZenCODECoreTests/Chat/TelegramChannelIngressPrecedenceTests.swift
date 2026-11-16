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
    typealias Support = TelegramChannelTestSupport

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

    // MARK: - Support

    /// The dynamic texts of the fixture's session.
    private struct Texts {
        let status: String
        let help: String
        let changes: String
        let unknown: String
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
