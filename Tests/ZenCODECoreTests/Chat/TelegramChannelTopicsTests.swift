//
//  TelegramChannelTopicsTests.swift
//  ZenCODE
//
//  Topic mode and legacy mode of a ``TelegramChannel``'s link
//  (`TelegramChannel+Topics.swift`): the route the session uses, the notice
//  in General, the fallback to the shared route, the rebind (the shared-chat
//  relay it moves to the new room before the rename) and its rename,
//  and the close and prune at detach and shutdown. Every router persists to
//  the test's settings, as the host's does, so an attach reads back what an
//  earlier one wrote. Telegram is a Bot API double; every test runs in a
//  UUID support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel topics", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelTopicsTests {
    private typealias Support = TelegramChannelTestSupport

    /// The session of the topic tests; its last eight characters name its
    /// topic.
    private static let topicSessionID = "topic-session-0123456789abcdef"

    /// The default topic name of ``topicSessionID`` in `/tmp/project`.
    private static let topicSessionName = "project · 89abcdef"

    /// What the channel presents when the link is active.
    private static let activationNotice = TelegramChannelNotice(
        text: "Telegram remote control is active.\nLinked chat: Test\n", channel: .system
    )

    /// `/telegram` of an active link without a topic of its own.
    private static let legacyStatusText =
        "Telegram: Active as @zencode_bot\nBot: @zencode_bot\nLinked chat: Test"

    /// `/telegram` of an active link in topic mode.
    private static func topicStatusText(topic: String) -> String {
        legacyStatusText + "\nTopic: \(topic)"
    }

    /// The default topic name is the folder and the last eight characters of
    /// the session ID, bounded to Telegram's 128 UTF-16 units.
    @Test
    func defaultTopicNameIsTheFolderAndTheSessionSuffixBounded() {
        let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        #expect(TelegramChannel.defaultTopicName(
            workingDirectory: folder, sessionID: "0123456789abcdef"
        ) == "project · 89abcdef")
        #expect(TelegramChannel.defaultTopicName(
            workingDirectory: folder, sessionID: "abc"
        ) == "project · abc")
        let deep = URL(
            fileURLWithPath: "/tmp/" + String(repeating: "d", count: 200), isDirectory: true
        )
        #expect(TelegramChannel.defaultTopicName(
            workingDirectory: deep, sessionID: "0123456789abcdef"
        ) == String(repeating: "d", count: 128))
    }

    /// With Threaded mode and no topic of its own, the session creates one,
    /// binds it to a route of its own, and announces it once in General after
    /// the activation text; `/telegram` names it. A repeated attach
    /// reuses the topic without a request or a notice.
    @Test
    func attachCreatesTheSessionTopicAndAnnouncesItOnceInGeneral() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(
                botID: Support.uniqueBotID(), hasTopicsEnabled: true, createdTopicIDs: [501]
            )
            let member = try Self.topicMember(transport: transport)
            let channel = member.channel

            try await channel.attach()

            let name = Self.topicSessionName
            #expect(await transport.createdTopicNames == [name])
            #expect(member.notices.notices == [Self.activationNotice])
            #expect(await transport.sentMessages == [TelegramRoutedText(
                text: "ZenCODE session “project · 89abcdef” now has its own topic; messages sent here in General reach every attached session.",
                topicID: nil
            )])
            #expect(TelegramChannel.generalTopicNoticeText(topicName: name)
                == (await transport.sentMessages.first?.text))
            let lease = try #require(channel.activeRouteLease)
            #expect(lease == Self.topicLease(501))
            #expect(channel.sessionTopic == .init(lease: lease, name: name))
            let routes = [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 501, roomID: Self.topicSessionID),
            ]
            #expect(member.commits.values == [routes])
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == routes)
            #expect(await channel.statusText() == Self.topicStatusText(topic: name))

            // A repeated `/telegram on` finds the topic active and reuses it.
            try await channel.attach()

            #expect(await transport.createdTopicNames == [name])
            #expect(await transport.sentMessages.count == 1)
            #expect(member.notices.notices == [Self.activationNotice, Self.activationNotice])
            #expect(channel.activeRouteLease == lease)
            #expect(channel.sessionTopic == .init(lease: lease, name: name))
            #expect(member.commits.values.count == 1)

            await channel.shutdown()
            await member.terminal.sessionHost.shutdown()
        }
    }

    /// A topic that cannot be created leaves the session on the shared route,
    /// as in legacy mode: the error is recorded and presented after the
    /// activation text, nothing is announced or persisted, the status has no
    /// topic, and neither the rebind nor the detach writes anything.
    @Test
    func failedTopicCreationFallsBackToTheSharedRoute() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID(), hasTopicsEnabled: true)
            let member = try Self.topicMember(transport: transport)
            let channel = member.channel

            try await channel.attach()

            let description = "Telegram API error 400: \(TelegramChannelTestTransport.createTopicFailure)"
            #expect(await transport.createdTopicNames == [Self.topicSessionName])
            #expect(member.notices.notices == [
                Self.activationNotice,
                .init(text: "ZenCODE: \(description)\n", channel: .failure),
            ])
            #expect(channel.controlState.lastError == description)
            #expect(channel.activeRouteLease?.key == Support.defaultRouteKey)
            #expect(channel.sessionTopic == nil)
            #expect(await transport.sentMessages.isEmpty)
            #expect(await channel.statusText() == Self.legacyStatusText)

            await channel.rebind(sessionID: "other-session", displayName: "Other")
            await channel.detach()

            #expect(await transport.topicRequestCount == 1)
            #expect(member.commits.values.isEmpty)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Support.pairedSettings.routes)
            await member.terminal.sessionHost.shutdown()
        }
    }

    /// On a new or loaded session the primary channel rebinds the topic: its
    /// route moves to the new session with the next generation, the previous
    /// lease stops validating, the topic is renamed with the name bounded like
    /// Telegram's, and the status names it.
    @Test
    func rebindMovesTheTopicToTheNewSessionAndRenamesIt() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(
                botID: Support.uniqueBotID(), hasTopicsEnabled: true, createdTopicIDs: [501]
            )
            let member = try Self.topicMember(transport: transport)
            let channel = member.channel
            try await channel.attach()
            let created = try #require(channel.activeRouteLease)
            let loadedSessionID = "loaded-session-fedcba9876543210"
            member.terminal.sessionID = loadedSessionID

            await channel.rebind(sessionID: loadedSessionID, displayName: "Parser refactor")

            let rebound = Self.topicLease(501, roomID: loadedSessionID, generation: 2)
            #expect(channel.activeRouteLease == rebound)
            #expect(channel.sessionTopic == .init(lease: rebound, name: "Parser refactor"))
            await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
                try await channel.router.validate(created)
            }
            #expect(await transport.renamedTopics == [TelegramRoutedText(text: "Parser refactor", topicID: 501)])
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 501, roomID: loadedSessionID, generation: 2),
            ])
            #expect(member.commits.values.count == 2)
            #expect(await channel.statusText() == Self.topicStatusText(topic: "Parser refactor"))
            #expect(member.notices.notices == [Self.activationNotice])

            // A name beyond Telegram's limit is renamed and shown bounded.
            let long = "Session " + String(repeating: "x", count: 200)
            let bounded = TerminalTelegramAPIClient.boundedTopicName(long)
            #expect(bounded.utf16.count == 128 && long.hasPrefix(bounded))

            await channel.rebind(sessionID: loadedSessionID, displayName: long)

            #expect(channel.activeRouteLease == Self.topicLease(501, roomID: loadedSessionID, generation: 3))
            #expect(await transport.renamedTopics.last == TelegramRoutedText(text: bounded, topicID: 501))
            #expect(channel.sessionTopic?.name == bounded)
            #expect(await channel.statusText() == Self.topicStatusText(topic: bounded))

            await channel.shutdown()
            await member.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Rebind and the shared-chat relay

    /// The rebind moves the shared-chat relay to the new room before the
    /// rename, which it does not wait for: a message the new room says while
    /// Telegram has not answered the rename yet reaches the chat, and the
    /// rename then completes as usual.
    @Test
    func theRelayFollowsTheReboundTopicBeforeTheRenameAnswers() async throws {
        try await Support.withSupport {
            let transport = RenameGatedTransport(base: TelegramChannelTestTransport(
                botID: Support.uniqueBotID(), hasTopicsEnabled: true, createdTopicIDs: [501]
            ))
            let member = try Self.topicMember(transport: transport)
            let channel = member.channel
            try await channel.attach()
            let cards = TelegramRelayCardLog()
            channel.sharedChatRelayStorage = Self.recordingRelay(cards)
            await channel.rebindSharedChatRelay(roomID: Self.topicSessionID)
            #expect(await channel.sharedChatRelay.forwards(roomID: Self.topicSessionID, chatID: 42))
            let loadedSessionID = "loaded-session-fedcba9876543210"
            member.terminal.sessionID = loadedSessionID

            let rebinding = Task { @ChatSessionActor in
                await channel.rebind(sessionID: loadedSessionID, displayName: "Parser refactor")
            }
            // Telegram has the rename and has not answered it.
            await transport.gate.waitForEntries(1)
            #expect(await channel.sharedChatRelay.forwards(roomID: loadedSessionID, chatID: 42))
            await channel.forwardSharedChatMessages(
                [Self.agentMessage(room: loadedSessionID, text: "while renaming")], roomID: loadedSessionID
            )
            await channel.sharedChatRelay.waitForPendingCards()
            #expect(Self.bodies(of: await cards.texts) == ["while renaming"])

            await transport.gate.open()
            await rebinding.value
            let rebound = Self.topicLease(501, roomID: loadedSessionID, generation: 2)
            #expect(channel.sessionTopic == .init(lease: rebound, name: "Parser refactor"))
            #expect(await transport.base.renamedTopics == [TelegramRoutedText(text: "Parser refactor", topicID: 501)])
            #expect(member.notices.notices == [Self.activationNotice])
            #expect(Self.bodies(of: await cards.texts) == ["while renaming"])

            await channel.shutdown()
            await member.terminal.sessionHost.shutdown()
        }
    }

    /// The detach closes the topic's route and prunes the inactive routes
    /// beyond 32, the lowest topics first. Only active topics are reused, so
    /// a rebind while detached does nothing and the next attach creates and
    /// announces a new topic.
    @Test
    func detachClosesAndPrunesAndTheNextAttachCreatesANewTopic() async throws {
        try await Support.withSupport(telegram: Self.settings(routes: Self.routesBeforePruning)) {
            let transport = TelegramChannelTestTransport(
                botID: Support.uniqueBotID(), hasTopicsEnabled: true, createdTopicIDs: [502]
            )
            let member = try Self.topicMember(transport: transport)
            let channel = member.channel
            try await channel.attach()
            #expect(channel.activeRouteLease == Self.topicLease(501))

            await channel.detach()

            // One commit closes the topic, one prunes topic 1.
            #expect(member.commits.values.count == 2)
            #expect(member.commits.values.last == Self.routesAfterPruning)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Self.routesAfterPruning)
            #expect(channel.sessionTopic == nil)
            #expect(channel.activeRouteLease == nil)
            #expect(member.notices.notices == [
                Self.activationNotice,
                .init(text: "Telegram remote control stopped.\n", channel: .system),
            ])

            await channel.rebind(sessionID: "other-session", displayName: "Other")

            #expect(member.commits.values.count == 2)
            #expect(await transport.topicRequestCount == 0)

            try await channel.attach()

            #expect(await transport.createdTopicNames == [Self.topicSessionName])
            #expect(await transport.sentMessages == [TelegramRoutedText(
                text: TelegramChannel.generalTopicNoticeText(topicName: Self.topicSessionName),
                topicID: nil
            )])
            #expect(channel.activeRouteLease == Self.topicLease(502))

            await channel.shutdown()
            await member.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    /// The lease of topic `topicID` bound to `roomID` in chat 42.
    private static func topicLease(
        _ topicID: Int, roomID: String = topicSessionID, generation: UInt64 = 1
    ) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: topicID, roomID: roomID),
            generation: generation, effectiveMessageThreadID: topicID
        )
    }

    /// The paired settings with `routes`.
    private static func settings(routes: [AgentTelegramRouteManifest]) -> AgentTelegramSettingsManifest {
        AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: routes
        )
    }

    /// The routes of the pruning tests: the shared route, 32 closed topics of
    /// earlier sessions, and the session's active topic 501.
    private static let routesBeforePruning =
        [AgentTelegramRouteManifest(roomID: "default")]
        + closedTopics(1...32)
        + [AgentTelegramRouteManifest(topicID: 501, roomID: topicSessionID)]

    /// Once topic 501 is closed 33 routes are inactive, and the lowest
    /// topic, 1, is pruned.
    private static let routesAfterPruning =
        [AgentTelegramRouteManifest(roomID: "default")]
        + closedTopics(2...32)
        + [AgentTelegramRouteManifest(
            topicID: 501, roomID: topicSessionID, lifecycle: .closed, generation: 2
        )]

    private static func closedTopics(_ topicIDs: ClosedRange<Int>) -> [AgentTelegramRouteManifest] {
        topicIDs.map {
            AgentTelegramRouteManifest(
                topicID: $0, roomID: "earlier-session-\($0)", lifecycle: .closed, generation: 2
            )
        }
    }

    private struct TopicMember {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let notices: TelegramChannelNoticeRecorder
        let commits: TelegramTestRecorder<[AgentTelegramRouteManifest]>
    }

    /// The Telegram channel of a terminal session ``topicSessionID`` on
    /// `transport`, whose router is read from the settings and persists every
    /// commit to them, as the host's does, recording it in `commits`.
    private static func topicMember(transport: any TelegramHTTPTransport) throws -> TopicMember {
        let terminal = try Support.makeTerminal(transport: transport)
        terminal.sessionID = topicSessionID
        let commits = TelegramTestRecorder<[AgentTelegramRouteManifest]>()
        let settings = AgentSettingsManifestStore.load()?.telegram
        let router = TerminalTelegramSessionRouter(
            linkedChatID: settings?.linkedChatID,
            ownerUserID: settings?.ownerUserID,
            routes: settings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
                commits.append(routes)
            }
        )
        let channel = TelegramChannel(
            host: terminal.sessionHost,
            slotID: terminal.terminalSlotID,
            sessionRunner: terminal.sessionRunner,
            router: router,
            controlService: TerminalTelegramControlService(transportFactory: { transport }),
            primaryChannelDescription: "TUI",
            registry: TelegramChannelRegistry()
        )
        let notices = TelegramChannelNoticeRecorder()
        notices.install(on: channel)
        return TopicMember(terminal: terminal, channel: channel, notices: notices, commits: commits)
    }

    /// A relay whose cards `log` records instead of sending.
    private static func recordingRelay(_ log: TelegramRelayCardLog) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay(
            validateLease: { _ in true },
            send: { text, _, _ in await log.record(text) }
        )
    }

    /// A message of the agent `planner` of `room` to the operator.
    private static func agentMessage(room: String, text: String) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: room,
            sender: AgentSharedChat.Participant(id: "agent-1", name: "planner", kind: .agent),
            recipientIDs: [AgentSharedChat.operatorID(for: room)],
            text: text
        )
    }

    /// The message bodies of the relay cards `texts`, in order (a card is
    /// route, body and footer, separated by blank lines).
    private static func bodies(of texts: [String]) -> [String] {
        texts.map { $0.components(separatedBy: "\n\n").dropFirst().first ?? "" }
    }
}

/// A gate the test opens: ``pass()`` waits until ``open()`` and goes on at
/// once afterwards; ``waitForEntries(_:)`` returns once that many calls
/// reached it.
private actor TopicTestGate {
    private var isOpen = false
    private var entries = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        entries += 1
        let ready = entryWaiters.filter { $0.count <= entries }
        entryWaiters.removeAll { $0.count <= entries }
        for waiter in ready {
            waiter.continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        guard entries < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let continuations = held
        held = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

/// The Bot API double of the topic tests (``base``) behind a gate on
/// `editForumTopic`: a rename waits at ``gate`` until the test opens it, so
/// it stays in flight meanwhile.
private actor RenameGatedTransport: TelegramHTTPTransport {
    let base: TelegramChannelTestTransport
    let gate = TopicTestGate()

    init(base: TelegramChannelTestTransport) {
        self.base = base
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        if url.lastPathComponent == "editForumTopic" {
            await gate.pass()
        }
        return try await base.send(url: url, method: method, headers: headers, body: body, timeout: timeout)
    }
}
