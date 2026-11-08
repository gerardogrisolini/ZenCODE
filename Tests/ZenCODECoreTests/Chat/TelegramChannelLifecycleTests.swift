//
//  TelegramChannelLifecycleTests.swift
//  ZenCODE
//
//  The link of a ``TelegramChannel``: attach, detach, and shutdown with the
//  texts the terminal writes, the per-bot registry, the status and remote
//  texts, the poll-health notices, the route checks and the egress seams,
//  the endings of a turn with their texts, the channel's presenter (overview
//  dedup, notice capture, workflow notice texts), the route revoked under a
//  turn, and the consent the channel asks in the chat. The channel is the
//  slot's channel of a terminal whose output is captured; Telegram is a Bot
//  API double; every test runs in a UUID support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel lifecycle", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelLifecycleTests {
    private typealias Support = TelegramChannelTestSupport

    private static let activationText = "Telegram remote control is active.\nLinked chat: Test\n"

    // MARK: - Attach

    @Test
    func attachWithoutAUsableRouteThrowsTheTerminalText() async throws {
        let foreignRoute = AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "foreign-session")]
        )
        try await Support.withSupport(telegram: foreignRoute) {
            let botID = Support.uniqueBotID()
            let transport = TelegramChannelTestTransport(botID: botID)
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            do throws(TelegramChannelAttachError) {
                try await channel.attach()
                Issue.record("attach linked a session without its route")
            } catch {
                #expect(error == .invalidConfiguration)
                #expect(error.failureText
                    == "ZenCODE: Telegram configuration is invalid. Run zen --setup to pair Telegram again.\n")
            }
            #expect(recorder.notices.isEmpty)
            #expect(channel.activeRouteLease == nil)
            #expect(await transport.requestCount == 0)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func repeatedAttachRestartsTheServiceAndRegistersOnce() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            try await channel.attach()
            let firstEpoch = try #require(channel.controlState.wireLifecycleEpoch)
            try await channel.attach()
            let secondEpoch = try #require(channel.controlState.wireLifecycleEpoch)

            #expect(firstEpoch != secondEpoch)
            #expect(recorder.texts == [Self.activationText, Self.activationText])
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Detach and shutdown

    @Test
    func detachWithoutAttachTellsTheStopTextAndKeepsOtherRegistrations() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let attachedTerminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            try await attachedTerminal.telegramChannel.attach()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            await channel.detach()

            #expect(recorder.texts == ["Telegram remote control stopped.\n"])
            #expect(!channel.isActive)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await attachedTerminal.sessionHost.shutdown()
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func shutdownStopsTheServiceSilentlyAndUnregisters() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()

            await channel.shutdown()

            #expect(recorder.notices.isEmpty)
            #expect(!channel.isActive)
            #expect(await channel.controlService.currentState().isActive == false)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Registry

    @Test
    func registryFollowsIdentityAndHoldsChannelsWeakly() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let registry = TelegramChannelRegistry()
            var channel: TelegramChannel? = TelegramChannel(
                host: terminal.sessionHost,
                slotID: terminal.terminalSlotID,
                sessionRunner: terminal.sessionRunner,
                router: TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7, routes: []),
                controlService: TerminalTelegramControlService(
                    transportFactory: { TelegramChannelTestTransport(botID: 1) }
                ),
                primaryChannelDescription: "TUI",
                registry: registry
            )

            registry.register(try #require(channel), botID: 1)
            registry.register(try #require(channel), botID: 1)
            #expect(registry.attachedCount(botID: 1) == 1)
            registry.register(try #require(channel), botID: 2)
            #expect(registry.attachedCount(botID: 1) == 0)
            #expect(registry.attachedCount(botID: 2) == 1)
            registry.unregister(try #require(channel))
            registry.unregister(try #require(channel))
            #expect(registry.attachedCount(botID: 2) == 0)

            registry.register(try #require(channel), botID: 3)
            channel = nil
            #expect(registry.attachedCount(botID: 3) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Egress

    @Test
    func routeChecksFollowTheLinkAndTheRoute() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let stale = TerminalTelegramRouteLease(key: lease.key, generation: lease.generation + 1)

            #expect(channel.outgoingChatID(for: lease) == 42)
            #expect(channel.outgoingChatID(for: stale) == 42)
            #expect(await channel.validateLease(lease))
            #expect(!(await channel.validateLease(stale)))
            let fence = try #require(channel.wireFence(for: lease))
            #expect(fence.lease == lease)
            #expect(fence.lifecycleEpoch == channel.controlState.wireLifecycleEpoch)

            await channel.detach()
            #expect(channel.outgoingChatID(for: lease) == nil)
            #expect(!(await channel.validateLease(lease)))
            #expect(channel.wireFence(for: lease) == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func systemMessagesGoThroughTheSeamsBeforeTheService() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let routed = TelegramTestRecorder<String>()
            let legacy = TelegramTestRecorder<String>()

            channel.onTelegramRoutedSystemMessage = { text, chatID, topicID in
                routed.append("\(text)|\(chatID)|\(topicID.map(String.init) ?? "nil")")
                return true
            }
            channel.onTelegramSystemMessage = { text, chatID in
                legacy.append("\(text)|\(chatID)")
                return true
            }
            #expect(await channel.sendSystemMessage("routed", to: 42, lease: lease))
            channel.onTelegramRoutedSystemMessage = nil
            #expect(await channel.sendSystemMessage("legacy", to: 42, lease: lease))
            channel.onTelegramSystemMessage = nil
            #expect(await channel.sendSystemMessage("wire", to: 42, lease: lease))
            #expect(!(await channel.sendSystemMessage("other chat", to: 43, lease: lease)))
            await channel.sendSystemMessageIfLinked("linked", lease: lease)
            await channel.detach()
            await channel.sendSystemMessageIfLinked("unlinked", lease: lease)

            #expect(routed.values == ["routed|42|nil"])
            #expect(legacy.values == ["legacy|42"])
            #expect(await transport.sentTexts == ["wire", "linked"])
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func turnMessagesNeedTheLinkAndPreferTheDirectSeam() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let detachedLease = TerminalTelegramRouteLease(key: Support.defaultRouteKey, generation: 1)
            let direct = TelegramTestRecorder<String>()
            channel.onDirectTelegramTurnMessage = { payload, chatID in
                direct.append("\(payload.text)|\(chatID)")
                return true
            }
            #expect(!(await channel.sendTurnMessage(.authorization("detached"), to: 42, lease: detachedLease)))

            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            #expect(await channel.sendTurnMessage(.authorization("direct"), to: 42, lease: lease))
            await channel.sendTurnMessageIfLinked(.authorization("linked"), lease: lease)
            channel.onDirectTelegramTurnMessage = nil
            #expect(await channel.sendTurnMessage(.authorization("wire"), to: 42, lease: lease))

            #expect(direct.values == ["direct|42", "linked|42"])
            #expect(await transport.sentTexts == ["wire"])
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Presenter

    /// The presenter sends the overviews as plain text: a task graph once per
    /// signature within a turn, the sub-agent response blocks once each
    /// without their metadata, a completed sub-agent response as its
    /// Markdown; the task-graph dedup starts over at every turn, the
    /// sub-agent responses are never sent again in a later turn; an overview
    /// with no reporter sending the turn is dropped.
    @Test
    func overviewsAreSentOnceAsPlainTextAndTheResponseDedupOutlivesTheTurn() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            let request = ChatTurnRequest(
                prompt: "go",
                sessionConfiguration: await terminal.chatSession.turnSessionConfiguration(
                    for: .normal, responseLanguageSection: nil
                )
            )

            // No turn: nothing is sent, nothing is remembered.
            let silent = TelegramTestRecorder<String>()
            channel.onDirectTelegramTurnMessage = { payload, _ in
                silent.append(payload.text)
                return true
            }
            await channel.enqueueOverview(.tasks("📋 Task graph\n\nlate"), taskGraphSignature: "graph-9")
            #expect(silent.values.isEmpty)
            #expect(channel.publishedTaskGraphOverviewSignature != "graph-9")
            channel.onDirectTelegramTurnMessage = nil

            await presenter.turnWillStart(request)
            let log = TelegramTurnMessageLog()
            let reporter = await Self.installLog(log, on: channel)
            let snapshots = [Self.subAgentSnapshot(
                id: "worker", response: "**Delegated** answer.", partial: "Looking into it."
            )]
            let overview = ChatSubAgentOverview(snapshots: snapshots)
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 done"), taskGraphSignature: "graph-3")
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await reporter.flush()
            let messages = await log.messages
            #expect(messages.count == 4)
            #expect(Array(messages.prefix(2)) == ["📋 Task graph\n\n1 running", "📋 Task graph\n\n1 done"])
            for message in messages {
                #expect(!message.contains("\u{1B}["), "\(message)")
            }
            #expect(messages.dropFirst(2).first == "💬 worker:\n\nLooking into it.")
            let completed = try #require(messages.last)
            #expect(completed.hasSuffix("\n\n**Delegated** answer."))
            #expect(!completed.contains("worker:\n\nLooking"))
            // The heading loses the terminal's colors.
            #expect(TelegramChannelPresenter.subAgentResponsePayload(
                heading: "\u{1B}[36m   ✅ Response from worker:\u{1B}[0m\n", markdown: "**First** answer"
            )?.text == "✅ Response from worker:\n\n**First** answer")
            #expect(TelegramChannelPresenter.subAgentResponsePayload(heading: "💬 worker:", markdown: "  ") == nil)

            // The next turn starts a new task-graph dedup, and does not send
            // the same sub-agent responses again.
            await presenter.turnWillStart(request)
            let next = TelegramTurnMessageLog()
            let nextReporter = await Self.installLog(next, on: channel)
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await nextReporter.flush()
            #expect(await next.messages.count == 1)
            #expect(await next.messages.first == "📋 Task graph\n\n1 running")

            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Route validation

    /// A turn on a route lease is stopped as soon as the route is revoked:
    /// the turn's reporting ends and the link's route is forgotten.
    @Test
    func revokedRouteStopsTheTurn() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)

            // A turn that finishes stops its validation.
            await channel.beginTurn(adoptingStreamingBlock: false)
            #expect(channel.routeValidationTask != nil)
            await channel.endTurnReporting()
            #expect(channel.routeValidationTask == nil)

            await channel.beginTurn(adoptingStreamingBlock: false)
            #expect(channel.activeTurnLease == lease)
            #expect(channel.routeValidationTask != nil)
            await channel.router.refresh(
                linkedChatID: 42, ownerUserID: 7,
                routes: [AgentTelegramRouteManifest(roomID: "default", generation: lease.generation + 1)]
            )
            try await Support.waitUntil { channel.activeTurnLease == nil }
            #expect(channel.activeTurnLease == nil)
            #expect(channel.activeProgressReporter == nil)
            #expect(channel.routeValidationTask == nil)
            #expect(channel.activeRouteLease == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Consent

    /// Tools outside the gated set run without asking; a gated call while
    /// the channel has no link is denied with the terminal's text. Every
    /// destructive tool of the executor is gated.
    @Test
    func ungatedToolsRunAndAnUnlinkedChannelDenies() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            let authorizer = terminal.permissionAuthorizer.consentAuthorizer

            #expect(DirectToolExecutor.destructiveGatedToolNames.allSatisfy(
                ChatToolConsentAuthorizer.gatedToolNames.contains
            ))
            #expect(await authorizer.isAlreadyAuthorized(Self.readRequest))
            #expect(!(await authorizer.isAlreadyAuthorized(Self.deleteRequest())))
            #expect(await channel.requestToolConsent(Self.deleteRequest()) == nil)
            #expect(recorder.notices == [.init(
                text: "ZenCODE: Telegram cannot request permission for local.delete; the operation was denied.\n",
                channel: .failure
            )])
            await terminal.sessionHost.shutdown()
        }
    }

    /// The decision of the chat is told to the primary channel with the
    /// terminal's texts.
    @Test
    func permissionRepliesAreAnsweredAndToldToThePrimaryChannel() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()
            let lease = try #require(channel.activeRouteLease)

            for (command, expected, notice) in [
                ("/allow", ChatConsentDecision.allowOnce, "Telegram approved local.delete.\n"),
                ("/deny", .denyOnce, "Telegram denied local.delete.\n"),
            ] {
                let sentBefore = await transport.sentTexts.count
                let decision = Task { @ChatSessionActor in
                    await channel.requestToolConsent(Self.deleteRequest())
                }
                try await Support.waitUntil { await transport.sentTexts.count > sentBefore }
                let card = try #require(await transport.sentTexts.last)
                let requestID = try #require(Self.permissionRequestID(in: card))
                #expect(await channel.handlePermissionResponseIfNeeded("\(command) \(requestID)", lease: lease))
                #expect(await decision.value == expected)
                #expect(recorder.notices.last == .init(text: notice, channel: .system))
            }
            #expect(!(await channel.handlePermissionResponseIfNeeded("hello", lease: lease)))
            #expect(await channel.handlePermissionResponseIfNeeded("/allow nope", lease: lease))
            #expect(await transport.sentTexts.last == "No permission request is pending.")
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    private static func response(_ text: String) -> DirectAgentResponse {
        DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }

    private static var readRequest: AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.readFile", title: "Read Sources/Main.swift",
            kind: "read", command: "read Sources/Main.swift"
        )
    }

    private static func deleteRequest(_ path: String = "Sources/Old.swift") -> AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.delete", title: "Delete \(path)",
            kind: "destructive", command: "delete \(path)"
        )
    }

    private static func authorizationRequest(
        toolName: String, title: String, kind: String, command: String
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "terminal-test",
            toolCallID: "tool-call-test",
            toolName: toolName,
            title: title,
            kind: kind,
            command: command,
            workingDirectory: "/tmp/project"
        )
    }

    /// The request ID a permission request message carries.
    private static func permissionRequestID(in message: String) -> String? {
        message
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Request ID:") }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    /// Replaces the reporter of `channel`'s turn with one that records into
    /// `log`.
    @discardableResult
    private static func installLog(
        _ log: TelegramTurnMessageLog, on channel: TelegramChannel
    ) async -> TerminalTelegramTurnProgressReporter {
        await channel.activeProgressReporter?.revokeAndWait()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await log.append(message)
            return true
        }
        channel.activeProgressReporter = reporter
        return reporter
    }

    /// A sub-agent snapshot with one completed response and one block
    /// promoted at a tool boundary.
    private static func subAgentSnapshot(
        id: String, response: String, partial: String
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: id,
            role: "worker",
            status: .idle,
            pending: false,
            currentActivity: partial,
            currentActivityKind: .content,
            currentActivityRevision: 1,
            latestOutput: response,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )
    }
}

/// The messages a reporter delivered, in order.
actor TelegramTurnMessageLog {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}
