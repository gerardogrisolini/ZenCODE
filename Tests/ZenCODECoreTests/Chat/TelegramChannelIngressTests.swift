//
//  TelegramChannelIngressTests.swift
//  ZenCODE
//
//  What a ``TelegramChannel`` answers to the Telegram ingress: the owner
//  authorization, the busy gate, ForceReply for a bare menu command, the
//  admission to the channel's queue and the full-queue texts, the dispatch of
//  the remote commands and of `/plan` `/goal` `/review` through the
//  controller, the permission replies on a route several sessions share, the
//  consumer of the ingress while the channel drives the slot, the direct
//  destinations checked on the roster, the shared-chat relay cards, the
//  channel's busy state for the shared chat, and the context of the
//  handover. The channel is linked by hand to chat 42, the way the
//  round-trip tests link a terminal: no control service is started, and the
//  system messages and picker cards are recorded through the seams instead
//  of being sent.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel ingress", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelIngressTests {
    private typealias Support = TelegramChannelTestSupport

    /// The receipt the picker seams answer with.
    private static let pickerReceipt = 91

    // MARK: - Lines

    /// The remote commands a line carries when it leaves the queue are
    /// answered with the terminal's texts and action: arguments refused,
    /// unknown commands listed, mentions diagnosed, prompts passed on, and
    /// `/plan` `/goal` `/review` run by the controller with their notices
    /// sent to the chat. A line on a route that is no longer valid is dropped.
    @Test
    func lineDispatchAnswersRemoteCommandsAndPassesPromptsOn() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-lines-\(UUID().uuidString)")
            let channel = pair.channel
            let handled: [String] = [
                "/help", "/help@zencode_bot", "/status", "/changes", "/undo", "/diff", "/start",
                "/start 233B0EC4", "/chat", "/status now", "/chat later", "/foo bar",
                "status", "diff", "@coordinator",
                "/plan status", "/PLAN status", "/plan list", "/goal",
            ]
            for line in handled {
                let countBefore = pair.texts.values.count + pair.cards.values.count
                #expect(await channel.lineAction(for: line, lease: pair.lease) == .handled, "\(line)")
                #expect(pair.texts.values.count + pair.cards.values.count > countBefore, "\(line)")
            }
            #expect(await channel.lineAction(for: "ordinary prompt", lease: pair.lease) == .runPrompt("ordinary prompt"))
            #expect(await channel.lineAction(for: "/allow", lease: pair.lease) == .runPrompt("/allow"))
            // Without a shared chat, a handle nobody owns is ordinary text.
            #expect(await channel.lineAction(for: "@nobody hi", lease: pair.lease) == .runPrompt("@nobody hi"))

            let texts = pair.texts.values
            #expect(texts.contains(channel.remoteHelpText()))
            #expect(texts.filter { $0 == channel.remoteStatusText() }.count == 2)
            #expect(texts.contains("ZenCODE: /status does not accept arguments."))
            #expect(texts.contains("ZenCODE: /chat does not accept arguments."))
            #expect(texts.contains(
                "ZenCODE: unknown command '/foo'. Available commands: \(TelegramChannel.remoteCommandList())"
            ))
            #expect(texts.contains("Use /undo in the TUI after /telegram off to revert file changes."))
            #expect(texts.contains(channel.alreadyLinkedText))
            #expect(texts.contains("ZenCODE message: add a message after the live mention."))
            #expect(texts.filter { $0 == "ZenCODE message: no diff is available for this session yet." }.count == 2)
            #expect(texts.contains(ChatSessionNoticeText.text(for: ChatSessionNotice.workflowMissingGoal)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(pair.cards.values.count == 1)

            // A line on a route that is no longer valid is dropped.
            let stale = TerminalTelegramRouteLease(key: pair.lease.key, generation: pair.lease.generation + 1)
            let count = pair.texts.values.count
            #expect(await channel.lineAction(for: "/status", lease: stale) == .handled)
            #expect(pair.texts.values.count == count)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Shared chat

    /// A direct destination is valid when every named agent is in the
    /// session's roster; the coordinator and the broadcasts always are.
    @Test
    func directDestinationsAreCheckedOnTheRoster() async throws {
        try await Support.withSupport {
            let room = "channel-roster-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner)
            let cases: [(AgentSharedChat.Destination, Bool)] = [
                (.direct(["agent-1"]), true),
                (.direct(["agent-9"]), false),
                (.direct([AgentSharedChat.coordinatorID(for: room)]), false),
                (.direct(["agent-1", "agent-9"]), true),
                (.direct([]), true),
                (.coordinator, true),
                (.all, true),
                (.operator, true),
                (.peers, true),
            ]
            for (destination, expected) in cases {
                #expect(await pair.channel.isCurrentSharedChatDirectDestination(destination) == expected)
            }
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// Cards are forwarded only while the link is active, and invite a
    /// reply only while the ingress is read, with the terminal's texts.
    @Test
    func relayCardsFollowTheLinkAndTheIngress() async throws {
        try await Support.withSupport {
            let room = "channel-relay-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner)
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)

            let unread = Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "need a decision")
            await channel.rebindSharedChatRelay(roomID: room)
            await channel.forwardSharedChatMessages([unread], roomID: room)

            let read = Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "ship it?")
            channel.readsIngress = true
            await channel.rebindSharedChatRelay(roomID: room)
            await channel.forwardSharedChatMessages([read], roomID: room)
            await channel.sharedChatRelay.waitForPendingCards()

            let texts = await cards.texts
            #expect(texts.count == 2)
            #expect(texts.first?.hasSuffix(
                "This ZenCODE session does not read Telegram messages; answer from the terminal."
            ) == true)
            #expect(texts.last?.hasSuffix("Reply to this message to answer planner.") == true)

            // Unlinked, nothing is forwarded.
            channel.controlState.isActive = false
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "late")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(await cards.texts.count == 2)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A rebind of the relay to another room retires the ForceReply receipts
    /// of the previous one, and a message of the previous room is not
    /// forwarded.
    @Test
    func rebindToAnotherRoomRetiresTheReceipts() async throws {
        try await Support.withSupport {
            let room = "channel-rebind-\(UUID().uuidString)"
            let pair = try await Self.handLinked(room: room)
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            let key = TerminalTelegramCommandReplyKey(chatID: 42, receiptMessageID: 90)
            channel.commandReplyBindings[key] = TerminalTelegramCommandReplyBinding(
                command: "/plan", chatID: 42, lease: pair.lease
            )

            await channel.rebindSharedChatRelay(roomID: room)
            #expect(channel.commandReplyBindings.count == 1)

            await channel.rebindSharedChatRelay(roomID: "another-room")
            #expect(channel.commandReplyBindings.isEmpty)
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "unbound")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(await cards.texts.isEmpty)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Shared route

    /// A message from Telegram on the shared route binds the relay to the
    /// room of the session, not to the route's own room: what the room says
    /// afterwards is forwarded (the relay used to be bound to `default` and
    /// dropped every batch of the session).
    @Test
    func sharedRouteKeepsRelayingAfterAnIncomingMessage() async throws {
        try await Support.withSupport {
            let room = "channel-shared-ingress-\(UUID().uuidString)"
            let pair = try await Self.handLinked(
                room: room, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)

            await channel.handleIncomingMessage(Self.ownerMessage("/start"))
            #expect(pair.texts.values == [channel.alreadyLinkedText])
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "ship it?")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()

            let texts = await cards.texts
            #expect(texts.count == 1)
            #expect(texts.first?.contains("ship it?") == true)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A room swap (`/sessions new`, `/sessions load`) rebinds the relay of
    /// the shared route to the new room of the session: the batches of the
    /// retired room are no longer forwarded, those of the new one are.
    @Test
    func sharedRouteFollowsTheSessionToItsNewRoom() async throws {
        try await Support.withSupport {
            let room = "channel-shared-swap-\(UUID().uuidString)"
            let nextRoom = "channel-shared-next-\(UUID().uuidString)"
            let pair = try await Self.handLinked(
                room: room, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)

            await channel.rebindSharedChatRelay(roomID: room)
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "first")],
                roomID: room
            )
            // Delivered before the swap: a rebind drops what is still queued.
            await channel.sharedChatRelay.waitForPendingCards()
            await channel.rebindSharedChatRelay(roomID: nextRoom)
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "retired")],
                roomID: room
            )
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: nextRoom, senderID: "agent-2", name: "writer", text: "second")],
                roomID: nextRoom
            )
            await channel.sharedChatRelay.waitForPendingCards()

            let texts = await cards.texts
            #expect(texts.count == 2)
            #expect(texts.first?.contains("first") == true)
            #expect(texts.last?.contains("second") == true)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A route bound to another room of its own never serves the session: the
    /// relay stays unbound instead of forwarding the room to it.
    @Test
    func aRouteOfAnotherRoomIsNotRelayed() async throws {
        try await Support.withSupport {
            let room = "channel-foreign-\(UUID().uuidString)"
            let pair = try await Self.handLinked(
                room: room, routeRoomID: "another-\(UUID().uuidString)"
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)

            await channel.rebindSharedChatRelay(roomID: room)
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "unbound")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(await cards.texts.isEmpty)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Only new messages

    /// After the route was invalidated, a message from Telegram binds the
    /// relay again: what the room said in the meantime, which the observation
    /// may still have to offer, is not forwarded; what it says afterwards is.
    @Test
    func aRouteBackFromTheIngressSkipsWhatTheRoomAlreadyHolds() async throws {
        try await Support.withSupport {
            let room = "channel-route-back-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
            let pair = try await Self.handLinked(
                room: room, runner: runner, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            await channel.handleIncomingMessage(Self.ownerMessage("/start"))
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "first")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["first"])

            // The route moves to its next generation and the channel drops the
            // retired lease, as its route validation does.
            await channel.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [
                AgentTelegramRouteManifest(roomID: TerminalTelegramRouteKey.sharedRoomID, generation: 2),
            ])
            await channel.routeWasInvalidated(pair.lease)
            #expect(channel.activeRouteLease == nil)
            await backend.enqueueCoordinatorMessage(text: "while unbound", roomID: room)

            await channel.handleIncomingMessage(Self.ownerMessage("/start"))
            #expect(channel.activeRouteLease?.generation == 2)
            // What the observation may still offer: the whole transcript, then
            // a message the room says afterwards.
            let held = await runner.sharedChatTranscriptMessages(rootSessionID: room)
            #expect(held.map(\.text) == ["ready", "while unbound"])
            await channel.forwardSharedChatMessages(
                held + [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "after")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["first", "after"])
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Handover context

    /// The context of the handover is the last six prompts and responses: the
    /// thoughts between them are left out before counting, so they never take
    /// the place of a prompt or a response; the response still streaming
    /// follows them, marked as in progress.
    @Test
    func handoverContextIsTheLastSixPromptsAndResponsesWhateverThoughtsLieBetween() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-context-\(UUID().uuidString)")
            var transcript: [ChatTurnEntry] = []
            for turn in 1...4 {
                let kinds: [ChatTurnEntry.Kind] = [
                    .userPrompt(text: "question \(turn)", attachments: [], origin: .local),
                    .thought("thinking \(turn)"),
                    .assistantText("answer \(turn)"),
                    .thought("more thinking \(turn)"),
                ]
                for kind in kinds {
                    transcript.append(ChatTurnEntry(sequence: transcript.count + 1, turnID: turn, kind: kind))
                }
            }
            let lastSix = [
                "👤 question 2", "🤖 answer 2", "👤 question 3", "🤖 answer 3", "👤 question 4", "🤖 answer 4",
            ]

            await pair.channel.sendHandoverContext(transcript: transcript, liveAssistantText: "")
            await pair.channel.sendHandoverContext(transcript: transcript, liveAssistantText: "  still streaming \n")
            await pair.channel.sendHandoverContext(transcript: Array(transcript.prefix(3)), liveAssistantText: "")
            await pair.channel.sendHandoverContext(transcript: [], liveAssistantText: " ")
            #expect(pair.texts.values == [
                (["Last 6 messages of the session:"] + lastSix).joined(separator: "\n\n"),
                (["Last 7 messages of the session:"] + lastSix + ["🤖 (in progress) still streaming"])
                    .joined(separator: "\n\n"),
                ["Last 2 messages of the session:", "👤 question 1", "🤖 answer 1"].joined(separator: "\n\n"),
            ])
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    private struct HandLinked {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let lease: TerminalTelegramRouteLease
        let texts = TelegramTestRecorder<String>()
        let cards = TelegramTestRecorder<PickerCard>()
    }

    /// A message with a reply markup, as a picker seam receives it.
    private struct PickerCard: Equatable, Sendable {
        let text: String
        let chatID: Int64
        let markup: TerminalTelegramReplyMarkup
    }

    /// The Telegram channel of a terminal of session `room`, linked by hand
    /// to chat 42 on the route of `routeRoomID` (the route of `room` by
    /// default; ``TerminalTelegramRouteKey/sharedRoomID`` for the route every
    /// session shares), in the topic `topicID` when given: no control service
    /// is started, and the system messages and picker cards are recorded
    /// through the seams.
    private static func handLinked(
        room: String,
        runner: AgentCoreSessionRunner? = nil,
        routeRoomID: String? = nil,
        topicID: Int? = nil
    ) async throws -> HandLinked {
        let routeRoomID = routeRoomID ?? room
        let terminal = try Support.makeTerminal(
            transport: TelegramChannelTestTransport(botID: 1), sessionRunner: runner
        )
        terminal.sessionID = room
        let channel = terminal.telegramChannel
        let route = AgentTelegramRouteManifest(topicID: topicID, roomID: routeRoomID, generation: 1)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: topicID, roomID: routeRoomID),
            generation: 1,
            effectiveMessageThreadID: topicID
        )
        await channel.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [route])
        channel.linkedChatID = 42
        channel.linkedUserID = 7
        channel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID()
        )
        channel.activeRouteLease = lease
        let pair = HandLinked(terminal: terminal, channel: channel, lease: lease)
        let (texts, cards, receipt) = (pair.texts, pair.cards, pickerReceipt)
        channel.onTelegramSystemMessage = { text, _ in
            texts.append(text)
            return true
        }
        channel.onTelegramMentionPickerMessage = { text, chatID, markup in
            cards.append(PickerCard(text: text, chatID: chatID, markup: markup))
            return receipt
        }
        return pair
    }

    /// A session runner whose backend holds a live shared chat for `room`,
    /// with its coordinator and one active agent, `agent-1`, named
    /// "planner".
    private static func plannerRunner(room: String) async throws -> AgentCoreSessionRunner {
        let (runner, backend) = try await sharedChatRunner(room: room)
        await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
        return runner
    }

    /// A session runner of the session `room` whose backend holds a live
    /// shared chat, still empty: each
    /// ``SharedChatRuntimeBackend/enqueueCoordinatorMessage(text:roomID:)``
    /// sends the coordinator a message of `agent-1` ("planner").
    private static func sharedChatRunner(
        room: String
    ) async throws -> (AgentCoreSessionRunner, SharedChatRuntimeBackend) {
        let backend = SharedChatRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: room, modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        return (runner, backend)
    }

    /// A relay whose cards `log` records instead of sending.
    private static func recordingRelay(_ log: TelegramRelayCardLog) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay(
            validateLease: { _ in true },
            send: { text, _, _ in await log.record(text) }
        )
    }

    /// The message bodies of the relay cards `texts`, in order (a card is
    /// route, body and footer, separated by blank lines).
    private static func bodies(of texts: [String]) -> [String] {
        texts.map { $0.components(separatedBy: "\n\n").dropFirst().first ?? "" }
    }

    /// A message of an agent of `room` to the operator.
    private static func agentMessage(
        room: String, senderID: String, name: String, text: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: room,
            sender: AgentSharedChat.Participant(id: senderID, name: name, kind: .agent),
            recipientIDs: [AgentSharedChat.operatorID(for: room)],
            text: text
        )
    }

    /// A message in chat 42 of `userID` (the owner by default), of any of
    /// the shapes the ingress reads.
    private static func ownerMessage(
        _ text: String?,
        topicID: Int? = nil,
        userID: Int64 = 7,
        chatKind: TerminalTelegramChatKind = .privateChat,
        replyTo: Int? = nil,
        voice: TerminalTelegramVoiceAttachment? = nil,
        attachment: TerminalTelegramInboundAttachment? = nil,
        callbackData: String? = nil,
        stoppedDraftID: Int? = nil
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: userID, topicID: topicID, chatKind: chatKind,
            text: text, voice: voice, messageID: 78, chatTitle: "Test", username: "operator",
            replyToMessageID: replyTo,
            callbackQueryID: callbackData.map { _ in "callback-1" }, callbackData: callbackData,
            stoppedMessageGenerationDraftID: stoppedDraftID, attachment: attachment
        )
    }
}

/// The cards a relay sent, in order.
actor TelegramRelayCardLog {
    private(set) var texts: [String] = []

    func record(_ text: String) -> Int {
        texts.append(text)
        return texts.count
    }
}
