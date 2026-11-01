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
//  destinations checked on the roster, and the shared-chat relay cards. The
//  channel is linked by hand to chat 42, the way the round-trip tests link a
//  terminal: no control service is started, and the system messages and
//  picker cards are recorded through the seams instead of being sent.
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
    /// `/chat`, the slash forms of `/help` and `/changes`, and the picker
    /// taps are answered; everything else is told the session is busy,
    /// before any work starts.
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
            #expect(effects.values.isEmpty)
            #expect(pair.texts.values.filter { $0 == TelegramChannel.busyMessageText }.count == 13)
            #expect(pair.texts.values.filter { $0 == channel.remoteStatusText() }.count == 2)
            #expect(pair.texts.values.contains(channel.remoteHelpText()))
            #expect(pair.texts.values.contains(channel.remoteChangesText()))
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
            #expect(texts.contains("Use /undo in the TUI to revert file changes."))
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
    /// to chat 42 on the route of `room`: no control service is started, and
    /// the system messages and picker cards are recorded through the seams.
    private static func handLinked(
        room: String,
        runner: AgentCoreSessionRunner? = nil
    ) async throws -> HandLinked {
        let terminal = try Support.makeTerminal(
            transport: TelegramChannelTestTransport(botID: 1), sessionRunner: runner
        )
        terminal.sessionID = room
        let channel = terminal.telegramChannel
        let route = AgentTelegramRouteManifest(roomID: room, generation: 1)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: room), generation: 1
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
        return runner
    }

    /// A relay whose cards `log` records instead of sending.
    private static func recordingRelay(_ log: TelegramRelayCardLog) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay(
            validateLease: { _ in true },
            send: { text, _, _ in await log.record(text) }
        )
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
