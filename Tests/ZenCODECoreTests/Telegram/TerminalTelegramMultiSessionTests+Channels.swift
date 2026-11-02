//
//  TerminalTelegramMultiSessionTests+Channels.swift
//  ZenCODE
//
//  Several Telegram channels on one bot: two terminal sessions attached in
//  topic mode through one dispatcher, one router and one registry, and two
//  ACP sessions of one bridge. A message is delivered to both, as the
//  dispatcher broadcasts every update to every session. Each test runs in a
//  support directory of its own.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Alpha and beta, two terminal sessions in `/tmp/project`, whose channels
/// are attached in topic mode to one bot: one dispatcher polls it, one router
/// holds every route and persists to the settings, one registry counts the
/// channels. Alpha's topic is 601, beta's 602.
extension TerminalTelegramMultiSessionTests {
    private typealias Support = TelegramChannelTestSupport

    private static let alreadyLinkedText =
        "Telegram is already linked to this ZenCODE session. Send a prompt or /help."

    /// A message in a session's topic reaches that session only, and is
    /// answered there; each topic was created and announced in General once.
    @Test(.timeLimit(.minutes(1)))
    func channelTopicsOnOneBotAreIsolated() async throws {
        try await Support.withSupport {
            let pair = try await Self.attachedChannelPair()
            let (alpha, beta) = (pair.alpha, pair.beta)
            #expect(pair.registry.attachedCount(botID: pair.botID) == 2)
            #expect(await pair.router.snapshot() == [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 601, roomID: alpha.sessionID),
                AgentTelegramRouteManifest(topicID: 602, roomID: beta.sessionID),
            ])
            for member in [alpha, beta] {
                let name = TelegramChannel.defaultTopicName(
                    workingDirectory: member.channel.workingDirectory,
                    sessionID: member.sessionID
                )
                #expect(await member.transport.sentMessages == [TelegramRoutedText(
                    text: TelegramChannel.generalTopicNoticeText(topicName: name), topicID: nil
                )])
                #expect(member.channel.activeRouteLease == member.topic)
            }

            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 601), to: pair) == [alpha.topic, nil])
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 602), to: pair) == [nil, beta.topic])
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 601), to: pair)
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 602), to: pair)

            #expect(await alpha.transport.sentMessages.dropFirst() == [
                TelegramRoutedText(text: Self.alreadyLinkedText, topicID: 601),
            ])
            #expect(await beta.transport.sentMessages.dropFirst() == [
                TelegramRoutedText(text: Self.alreadyLinkedText, topicID: 602),
            ])
            await pair.shutdown()
        }
    }

    /// General belongs to every session: both channels handle a message
    /// sent there on the shared route, and answer in General.
    @Test(.timeLimit(.minutes(1)))
    func generalIsHandledByBothChannels() async throws {
        try await Support.withSupport {
            let pair = try await Self.attachedChannelPair()
            let shared = try await pair.router.resolve(chatID: 42, userID: 7, topicID: nil)
            #expect(shared.key == TerminalTelegramRouteKey(chatID: 42, userID: 7, roomID: "default"))
            #expect(shared.effectiveMessageThreadID == nil)

            #expect(await Self.deliver(Self.ownerMessage("hello"), to: pair) == [shared, shared])
            _ = await Self.deliver(Self.ownerMessage("/start"), to: pair)

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    TelegramRoutedText(text: Self.alreadyLinkedText, topicID: nil),
                ])
            }
            await pair.shutdown()
        }
    }

    /// A topic no route knows falls back to the shared route: both channels
    /// handle the message and answer in the topic it came from.
    @Test(.timeLimit(.minutes(1)))
    func unknownTopicIsHandledByBothChannelsInThatTopic() async throws {
        try await Support.withSupport {
            let pair = try await Self.attachedChannelPair()
            let unknown = try await pair.router.resolve(chatID: 42, userID: 7, topicID: 999)
            #expect(unknown.key == TerminalTelegramRouteKey(chatID: 42, userID: 7, roomID: "default"))
            #expect(unknown.effectiveMessageThreadID == 999)

            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 999), to: pair) == [unknown, unknown])
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 999), to: pair)

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    TelegramRoutedText(text: Self.alreadyLinkedText, topicID: 999),
                ])
            }
            await pair.shutdown()
        }
    }

    /// While both channels are attached to the bot, a permission reply
    /// without a request ID in General, or in a topic no route knows, is
    /// refused by both, each in the topic it came from, and runs nothing.
    @Test(.timeLimit(.minutes(1)))
    func permissionRepliesWithoutAnIDInGeneralAreRefusedByBothChannels() async throws {
        try await Support.withSupport {
            let pair = try await Self.attachedChannelPair()
            let refusal = TelegramChannel.sharedRoutePermissionReplyText

            for topicID in [nil, 999] as [Int?] {
                #expect(await Self.deliver(Self.ownerMessage("/allow", topicID: topicID), to: pair) == [nil, nil])
            }

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    TelegramRoutedText(text: refusal, topicID: nil),
                    TelegramRoutedText(text: refusal, topicID: 999),
                ])
            }
            await pair.shutdown()
        }
    }

    /// A message in General, or in a topic no route knows, leaves each link
    /// on its session's topic: the link's route, the route of the next turn,
    /// and the shared-chat relay stay there, while the message itself is
    /// handled on its own route.
    @Test(.timeLimit(.minutes(1)))
    func generalLeavesEachLinkOnItsSessionTopic() async throws {
        try await Support.withSupport {
            let pair = try await Self.attachedChannelPair()
            let (alpha, beta) = (pair.alpha, pair.beta)
            let cards = TelegramTestRecorder<TerminalTelegramRouteLease>()
            alpha.channel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay(
                validateLease: { _ in true },
                send: { _, _, lease in
                    cards.append(lease)
                    return 1
                }
            )
            let shared = try await pair.router.resolve(chatID: 42, userID: 7, topicID: nil)
            let unknown = try await pair.router.resolve(chatID: 42, userID: 7, topicID: 999)

            // A message in alpha's topic binds alpha's relay to it.
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 601), to: pair) == [alpha.topic, nil])
            #expect(await Self.deliver(Self.ownerMessage("hello"), to: pair) == [shared, shared])
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 999), to: pair) == [unknown, unknown])

            for member in [alpha, beta] {
                #expect(member.channel.activeRouteLease == member.topic)
                #expect(member.channel.sessionTopic?.lease == member.topic)
                // The next turn of the channel reports on the link's route.
                await member.channel.beginTurn(adoptingStreamingBlock: false)
                #expect(member.channel.activeTurnLease == member.topic)
                await member.channel.endTurnReporting()
            }
            let relay = try #require(alpha.channel.sharedChatRelayStorage)
            await relay.forward([AgentSharedChat.Message(
                roomID: alpha.sessionID,
                sender: AgentSharedChat.Participant(id: "agent-1", name: "planner", kind: .agent),
                recipientIDs: [AgentSharedChat.operatorID(for: alpha.sessionID)],
                text: "ready"
            )], roomID: alpha.sessionID)
            await relay.waitForPendingCards()
            #expect(cards.values == [alpha.topic])
            await pair.shutdown()
        }
    }

    /// Two sessions of one ACP bridge, each handed to Telegram with
    /// `/telegram on` on the same bot in Threaded mode, share the bridge's
    /// router: each creates its own topic and neither overwrites the route
    /// of the other, in the router and in the settings. They also share its
    /// dispatcher, so the bot has a single long poll (a second concurrent
    /// `getUpdates` would get HTTP 409), whose messages reach both: a
    /// permission reply without an ID in General is refused by both, and
    /// runs nothing.
    @Test(.timeLimit(.minutes(1)))
    func twoACPSessionsShareOneRouterAndOneLongPoll() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let botID = ACPTelegramTestSupport.uniqueBotID()
            let transport = ACPTelegramScriptedTransport(
                botID: botID, hasTopicsEnabled: true, createdTopicIDs: [601, 602]
            )
            let alpha = "acp-alpha-\(UUID().uuidString)"
            let beta = "acp-beta-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [alpha, beta], transport: transport
            )
            let activeText = "Telegram remote control is active.\nLinked chat: Test"
            #expect(await fixture.turnTelegramOn(sessionID: alpha, id: 1) == activeText)
            #expect(await fixture.turnTelegramOn(sessionID: beta, id: 2) == activeText)

            let router = try #require(await fixture.bridge.telegramRouterForTesting())
            let alphaChannel = try #require(await fixture.telegramChannel(sessionID: alpha))
            let betaChannel = try #require(await fixture.telegramChannel(sessionID: beta))
            #expect(alphaChannel !== betaChannel)
            #expect(await alphaChannel.router === router)
            #expect(await betaChannel.router === router)
            #expect(await alphaChannel.controlService !== betaChannel.controlService)
            let routes = [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 601, roomID: alpha),
                AgentTelegramRouteManifest(topicID: 602, roomID: beta),
            ]
            #expect(await router.snapshot() == routes)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == routes)
            #expect(await alphaChannel.activeRouteLease?.key.topicID == 601)
            #expect(await betaChannel.activeRouteLease?.key.topicID == 602)
            #expect(await TelegramChannelRegistry.shared.attachedCount(botID: botID) == 2)

            #expect(await ACPTelegramTestSupport.waitUntil { await transport.pollCount > 0 })
            let before = await transport.sentMessages.count
            try await transport.deliver("/allow")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await transport.sentMessages.count >= before + 2
            })
            let refusal = ACPTelegramSentMessage(
                method: "sendMessage",
                text: await TelegramChannel.sharedRoutePermissionReplyText,
                topicID: nil
            )
            #expect(await Array(transport.sentMessages.dropFirst(before)) == [refusal, refusal])
            #expect(await transport.maximumConcurrentPolls == 1)
            #expect(await fixture.backend.prompts.isEmpty)

            await fixture.bridge.shutdown()
            // Each shutdown closed its session's topic route, in the router
            // and in the settings; the shared route stays active.
            let closed = await router.snapshot()
            #expect(closed.count == 3)
            #expect(closed.filter { $0.topicID == nil }.allSatisfy { $0.lifecycle == .active })
            #expect(closed.filter { $0.topicID != nil }.allSatisfy { $0.lifecycle != .active })
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == closed)
            #expect(await TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
        }
    }

    // MARK: Channel support

    /// Alpha and beta, two sessions in `/tmp/project`, with their channels
    /// attached in topic mode to one bot through one dispatcher, one router
    /// and one registry: alpha first, creating topic 601, then beta,
    /// creating topic 602. Each channel's queue is held, so the lines it
    /// admits wait where the test reads them.
    @ChatSessionActor
    private static func attachedChannelPair() async throws -> ChannelPair {
        let botID = Support.uniqueBotID()
        let settings = AgentSettingsManifestStore.load()?.telegram
        let router = TerminalTelegramSessionRouter(
            linkedChatID: settings?.linkedChatID,
            ownerUserID: settings?.ownerUserID,
            routes: settings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
            }
        )
        let dispatcher = TerminalTelegramBotDispatcher()
        let registry = TelegramChannelRegistry()
        func member(sessionID: String, topicID: Int) throws -> ChannelPairMember {
            let transport = TelegramChannelTestTransport(
                botID: botID, hasTopicsEnabled: true, createdTopicIDs: [topicID]
            )
            let terminal = try Support.makeTerminal(transport: transport)
            terminal.sessionID = sessionID
            let channel = TelegramChannel(
                host: terminal.sessionHost,
                slotID: terminal.terminalSlotID,
                sessionRunner: terminal.sessionRunner,
                router: router,
                controlService: TerminalTelegramControlService(
                    transportFactory: { transport }, dispatcher: dispatcher
                ),
                primaryChannelDescription: "TUI",
                registry: registry
            )
            let hold = Task<Void, Never> {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            }
            channel.activeTurnTask = hold
            return ChannelPairMember(
                terminal: terminal, channel: channel, transport: transport, topicID: topicID, hold: hold
            )
        }
        let pair = ChannelPair(
            alpha: try member(sessionID: "alpha-session-00000001", topicID: 601),
            beta: try member(sessionID: "beta-session-00000002", topicID: 602),
            router: router,
            registry: registry,
            botID: botID
        )
        try await pair.alpha.channel.attach()
        try await pair.beta.channel.attach()
        return pair
    }

    /// Delivers `message` to alpha, then to beta, and returns the route each
    /// admitted its line on (`nil`: not admitted).
    @ChatSessionActor
    private static func deliver(
        _ message: TerminalTelegramIncomingMessage,
        to pair: ChannelPair
    ) async -> [TerminalTelegramRouteLease?] {
        var leases: [TerminalTelegramRouteLease?] = []
        for member in [pair.alpha, pair.beta] {
            _ = await member.channel.handleIncomingMessage(message)
            leases.append(member.channel.promptQueue.dequeue()?.origin)
        }
        return leases
    }

    /// A text of the owner in chat 42, in `topicID` (General when `nil`).
    private static func ownerMessage(_ text: String, topicID: Int? = nil) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, topicID: topicID, text: text, voice: nil,
            messageID: 78, chatTitle: "Test", username: "operator"
        )
    }
}

/// The two channels of ``TerminalTelegramMultiSessionTests`` on one bot,
/// with the router and the registry they share.
private struct ChannelPair {
    let alpha: ChannelPairMember
    let beta: ChannelPairMember
    let router: TerminalTelegramSessionRouter
    let registry: TelegramChannelRegistry
    let botID: Int64

    @ChatSessionActor
    func shutdown() async {
        for member in [alpha, beta] {
            member.hold.cancel()
            await member.channel.shutdown()
            await member.terminal.sessionHost.shutdown()
        }
    }
}

/// One session of a ``ChannelPair``: the terminal whose slot the channel
/// belongs to, the channel, its own transport to the bot, and the task that
/// holds its queue.
private struct ChannelPairMember {
    let terminal: TerminalChat
    let channel: TelegramChannel
    let transport: TelegramChannelTestTransport
    let topicID: Int
    let hold: Task<Void, Never>

    @ChatSessionActor
    var sessionID: String {
        channel.sessionID
    }

    /// The lease of the session's topic, as its attach created it.
    @ChatSessionActor
    var topic: TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: topicID, roomID: sessionID),
            generation: 1, effectiveMessageThreadID: topicID
        )
    }
}
