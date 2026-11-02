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

    private static let voiceNote = TerminalTelegramVoiceAttachment(
        fileID: "voice-1", fileUniqueID: nil, duration: 2, mimeType: "audio/ogg", fileSize: 4
    )

    /// A document the ingress admits.
    private static let noteAttachment = TerminalTelegramInboundAttachment(
        fileID: "note-1", fileUniqueID: nil, kind: .document,
        mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 78
    )

    // MARK: - Admission

    /// With the session free, every message is answered as the terminal
    /// answered it: the same texts, the same ForceReply cards, the same lines
    /// admitted on the message's route, and the same work started. A message
    /// from a group or from another user, a blank one, and any message on an
    /// inactive link are dropped without a word.
    @Test
    func idleIngressAnswersEveryMessageAndAdmitsTheLinesOnTheirRoute() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-idle-\(UUID().uuidString)")
            let channel = pair.channel
            let effects = TelegramTestRecorder<TelegramChannel.TelegramWorkEffectForTesting>()
            channel.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            // The queue is held: the admitted lines wait instead of running.
            let hold = Self.holdQueue(of: channel)
            let messages: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage("/start"),
                Self.ownerMessage("/start 233B0EC4"),
                Self.ownerMessage("ordinary prompt"),
                Self.ownerMessage("/status"),
                Self.ownerMessage("/chat later"),
                Self.ownerMessage("/chat"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("route all frontends", replyTo: Self.pickerReceipt),
                Self.ownerMessage("/goal@zencode_bot"),
                Self.ownerMessage("implement parity", replyTo: Self.pickerReceipt),
                Self.ownerMessage("ordinary follow-up", replyTo: 5),
                Self.ownerMessage("@coordinator do work"),
                Self.ownerMessage("   \n "),
                Self.ownerMessage("/allow"),
                Self.ownerMessage(nil, attachment: Self.noteAttachment),
                Self.ownerMessage(nil, voice: Self.voiceNote),
                Self.ownerMessage("from a group", chatKind: .unsupported),
                Self.ownerMessage("from another user", userID: 8),
            ]
            var queuedFlags: [Bool] = []
            for message in messages {
                queuedFlags.append(await channel.handleIncomingMessage(message))
            }

            var admitted: [ChatQueuedPrompt<TerminalTelegramRouteLease>] = []
            while let prompt = channel.promptQueue.dequeue() {
                admitted.append(prompt)
            }
            #expect(admitted.map(\.text) == [
                "ordinary prompt", "/status", "/chat later", "/plan route all frontends",
                "/goal implement parity", "ordinary follow-up", "@coordinator do work",
            ])
            #expect(admitted.allSatisfy { $0.origin == pair.lease && $0.mode == .submittedLine })
            #expect(queuedFlags.count(where: { $0 }) == admitted.count)
            #expect(pair.texts.values.filter { $0 == channel.alreadyLinkedText }.count == 2)
            #expect(pair.cards.values.map(\.markup).filter { $0 == .forceReply }.count == 2)
            #expect(pair.cards.values.count == 3)
            #expect(effects.values == [.attachmentDownload, .voiceTranscription])

            // An inactive link reads nothing.
            channel.controlState.isActive = false
            let textCount = pair.texts.values.count
            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage("late prompt"))))
            #expect(channel.promptQueue.isEmpty)
            #expect(pair.texts.values.count == textCount)
            hold.cancel()
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A full queue is told with the terminal's texts, for a prompt and for
    /// a command completed through its ForceReply.
    @Test
    func fullQueueIsToldForPromptsAndForCompletedCommands() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-queue-\(UUID().uuidString)")
            let channel = pair.channel
            channel.promptQueue = ChatPromptQueue(capacity: 1)
            _ = channel.promptQueue.enqueue(ChatQueuedPrompt(text: "already waiting", origin: pair.lease))
            let hold = Self.holdQueue(of: channel)

            for message in [
                Self.ownerMessage("overflow prompt"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("route all frontends", replyTo: Self.pickerReceipt),
            ] {
                #expect(!(await channel.handleIncomingMessage(message)))
            }
            #expect(pair.texts.values == [
                "ZenCODE is busy and the prompt queue is full. Your prompt was not queued; try again after a running prompt completes.",
                "ZenCODE is busy and the prompt queue is full. Your command was not queued; try again after a running prompt completes.",
            ])
            #expect(pair.cards.values.count == 1)
            hold.cancel()
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// While the session generates, only permission replies, `/status`,
    /// `/chat`, the slash forms of `/help` and `/changes`, the picker
    /// taps, and the live `@mention` lines are answered; everything else is
    /// told the session is busy, before any work starts.
    @Test
    func busyGateAnswersOnlyWhatMayRunWhileTheSessionGenerates() async throws {
        try await Support.withSupport {
            let pair = try await Self.handLinked(room: "channel-busy-\(UUID().uuidString)")
            let channel = pair.channel
            let effects = TelegramTestRecorder<TelegramChannel.TelegramWorkEffectForTesting>()
            channel.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            channel.onRunTurnForTesting = { prompt, _, _ in
                Issue.record("A busy session ran \(prompt)")
            }
            let reservation = try pair.terminal.sessionHost.reservePrompt(in: pair.terminal.terminalSlotID)
            #expect(channel.isSessionGenerating)
            let messages: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage("ordinary prompt"),
                Self.ownerMessage("/status"),
                Self.ownerMessage("stato"),
                Self.ownerMessage("/help"),
                Self.ownerMessage("help"),
                Self.ownerMessage("/changes"),
                Self.ownerMessage("changes"),
                Self.ownerMessage("/status now"),
                Self.ownerMessage("/diff"),
                Self.ownerMessage("/undo"),
                Self.ownerMessage("/start"),
                Self.ownerMessage("/plan route all frontends"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("/chat"),
                Self.ownerMessage("/allow"),
                Self.ownerMessage(nil, attachment: Self.noteAttachment),
                Self.ownerMessage(nil, voice: Self.voiceNote),
                Self.ownerMessage("@coordinator do work"),
                Self.ownerMessage(nil, callbackData: "zencode:mention:coordinator"),
                Self.ownerMessage(nil, callbackData: "unrelated"),
            ]
            for message in messages {
                #expect(!(await channel.handleIncomingMessage(message)), "\(message.text ?? "media")")
            }

            #expect(channel.promptQueue.isEmpty)
            #expect(pair.cards.values.count == 2)
            // The live mention is published, as the terminal publishes one
            // typed while it generates.
            #expect(effects.values == [.sharedChatPublication])
            #expect(pair.texts.values.filter { $0 == TelegramChannel.busyMessageText }.count == 12)
            #expect(pair.texts.values.filter { $0 == channel.remoteStatusText() }.count == 2)
            #expect(pair.texts.values.contains(channel.remoteHelpText()))
            #expect(pair.texts.values.contains(channel.remoteChangesText()))
            pair.terminal.sessionHost.releasePrompt(reservation)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// While the session generates, the live shared chat stays reachable
    /// from Telegram, as from the terminal: a reply to the `/chat` picker's
    /// card reaches the chosen agent or the coordinator, a live `@mention`
    /// is published, and a mention without text is diagnosed, instead of
    /// the busy text. A prompt, and a reply quoting a card the relay never
    /// sent, are still told the session is busy.
    @Test
    func busyGateLetsTheLiveSharedChatThrough() async throws {
        try await Support.withSupport {
            let room = "channel-busy-live-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner)
            let channel = pair.channel
            channel.onRunTurnForTesting = { prompt, _, _ in
                Issue.record("A busy session ran \(prompt)")
            }
            let reservation = try pair.terminal.sessionHost.reservePrompt(in: pair.terminal.terminalSlotID)
            #expect(channel.refusesMessagesAsBusy)

            let messages: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage(nil, callbackData: "zencode:mention:planner"),
                Self.ownerMessage("ship it", replyTo: Self.pickerReceipt),
                Self.ownerMessage(nil, callbackData: "zencode:mention:coordinator"),
                Self.ownerMessage("is the doc needed?", replyTo: Self.pickerReceipt),
                Self.ownerMessage("@planner check the log"),
                Self.ownerMessage("@coordinator"),
                Self.ownerMessage("ordinary prompt"),
                Self.ownerMessage("ordinary follow-up", replyTo: 5),
            ]
            for message in messages {
                #expect(!(await channel.handleIncomingMessage(message)), "\(message.text ?? "callback")")
            }

            #expect(pair.cards.values.map(\.text) == [
                "Writing to @planner. Reply to this message with the content to send; it will not be treated as a normal prompt.",
                "Writing to @coordinator. Reply to this message with the content to send; it will not be treated as a normal prompt.",
            ])
            let delivered = await runner.sharedChatTranscriptMessages(rootSessionID: room)
                .filter { $0.sender.kind == .operator }
            #expect(delivered.map(\.text) == ["ship it", "is the doc needed?", "check the log"])
            #expect(delivered.map(\.recipientIDs) == [
                ["agent-1"], [AgentSharedChat.coordinatorID(for: room)], ["agent-1"],
            ])
            #expect(channel.promptQueue.isEmpty)
            #expect(pair.texts.values.contains("ZenCODE message: add a message after the live mention."))
            #expect(pair.texts.values.filter { $0 == TelegramChannel.busyMessageText }.count == 2)
            pair.terminal.sessionHost.releasePrompt(reservation)
            await pair.terminal.sessionHost.shutdown()
        }
    }

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

    @Test
    func coordinatorCommandLinesUseTheRegistrySpelling() throws {
        let cases = [
            ("/PLAN status", "/plan status"),
            ("/review\tfocus on routing", "/review focus on routing"),
            ("/goal", "/goal"),
            ("/Goal  ship  it ", "/goal ship  it"),
            ("/plan@zencode_bot approve", "/plan approve"),
        ]
        for (line, expected) in cases {
            let command = try #require(CoordinatorCommandParser.parse(line))
            #expect(TelegramChannel.coordinatorCommandLine(command, from: line) == expected)
        }
    }

    // MARK: - Shared route

    /// On the route several sessions of one bot share, a permission reply
    /// without a request ID is refused with the text that asks for one; the
    /// session's own topic is attributed; with one channel left the shared
    /// route is attributed as before.
    @Test
    func permissionRepliesWithoutAnIDOnTheSharedRouteNeedOneWithSeveralChannels() async throws {
        try await Support.withSupport {
            let registry = TelegramChannelRegistry()
            let botID = Support.uniqueBotID()
            let room = "channel-shared-\(UUID().uuidString)"
            let first = try await Self.sharedBotMember(room: room, topicID: 70, botID: botID, registry: registry)
            let second = try await Self.sharedBotMember(
                room: "channel-shared-other-\(UUID().uuidString)", topicID: 71, botID: botID, registry: registry
            )
            #expect(registry.attachedCount(botID: botID) == 2)
            let channel = first.channel
            let refusal = "ZenCODE: several ZenCODE sessions are attached to this chat; reply with the request ID: /allow ID, /always ID or /deny ID."
            #expect(TelegramChannel.sharedRoutePermissionReplyText == refusal)
            channel.onRunTurnForTesting = { prompt, _, _ in
                Issue.record("A permission reply ran as the prompt \(prompt)")
            }

            let sharedLease = try await channel.router.resolve(chatID: 42, userID: 7, topicID: nil)
            #expect(sharedLease.key.roomID == "default" && sharedLease.key.topicID == nil)
            let shared = try await Self.pendingPermission(on: channel, lease: sharedLease)
            for (text, topicID) in [("/allow", nil), ("/always", nil), ("/deny@zencode_bot", 99), ("/allow !!!", nil)] as [(String, Int?)] {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(text, topicID: topicID))))
            }
            #expect(first.texts.values == [
                TelegramRoutedText(text: refusal, topicID: nil),
                TelegramRoutedText(text: refusal, topicID: nil),
                TelegramRoutedText(text: refusal, topicID: 99),
                TelegramRoutedText(text: refusal, topicID: nil),
            ])
            // The request was still pending: the reply with its ID decides it.
            _ = await channel.handleIncomingMessage(Self.ownerMessage("/deny \(shared.requestID)"))
            #expect(await shared.decision.value == .denied)
            #expect(first.texts.values.last == TelegramRoutedText(
                text: "⛔ Permission \(shared.requestID) denied. The operation will not run.", topicID: nil
            ))

            // The session's own topic is attributed: no ID is needed.
            let topicLease = try await channel.router.resolve(chatID: 42, userID: 7, topicID: 70)
            #expect(topicLease.key.roomID == room && topicLease.key.topicID == 70)
            let topic = try await Self.pendingPermission(on: channel, lease: topicLease)
            _ = await channel.handleIncomingMessage(Self.ownerMessage("/allow", topicID: 70))
            #expect(await topic.decision.value == .allowedOnce)
            #expect(first.texts.values.last == TelegramRoutedText(
                text: "✅ Permission \(topic.requestID) allowed once. Continuing.", topicID: 70
            ))

            // With one channel, the shared route is attributed as before.
            registry.unregister(second.channel)
            #expect(registry.attachedCount(botID: botID) == 1)
            let single = try await Self.pendingPermission(on: channel, lease: sharedLease)
            _ = await channel.handleIncomingMessage(Self.ownerMessage("/always"))
            #expect(await single.decision.value == .allowedAlways)
            #expect(first.texts.values.last == TelegramRoutedText(
                text: "✅ Permission \(single.requestID) allowed always. Continuing.", topicID: nil
            ))
            #expect(second.texts.values.isEmpty)
            await first.terminal.sessionHost.shutdown()
            await second.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Driving

    /// `startDriving()` reads the control service's ingress once, gating each
    /// message on the session's state (a stop-generation update is ignored),
    /// until `stopDriving()` or `shutdown()` stops it, leaving later messages
    /// unread.
    @Test
    func drivingReadsTheIngressUntilTheLinkStops() async throws {
        try await Support.withSupport {
            for shutsDown in [false, true] {
                let pair = try await Self.handLinked(room: "channel-drive-\(UUID().uuidString)")
                let channel = pair.channel
                let (texts, continuation) = AsyncStream.makeStream(of: String.self)
                var iterator = texts.makeAsyncIterator()
                channel.onTelegramSystemMessage = { text, _ in
                    continuation.yield(text)
                    return true
                }
                let prompts = TelegramTestRecorder<String>()
                channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }
                let mailbox = channel.controlService.incomingMailbox
                let stop = Self.ownerMessage(nil, stoppedDraftID: 5)
                #expect(!(await channel.stoppedDraftBelongsToActiveTurn(stop)))
                #expect(!(await channel.stoppedDraftBelongsToActiveTurn(Self.ownerMessage("/status"))))

                channel.startDriving()
                let consumer = try #require(channel.ingressConsumerTask)
                channel.startDriving()
                #expect(channel.ingressConsumerTask == consumer)
                #expect(channel.readsIngress)

                #expect(await mailbox.send(stop))
                #expect(await mailbox.send(Self.ownerMessage("/start")))
                #expect(await iterator.next() == channel.alreadyLinkedText)
                #expect(await mailbox.send(Self.ownerMessage("ordinary prompt")))
                try await Support.waitUntil { prompts.values == ["ordinary prompt"] }
                #expect(prompts.values == ["ordinary prompt"])
                let reservation = try pair.terminal.sessionHost.reservePrompt(in: pair.terminal.terminalSlotID)
                #expect(await mailbox.send(Self.ownerMessage("/diff")))
                #expect(await iterator.next() == TelegramChannel.busyMessageText)
                #expect(await mailbox.send(Self.ownerMessage("/help")))
                #expect(await iterator.next() == channel.remoteHelpText())
                pair.terminal.sessionHost.releasePrompt(reservation)

                if shutsDown {
                    await channel.shutdown()
                    #expect(channel.voiceTranscriptions.isShutDown)
                } else {
                    await channel.stopDriving()
                    #expect(!channel.voiceTranscriptions.isShutDown)
                }
                #expect(channel.ingressConsumerTask == nil)
                #expect(!channel.readsIngress)
                #expect(await mailbox.send(Self.ownerMessage("/status")))
                #expect(await mailbox.bufferedCountForTesting == 1)
                await pair.terminal.sessionHost.shutdown()
            }
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

    /// On the route every session shares (`default`), the relay is bound to
    /// the room of the session as soon as the channel drives the slot, so a
    /// message of the room reaches the chat without the operator having
    /// written first (`/telegram on` and nothing else). Only what the room
    /// says from then on is forwarded: the message it already held is not.
    @Test
    func sharedRouteRelaysTheRoomOnceTheChannelDrivesTheSlot() async throws {
        try await Support.withSupport {
            let room = "channel-shared-drive-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            await backend.enqueueCoordinatorMessage(text: "need a decision", roomID: room)
            let pair = try await Self.handLinked(
                room: room, runner: runner, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            // The coordinator turn the message asks for is not under test: it
            // is recorded only as the barrier proving the observation reads.
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }
            let slot = try #require(pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID])
            slot.setActiveChannel(.telegram)
            #expect(channel.activeRouteLease?.key.roomID == TerminalTelegramRouteKey.sharedRoomID)

            channel.startDriving()
            try await Self.expectOnlyNewMessagesAreRelayed(
                channel: channel, backend: backend, room: room, cards: cards, prompts: prompts
            )
            await channel.stopDriving()
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// On the session's own topic route the rule is the same: the relay is
    /// bound as soon as the channel drives the slot, the message the room
    /// already held is not forwarded, and the next one is.
    @Test
    func topicRouteRelaysOnlyWhatTheRoomSaysOnceTheChannelDrivesTheSlot() async throws {
        try await Support.withSupport {
            let room = "channel-topic-drive-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            await backend.enqueueCoordinatorMessage(text: "need a decision", roomID: room)
            let pair = try await Self.handLinked(room: room, runner: runner, topicID: 501)
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }
            let slot = try #require(pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID])
            slot.setActiveChannel(.telegram)
            #expect(channel.activeRouteLease?.key.topicID == 501)
            #expect(channel.activeRouteLease?.key.roomID == room)

            channel.startDriving()
            try await Self.expectOnlyNewMessagesAreRelayed(
                channel: channel, backend: backend, room: room, cards: cards, prompts: prompts
            )
            await channel.stopDriving()
            await pair.terminal.sessionHost.shutdown()
        }
    }

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

    /// A reply to a forwarded card on the shared route is delivered to the
    /// agent that wrote it, and is not taken for a prompt of the session.
    @Test
    func sharedRouteDeliversTheReplyToAForwardedCardToItsSender() async throws {
        try await Support.withSupport {
            let room = "channel-shared-reply-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            // Registers `agent-1` ("planner") in the room.
            await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
            let pair = try await Self.handLinked(
                room: room, runner: runner, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }

            await channel.handleIncomingMessage(Self.ownerMessage("/start"))
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "ship it?")],
                roomID: room
            )
            await channel.sharedChatRelay.waitForPendingCards()
            // The log answers each card with its position as the receipt.
            #expect(await cards.texts.count == 1)
            let receipt = 1
            #expect(await backend.recordedSharedChatMessageID() == nil)

            let admitted = await channel.handleIncomingMessage(
                Self.ownerMessage("yes, ship it", replyTo: receipt)
            )

            #expect(!admitted)
            #expect(await backend.recordedSharedChatMessageID() != nil)
            while let task = channel.activeTurnTask {
                await task.value
            }
            #expect(prompts.values.isEmpty)
            #expect(pair.texts.values == [channel.alreadyLinkedText])
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

    /// While the channel drives the slot it tells the shared chat it is busy
    /// for as long as a task of its own or its queue keeps it, and free when
    /// they end, as the terminal does. A batch the room offers while a task
    /// of the channel runs is declined, with the channel declared busy first,
    /// so it waits instead of coming straight back; once the task ends the
    /// channel says it is free and the room offers the batch again, which the
    /// channel runs. A batch that arrives while a turn of the channel and a
    /// prompt in its queue wait is not offered until both ran.
    @Test
    func aSharedChatBatchDeclinedWhileTheChannelIsBusyRunsOnceTheChannelIsFree() async throws {
        try await Support.withSupport {
            let room = "channel-trigger-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner)
            let channel = pair.channel
            let slot = try #require(pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID])
            #expect(slot.telegramChannel === channel)
            slot.setActiveChannel(.telegram)
            #expect(channel.drivesSlot)
            #expect(channel.sessionID == room)
            let coordinator = await runner.sharedChatCoordinator()
            @ChatSessionActor
            func isIdle() async -> Bool {
                let busyObservers = await coordinator.busyObserverCount(roomID: room)
                let claimOwner = await coordinator.claimedAutoTriggerOwnerID(roomID: room)
                let channelIsFree = channel.activeTurnTask == nil
                return busyObservers == 0 && claimOwner == nil && channelIsFree
            }
            let prompts = TelegramTestRecorder<String>()
            let gate = TelegramTurnGate()
            channel.onRunTurnForTesting = { prompt, _, _ in
                prompts.append(prompt)
                if prompt == "held prompt" {
                    await gate.wait()
                }
            }

            // Free: the room's first batch runs at once, and the channel is
            // free again when its turn ends.
            await backend.enqueueCoordinatorMessage(text: "first batch", roomID: room)
            channel.startSharedChatObservation()
            try await Support.waitUntil { prompts.values.count == 1 }
            #expect(prompts.values.first?.contains("first batch") == true)
            try await Support.waitUntil { await isIdle() }
            #expect(await isIdle())

            // Busy: a task of the channel runs that has not declared itself
            // yet (the moment between its start and its first step). The
            // batch offered meanwhile is declined: the channel declares itself
            // busy first, so the batch waits in the room.
            let hold = Self.holdQueue(of: channel)
            await backend.enqueueCoordinatorMessage(text: "second batch", roomID: room)
            try await Support.waitUntil {
                let busyObservers = await coordinator.busyObserverCount(roomID: room)
                let pending = await coordinator.pendingMessageCount(roomID: room)
                return busyObservers == 1 && pending == 1
            }
            #expect(await coordinator.busyObserverCount(roomID: room) == 1)
            #expect(await coordinator.pendingMessageCount(roomID: room) == 1)
            #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
            #expect(prompts.values.count == 1)

            // Free: the task ends, the channel says so, and the room offers
            // the batch again, which the channel now accepts and runs.
            hold.cancel()
            await channel.turnTaskDidEnd()
            try await Support.waitUntil { prompts.values.count == 2 }
            #expect(prompts.values.last?.contains("second batch") == true)
            try await Support.waitUntil { await isIdle() }
            #expect(await isIdle())

            // Busy with a queue: a turn of the channel waits, a prompt waits
            // behind it, and the batch that arrives meanwhile is not offered
            // until both ran.
            #expect(await channel.admitPrompt("held prompt", lease: pair.lease))
            try await Support.waitUntil { prompts.values.last == "held prompt" }
            #expect(await channel.admitPrompt("queued prompt", lease: pair.lease))
            #expect(channel.promptQueue.count == 1)
            #expect(await coordinator.busyObserverCount(roomID: room) == 1)
            await backend.enqueueCoordinatorMessage(text: "third batch", roomID: room)
            try await Support.waitUntil { await coordinator.pendingMessageCount(roomID: room) == 1 }
            #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
            #expect(prompts.values.count == 3)
            await gate.open()
            try await Support.waitUntil { prompts.values.count == 5 }
            let values = prompts.values
            #expect(values.count == 5)
            #expect(Array(values.dropFirst(2).prefix(2)) == ["held prompt", "queued prompt"])
            #expect(values.last?.contains("third batch") == true)
            try await Support.waitUntil { await isIdle() }
            #expect(await isIdle())

            await channel.stopSharedChatObservation()
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A channel without a route (revoked, rebound, or closed, until the chat
    /// writes again) has nowhere to answer a coordinator turn: the batch the
    /// room offers is declined with the channel declared busy first, so no
    /// claim holds the room and the batch waits there instead of coming
    /// straight back. A route that comes back makes the channel free, and the
    /// room offers the batch again, which the channel runs. A route that goes
    /// away while the channel is idle makes it busy at once, so the next
    /// batch waits until a route is back.
    @Test
    func aSharedChatBatchWaitsWhileTheChannelHasNoRouteAndRunsOnceARouteIsBack() async throws {
        try await Support.withSupport {
            let room = "channel-trigger-route-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner)
            let channel = pair.channel
            let slot = try #require(pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID])
            slot.setActiveChannel(.telegram)
            #expect(channel.drivesSlot)
            let coordinator = await runner.sharedChatCoordinator()
            @ChatSessionActor
            func isIdle() async -> Bool {
                let busyObservers = await coordinator.busyObserverCount(roomID: room)
                let claimOwner = await coordinator.claimedAutoTriggerOwnerID(roomID: room)
                return busyObservers == 0 && claimOwner == nil && channel.activeTurnTask == nil
            }
            @ChatSessionActor
            func waitsBusy() async -> Bool {
                let busyObservers = await coordinator.busyObserverCount(roomID: room)
                let pending = await coordinator.pendingMessageCount(roomID: room)
                return busyObservers == 1 && pending == 1
            }
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }

            // No route: the batch offered is declined and waits, unclaimed.
            channel.activeRouteLease = nil
            await backend.enqueueCoordinatorMessage(text: "first batch", roomID: room)
            channel.startSharedChatObservation()
            try await Support.waitUntil { await waitsBusy() }
            #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
            #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
            #expect(prompts.values.isEmpty)

            // The route is back: the room offers the batch again.
            channel.activeRouteLease = pair.lease
            await channel.activeRouteLeaseDidChange(hadLease: false)
            try await Support.waitUntil { prompts.values.count == 1 }
            #expect(prompts.values.first?.contains("first batch") == true)
            try await Support.waitUntil { await isIdle() }

            // The route goes away while the channel is idle: it is busy at
            // once, and the next batch is not even offered.
            await channel.routeWasInvalidated(pair.lease)
            #expect(channel.activeRouteLease == nil)
            #expect(await coordinator.busyObserverCount(roomID: room) == 1)
            await backend.enqueueCoordinatorMessage(text: "second batch", roomID: room)
            try await Support.waitUntil { await waitsBusy() }
            #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
            #expect(prompts.values.count == 1)
            channel.activeRouteLease = pair.lease
            await channel.activeRouteLeaseDidChange(hadLease: false)
            try await Support.waitUntil { prompts.values.count == 2 }
            #expect(prompts.values.last?.contains("second batch") == true)
            try await Support.waitUntil { await isIdle() }

            await channel.stopSharedChatObservation()
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Only new messages

    /// `/telegram off` → a message → `/telegram on`: what the room said while
    /// the link was off is not forwarded, what it says afterwards is, and a
    /// reply to a card forwarded before the off still reaches its sender (the
    /// ledger and its receipts survive the round trip on the same route).
    @Test
    func offThenOnSkipsWhatTheRoomSaidWhileOffAndKeepsEarlierReplies() async throws {
        try await Support.withSupport {
            let room = "channel-off-on-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            // Registers `agent-1` ("planner") in the room before the link.
            await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
            let terminal = try Support.makeTerminal(
                transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()),
                sessionRunner: runner
            )
            terminal.sessionID = room
            let host = terminal.sessionHost
            let slot = terminal.terminalSlotID
            let channel = terminal.telegramChannel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }

            try await host.activateTelegram(in: slot)
            #expect(host.activeChannel(in: slot) == .telegram)
            try await Self.waitForCoordinatorTurn(about: "ready", prompts)
            await backend.enqueueCoordinatorMessage(text: "first", roomID: room)
            try await Support.waitUntil { await cards.texts.count == 1 }

            _ = await host.deactivateTelegram(in: slot)
            #expect(!channel.isActive)
            await backend.enqueueCoordinatorMessage(text: "while off", roomID: room)

            try await host.activateTelegram(in: slot)
            #expect(channel.isActive)
            try await Self.waitForCoordinatorTurn(about: "while off", prompts)
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["first"])
            await backend.enqueueCoordinatorMessage(text: "after on", roomID: room)
            try await Support.waitUntil { await cards.texts.count == 2 }
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["first", "after on"])

            // The log answers each card with its position as the receipt: the
            // card forwarded before the off is still answerable.
            #expect(await backend.recordedSharedChatMessageID() == nil)
            let admitted = await channel.handleIncomingMessage(
                Self.ownerMessage("yes, ship it", replyTo: 1)
            )
            #expect(!admitted)
            #expect(await backend.recordedSharedChatMessageID() != nil)
            _ = await host.deactivateTelegram(in: slot)
            await host.shutdown()
        }
    }

    /// A room swap (`/sessions new`, `/sessions load`; here the session takes
    /// a new id in place) moves the observation and the relay to the new
    /// room: what the new room already held is not forwarded, what it says
    /// afterwards is.
    @Test
    func aSessionSwapSkipsWhatTheNewRoomAlreadyHolds() async throws {
        try await Support.withSupport {
            let room = "channel-swap-old-\(UUID().uuidString)"
            let nextRoom = "channel-swap-new-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            await backend.enqueueCoordinatorMessage(text: "need a decision", roomID: room)
            let pair = try await Self.handLinked(
                room: room, runner: runner, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in prompts.append(prompt) }
            let slot = try #require(pair.terminal.sessionHost.slots[pair.terminal.terminalSlotID])
            slot.setActiveChannel(.telegram)
            channel.startDriving()
            try await Self.waitForCoordinatorTurn(about: "need a decision", prompts)

            await backend.enqueueCoordinatorMessage(text: "already there", roomID: nextRoom)
            pair.terminal.sessionID = nextRoom
            #expect(channel.sessionID == nextRoom)
            try await Self.waitForCoordinatorTurn(about: "already there", prompts)
            #expect(channel.observedSharedChatRoomID == nextRoom)
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(await cards.texts.isEmpty)

            await backend.enqueueCoordinatorMessage(text: "fresh", roomID: nextRoom)
            try await Support.waitUntil { await cards.texts.count == 1 }
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["fresh"])
            await channel.stopDriving()
            await pair.terminal.sessionHost.shutdown()
        }
    }

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

    /// A new lease of the route the relay already forwards (the route's
    /// generation advanced; here it reaches the relay through a message from
    /// Telegram) is a refresh, not a start: a new message of the room that
    /// the observation has not offered yet still arrives.
    @Test
    func aRouteRefreshOnTheForwardedRoomStillRelaysANewMessage() async throws {
        try await Support.withSupport {
            let room = "channel-route-refresh-\(UUID().uuidString)"
            let (runner, backend) = try await Self.sharedChatRunner(room: room)
            await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
            let pair = try await Self.handLinked(
                room: room, runner: runner, routeRoomID: TerminalTelegramRouteKey.sharedRoomID
            )
            let channel = pair.channel
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            await channel.rebindSharedChatRelay(roomID: room)
            #expect(await channel.sharedChatRelay.forwards(roomID: room, chatID: 42))

            await backend.enqueueCoordinatorMessage(text: "fresh", roomID: room)
            await channel.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [
                AgentTelegramRouteManifest(roomID: TerminalTelegramRouteKey.sharedRoomID, generation: 2),
            ])
            await channel.handleIncomingMessage(Self.ownerMessage("/start"))
            #expect(channel.activeRouteLease?.generation == 2)

            let fresh = try #require(
                await runner.sharedChatTranscriptMessages(rootSessionID: room).last
            )
            #expect(fresh.text == "fresh")
            await channel.forwardSharedChatMessages([fresh], roomID: room)
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["fresh"])
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

    private struct SharedBotMember {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let texts = TelegramTestRecorder<TelegramRoutedText>()
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

    /// Holds the channel's queue: a task that never ends stands in for a
    /// turn of the channel, so admitted lines wait instead of running.
    private static func holdQueue(of channel: TelegramChannel) -> Task<Void, Never> {
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        channel.activeTurnTask = task
        return task
    }

    /// A channel of session `room` on the bot `botID`, registered in
    /// `registry` and linked by hand to chat 42 with the shared route and the
    /// topic `topicID` of its own; its routed system messages are recorded.
    private static func sharedBotMember(
        room: String, topicID: Int, botID: Int64, registry: TelegramChannelRegistry
    ) async throws -> SharedBotMember {
        let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
        terminal.sessionID = room
        let channel = TelegramChannel(
            host: terminal.sessionHost,
            slotID: terminal.terminalSlotID,
            sessionRunner: terminal.sessionRunner,
            router: TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7, routes: []),
            controlService: TerminalTelegramControlService(
                transportFactory: { TelegramChannelTestTransport(botID: botID) }
            ),
            primaryChannelDescription: "TUI",
            registry: registry
        )
        await channel.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [
            AgentTelegramRouteManifest(roomID: "default", generation: 1),
            AgentTelegramRouteManifest(topicID: topicID, roomID: room, generation: 1),
        ])
        channel.linkedChatID = 42
        channel.linkedUserID = 7
        channel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID(), botID: botID
        )
        channel.activeRouteLease = try await channel.router.resolve(chatID: 42, userID: 7, topicID: nil)
        registry.register(channel, botID: botID)
        let member = SharedBotMember(terminal: terminal, channel: channel)
        let texts = member.texts
        channel.onTelegramRoutedSystemMessage = { text, _, topicID in
            texts.append(TelegramRoutedText(text: text, topicID: topicID))
            return true
        }
        return member
    }

    /// Asks `channel`'s broker to authorize a deletion on `lease`, and
    /// returns the decision in flight with the request ID the chat was sent.
    private static func pendingPermission(
        on channel: TelegramChannel,
        lease: TerminalTelegramRouteLease
    ) async throws -> (decision: Task<TerminalTelegramPermissionOutcome, Never>, requestID: String) {
        let (requests, continuation) = AsyncStream.makeStream(of: String.self)
        let broker = channel.permissionBroker
        let request = AgentToolAuthorizationRequest(
            sessionID: "terminal-test", toolCallID: "tool-call-test", toolName: "local.delete",
            title: "Delete Sources/Old.swift", kind: "destructive",
            command: "delete Sources/Old.swift", workingDirectory: "/tmp/project"
        )
        let decision = Task {
            await broker.authorize(request, lease: lease) { message in
                continuation.yield(message)
                return true
            }
        }
        var iterator = requests.makeAsyncIterator()
        let message = try #require(await iterator.next())
        let requestID = try #require(message
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Request ID:") }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            })
        return (decision, requestID)
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

    /// Waits until the coordinator turn a shared-chat message about `text`
    /// asks for has run. The observation offers a message before the turn
    /// its batch triggers, so from here on that message was handled by the
    /// relay: a negative expectation about its card is deterministic.
    private static func waitForCoordinatorTurn(
        about text: String,
        _ prompts: TelegramTestRecorder<String>
    ) async throws {
        try await Support.waitUntil { prompts.values.contains { $0.contains(text) } }
        try #require(prompts.values.contains { $0.contains(text) })
    }

    /// With the channel driving the slot of `room`, which held "need a
    /// decision" before: that message is offered but never becomes a card,
    /// and the next message of the room ("ship it?") is the only card, inviting
    /// a reply to its sender.
    private static func expectOnlyNewMessagesAreRelayed(
        channel: TelegramChannel,
        backend: SharedChatRuntimeBackend,
        room: String,
        cards: TelegramRelayCardLog,
        prompts: TelegramTestRecorder<String>
    ) async throws {
        try await waitForCoordinatorTurn(about: "need a decision", prompts)
        await channel.sharedChatRelay.waitForPendingCards()
        #expect(await cards.texts.isEmpty)

        await backend.enqueueCoordinatorMessage(text: "ship it?", roomID: room)
        try await Support.waitUntil { await cards.texts.count == 1 }
        await channel.sharedChatRelay.waitForPendingCards()

        let texts = await cards.texts
        #expect(texts.count == 1)
        #expect(texts.first?.contains("ship it?") == true)
        #expect(texts.first?.hasSuffix("Reply to this message to answer planner.") == true)
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

/// A gate the test opens: ``wait()`` suspends until ``open()``, and returns
/// at once afterwards.
private actor TelegramTurnGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let opened = waiters
        waiters = []
        for waiter in opened {
            waiter.resume()
        }
    }
}
