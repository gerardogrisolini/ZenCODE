//
//  TerminalChatSessionHostTests.swift
//  ZenCODE
//
//  The terminal as one slot of a `ChatSessionHost`: the slot it opens, the
//  incarnation it follows, `/sessions new` from the launch profile and
//  `/sessions load` with the saved selection, the slot's Telegram channel
//  that follows the slot with its topic renamed, the session id adopted in
//  place, the shell of the host with the slot Telegram drives,
//  and the shutdown that goes through the host. Every test runs in
//  directories named by UUIDs; nothing touches the real application state.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal chat in a session host", .serialized, .timeLimit(.minutes(2)))
struct TerminalChatSessionHostTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let backend = CapturingACPBackend()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-terminal-host-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func configuration() throws -> AgentConfiguration {
            try AgentConfiguration(
                hostedModelID: "test-model",
                explicitModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: workspace
            )
        }

        func makeRunner() -> AgentCoreSessionRunner {
            let backend = backend
            return AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
        }

        /// A terminal chat whose writes are captured and whose Telegram
        /// service uses `transport`; `host` when the composition root owns it.
        @ChatSessionActor
        func makeTerminal(
            stdinIsTerminal: Bool = false,
            host: ChatSessionHost? = nil,
            transport: (any TelegramHTTPTransport)? = nil
        ) throws -> TerminalChat {
            var transportFactory: (@Sendable () -> any TelegramHTTPTransport)?
            if let transport {
                transportFactory = { transport }
            }
            return TerminalChat(
                configuration: try configuration(),
                stdinIsTerminal: stdinIsTerminal,
                sessionRunner: host == nil ? makeRunner() : nil,
                sessionHost: host,
                telegramTransportFactory: transportFactory,
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false,
                    standardOutput: nil,
                    standardError: nil,
                    standardOutputIsTerminal: false,
                    standardErrorIsTerminal: false,
                    cursorTopology: .separate,
                    capturesWrites: true,
                    streamingFlushDelay: nil,
                    columnWidthProvider: { 100 }
                )
            )
        }

        /// A saved session of the workspace named `name`, with `history`.
        func savedSession(name: String, sessionID: String, history: [AgentRuntimeMessage]) -> TerminalSavedSession {
            TerminalSavedSession(
                name: name, sessionID: sessionID, cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillNames: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID)
            )
        }
    }

    /// Runs `body` on the chat actor with a private support directory (never
    /// the real `~/.zencode`), holding `telegram` when given, and a UUID-named
    /// workspace.
    private nonisolated func withEnvironment(
        telegram: AgentTelegramSettingsManifest? = nil,
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: telegram),
            to: environment.support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.terminal-session-host") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    /// Chat 42 of owner 7, paired on the shared route, as setup leaves it.
    private static let pairedTelegram = AgentTelegramSettingsManifest(
        enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
        linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
    )

    /// The text the terminal wrote so far.
    private static func capturedText(of terminal: TerminalChat) async -> String {
        await terminal.renderCoordinator.capturedWriteEvents().map(\.text).joined()
    }

    // MARK: - Slot

    @Test
    nonisolated func theTerminalOpensOneSlotInTheHostItIsGivenAndShutsDownThroughIt() async throws {
        try await withEnvironment { environment in
            let host = TerminalChat.makeSessionHost(
                configuration: try environment.configuration(),
                sessionRunner: environment.makeRunner()
            )
            #expect(host.sleepAssertionReason == "ZenCODE terminal session active")
            let terminal = try environment.makeTerminal(host: host)
            let slot = terminal.terminalSlotID
            let controller = terminal.chatSession

            // One slot, running the terminal's session from the start, with
            // the terminal's bindings and the host's runner, router, and
            // poller.
            #expect(terminal.sessionHost === host)
            #expect(terminal.sessionRunner === host.runner)
            #expect(host.slotIDs == [slot])
            let incarnation = try #require(host.incarnation(in: slot))
            #expect(incarnation.controller === controller)
            #expect(incarnation.reducer == nil)
            #expect(incarnation.sessionID == terminal.sessionID)
            #expect(terminal.sessionID.hasPrefix("terminal-"))
            // The controller presents and asks through the slot, which
            // forwards to the terminal while the terminal drives it.
            #expect(controller.presenter is ChatSlotPresenter)
            #expect((controller.presenter as? ChatSlotPresenter)?.activePresenter as? TerminalChatSessionPresenter
                === terminal.chatSessionPresenter)
            #expect(controller.host is ChatSlotInteractionHost)
            #expect(controller.channelHooks === terminal)
            #expect(controller.commandRegistry.descriptor(forLine: "/exit")?.scope == .channel)
            #expect(controller.hostBinding?.slotID == slot)
            #expect(host.activeChannel(in: slot) == .primary)
            #expect(host.telegramChannel(in: slot) == nil)

            // The id is set in place, through the host.
            terminal.sessionID = "adopted-session"
            #expect(controller.sessionID == "adopted-session")
            #expect(host.incarnation(in: slot)?.sessionID == "adopted-session")
            #expect(host.incarnation(in: slot)?.epoch == incarnation.epoch)
            #expect(terminal.chatSession === controller)

            // The shutdown goes through the host: the slot ends, the
            // controller is fenced, and the terminal keeps finding it.
            let turnToken = controller.beginTurnToken()
            await host.shutdown()
            #expect(host.isShutDown)
            #expect(host.slotIDs.isEmpty)
            #expect(controller.isCurrentTurn(turnToken, sessionID: "adopted-session") == false)
            #expect(terminal.chatSession === controller)
            #expect(terminal.sessionID == "adopted-session")
            terminal.sessionID = "late"
            #expect(terminal.sessionID == "adopted-session")
        }
    }

    @Test
    nonisolated func aTerminalWithoutAHostBuildsOneOverItsRunner() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            let host = terminal.sessionHost
            #expect(host.runner === terminal.sessionRunner)
            #expect(host.environment.explicitModelID == "test-model")
            #expect(host.sleepAssertionReason == "ZenCODE terminal session active")
            #expect(host.incarnation(in: terminal.terminalSlotID)?.controller === terminal.chatSession)

            // Every terminal starts a new session.
            let another = TerminalChat(
                configuration: try environment.configuration(),
                stdinIsTerminal: false,
                sessionRunner: environment.makeRunner()
            )
            #expect(another.sessionID.hasPrefix("terminal-"))
            #expect(another.sessionID != terminal.sessionID)
            #expect(another.sessionHost.incarnation(in: another.terminalSlotID)?.sessionID == another.sessionID)
            await host.shutdown()
            await another.sessionHost.shutdown()
        }
    }

    // MARK: - New and loaded sessions

    @Test
    nonisolated func aNewSessionIsANewIncarnationFromTheLaunchProfileThatTheTerminalFollows() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            let host = terminal.sessionHost
            let slot = terminal.terminalSlotID
            let launchSelection = ChatSessionController.initialSelection(for: host.environment)
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let previous = terminal.chatSession
            let previousSessionID = terminal.sessionID
            #expect(previous.taskGraphObserverTask != nil)

            // The operator changes the selection; the new session starts over.
            terminal.chatSession.selection.modelIDOverride = "other-model"
            terminal.chatSession.selection.thinkingOverride = .high
            terminal.selectedToolKeys = ["local"]
            terminal.chatSession.selection.skillNames = ["skill"]
            terminal.chatSession.history = [AgentRuntimeMessage(role: .user, content: "Before")]
            await terminal.startNewSession()

            let next = terminal.chatSession
            #expect(next !== previous)
            #expect(terminal.sessionID != previousSessionID)
            #expect(terminal.sessionID.hasPrefix("terminal-"))
            #expect(next.selection == launchSelection)
            #expect(terminal.chatSession.selection.modelIDOverride == launchSelection.modelIDOverride)
            #expect(terminal.chatSession.selection.thinkingOverride == nil)
            #expect(terminal.selectedToolKeys.isEmpty)
            #expect(terminal.chatSession.selection.skillNames.isEmpty)
            #expect(terminal.chatSession.history.isEmpty)
            #expect(previous.selection.modelIDOverride == "other-model")
            // The slot is the same and runs the new incarnation; the Telegram
            // channel and the routing of the sub-agent tool events follow it.
            #expect(terminal.terminalSlotID == slot)
            let incarnation = try #require(host.incarnation(in: slot))
            #expect(incarnation.controller === next)
            // A delegated tool event of the new session reaches the new
            // controller, and through it the terminal's delegated tool rows;
            // one of the replaced session is dropped.
            let read = DirectAgentToolCall(
                id: "read", name: "local.readFile",
                argumentsObject: ["path": "a.swift"], argumentsJSON: "{}"
            )
            await host.routeSubAgentToolEvent(DirectSubAgentToolEvent(
                agentID: "stale-worker", agentName: "stale-worker", toolCall: read,
                lifecycle: .started, rootSessionID: previousSessionID
            ))
            await host.routeSubAgentToolEvent(DirectSubAgentToolEvent(
                agentID: "worker", agentName: "worker", toolCall: read,
                lifecycle: .started, rootSessionID: terminal.sessionID
            ))
            let delegatedRows = await terminal.renderCoordinator.subAgentToolPresentationSnapshot()
            #expect(delegatedRows.presentationsByAgentID["worker"]?.toolCall.id == "read")
            #expect(delegatedRows.presentationsByAgentID["stale-worker"] == nil)
            #expect(await terminal.sessionRunner.snapshotSession(id: terminal.sessionID) != nil)
            #expect(await terminal.sessionRunner.snapshotSession(id: previousSessionID) == nil)
            #expect(await Self.capturedText(of: terminal).contains("Started a new session."))

            // The previous controller is fenced: its observer was stopped
            // before the switch, the new one runs, and a graph of the old
            // session publishes nothing through the terminal.
            #expect(previous.taskGraphObserverTask == nil)
            #expect(next.taskGraphObserverTask != nil)
            let reserved = await terminal.reserveTaskGraphOverviewPublication().revision
            _ = try await terminal.sessionRunner.taskOrchestrator.createGraph(
                sessionID: previousSessionID,
                id: "old-graph",
                source: .manual,
                state: .active,
                tasks: [
                    TaskDefinition(id: "old-a", title: "Old task A"),
                    TaskDefinition(id: "old-b", title: "Old task B"),
                ]
            )
            try await Task.sleep(for: .milliseconds(500))
            #expect(await terminal.reserveTaskGraphOverviewPublication().revision == reserved + 1)
            #expect(previous.taskGraphObserverTask == nil)
            // While a graph of the new session is observed.
            let observed = await terminal.reserveTaskGraphOverviewPublication().revision
            _ = try await terminal.sessionRunner.taskOrchestrator.createGraph(
                sessionID: terminal.sessionID,
                id: "new-graph",
                source: .manual,
                state: .active,
                tasks: [
                    TaskDefinition(id: "new-a", title: "New task A"),
                    TaskDefinition(id: "new-b", title: "New task B"),
                ]
            )
            try await Task.sleep(for: .milliseconds(500))
            #expect(await terminal.reserveTaskGraphOverviewPublication().revision > observed + 1)

            await terminal.stopTaskGraphObserver()
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aLoadedSessionIsANewIncarnationWithTheSavedSelection() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            let host = terminal.sessionHost
            let slot = terminal.terminalSlotID
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let previous = terminal.chatSession
            let previousSessionID = terminal.sessionID
            terminal.chatSession.selection.thinkingOverride = .high
            let history = [
                AgentRuntimeMessage(role: .user, content: "Saved question"),
                AgentRuntimeMessage(role: .assistant, content: "Saved answer"),
            ]
            let saved = environment.savedSession(name: "kept", sessionID: "terminal-kept", history: history)

            try await terminal.loadSavedSession(saved)

            let next = terminal.chatSession
            #expect(next !== previous)
            #expect(terminal.sessionID == "terminal-kept")
            #expect(terminal.activeSavedSessionName == "kept")
            #expect(terminal.chatSession.history == history)
            // The selection is the saved session's, not the previous one's.
            #expect(terminal.chatSession.selection.modelIDOverride == "test-model")
            #expect(terminal.chatSession.selection.thinkingOverride == nil)
            #expect(terminal.selectedToolKeys.isEmpty)
            #expect(host.incarnation(in: slot)?.controller === next)
            #expect(previous.taskGraphObserverTask == nil)
            #expect(next.taskGraphObserverTask != nil)
            #expect(await terminal.sessionRunner.snapshotSession(id: "terminal-kept") != nil)
            #expect(await terminal.sessionRunner.snapshotSession(id: previousSessionID) == nil)
            let text = await Self.capturedText(of: terminal)
            #expect(text.contains("Restored transcript:"))
            #expect(text.contains("Saved question"))
            #expect(text.contains("Loaded session: kept"))
            // The transcript is replayed before the loaded notice, as always.
            let replay = try #require(text.range(of: "Restored transcript:"))
            let loaded = try #require(text.range(of: "Loaded session: kept"))
            #expect(replay.lowerBound < loaded.lowerBound)

            await terminal.stopTaskGraphObserver()
            await host.shutdown()
        }
    }

    // MARK: - Telegram channel

    /// The slot's Telegram channel belongs to the slot: `/sessions new` and
    /// `/sessions load` keep the link, the control service, and the router,
    /// and the session's topic follows the new session, renamed; the slot
    /// stays driven by Telegram across both.
    @Test
    nonisolated func theTelegramChannelFollowsNewAndLoadedSessionsWithItsTopicRenamed() async throws {
        try await withEnvironment(telegram: Self.pairedTelegram) { environment in
            let transport = TerminalHostTopicTransport(botID: 9801, topicID: 701)
            let terminal = try environment.makeTerminal(stdinIsTerminal: true, transport: transport)
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let firstSessionID = terminal.sessionID
            let host = terminal.sessionHost
            let slot = terminal.terminalSlotID

            TelegramChannelTestSupport.standInForInteractiveLoop(of: terminal)
            await terminal.startTelegramControl()
            let channel = try #require(host.telegramChannel(in: slot))
            #expect(channel.isActive)
            #expect(host.activeChannel(in: slot) == .telegram)
            #expect(channel.sessionTopic?.lease.key.topicID == 701)
            #expect(channel.sessionTopic?.lease.key.roomID == firstSessionID)
            let controlService = channel.controlService
            let router = channel.router

            // `/sessions new`: the slot's channel keeps its link, and the
            // topic follows the new session, renamed.
            await terminal.startNewSession()
            let newSessionID = terminal.sessionID
            #expect(newSessionID != firstSessionID)
            #expect(host.telegramChannel(in: slot) === channel)
            #expect(host.activeChannel(in: slot) == .telegram)
            #expect(channel.controller === terminal.chatSession)
            #expect(channel.isActive)
            #expect(channel.controlService === controlService)
            #expect(channel.router === router)
            #expect(channel.sessionTopic?.lease.key.topicID == 701)
            #expect(channel.sessionTopic?.lease.key.roomID == newSessionID)
            #expect(channel.activeRouteLease == channel.sessionTopic?.lease)
            let newTopicName = TelegramChannel.defaultTopicName(
                workingDirectory: environment.workspace, sessionID: newSessionID
            )
            #expect(await transport.renamedTopics == [newTopicName])
            #expect(channel.sessionTopic?.name == newTopicName)
            #expect(await router.activeRoute(forRoomID: newSessionID)?.topicID == 701)
            #expect(await router.activeRoute(forRoomID: firstSessionID) == nil)

            // `/sessions load`: the same, named after the saved session.
            let saved = environment.savedSession(
                name: "kept", sessionID: "terminal-kept",
                history: [AgentRuntimeMessage(role: .user, content: "Saved")]
            )
            try await terminal.loadSavedSession(saved)
            #expect(channel.controller === terminal.chatSession)
            #expect(terminal.sessionID == "terminal-kept")
            #expect(channel.isActive)
            #expect(host.activeChannel(in: slot) == .telegram)
            #expect(channel.sessionTopic?.lease.key.roomID == "terminal-kept")
            #expect(channel.sessionTopic?.name == "kept")
            #expect(await transport.renamedTopics == [newTopicName, "kept"])
            #expect(await router.activeRoute(forRoomID: "terminal-kept")?.topicID == 701)
            #expect(await router.activeRoute(forRoomID: newSessionID) == nil)

            await terminal.stopTaskGraphObserver()
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Shell

    /// The shell of the terminal's host: the configured Telegram link, read
    /// from the settings, the slot Telegram drives from `/telegram on` to
    /// `/telegram off`, with the summary of the reducer the handover created,
    /// and the poller that runs meanwhile.
    @Test
    nonisolated func theShellShowsTheTerminalSlotTelegramDrivesAndThePoller() async throws {
        try await withEnvironment(telegram: Self.pairedTelegram) { environment in
            let transport = TerminalHostTopicTransport(botID: 9802, topicID: 702)
            let terminal = try environment.makeTerminal(stdinIsTerminal: true, transport: transport)
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let host = terminal.sessionHost
            let slot = terminal.terminalSlotID

            await host.refreshShellSnapshot()
            #expect(host.shellSnapshot.telegram.isConfigured)
            #expect(host.shellSnapshot.telegram.isPolling == false)
            #expect(host.shellSnapshot.telegram.drivenSlots.isEmpty)
            // The terminal publishes no state: its summary comes from the
            // incarnation, and no reducer is created for the shell.
            #expect(host.reducer(in: slot) == nil)
            #expect(host.shellSnapshot.sessions[slot]?.workspace == environment.workspace)
            #expect(host.shellSnapshot.sessions[slot]?.activeChannel == .local)
            #expect(host.shellSnapshot.savedSessions[environment.workspace] == [])

            TelegramChannelTestSupport.standInForInteractiveLoop(of: terminal)
            await terminal.startTelegramControl()
            #expect(host.shellSnapshot.telegram.drivenSlots == [slot])
            let reducer = try #require(host.reducer(in: slot))
            #expect(host.shellSnapshot.sessions[slot] == reducer.snapshot.summary)
            for _ in 0 ..< 400 where !host.shellSnapshot.telegram.isPolling {
                await host.refreshShellSnapshot()
                if !host.shellSnapshot.telegram.isPolling {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            #expect(host.shellSnapshot.telegram.isPolling)

            await terminal.stopTelegramControl()
            #expect(host.shellSnapshot.telegram.drivenSlots.isEmpty)
            #expect(host.reducer(in: slot) == nil)
            // The poll ends with the link's last subscriber.
            for _ in 0 ..< 400 where host.shellSnapshot.telegram.isPolling {
                await host.refreshShellSnapshot()
                if host.shellSnapshot.telegram.isPolling {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            #expect(host.shellSnapshot.telegram.isPolling == false)

            await terminal.stopTaskGraphObserver()
            await terminal.sessionHost.shutdown()
            #expect(host.shellSnapshot.sessions.isEmpty)
        }
    }
}

/// The transport of a bot in Threaded mode: getMe reports `botID` with
/// `has_topics_enabled`, createForumTopic answers `topicID`, editForumTopic
/// records the name, getUpdates waits until it is cancelled, and every other
/// method succeeds.
private actor TerminalHostTopicTransport: TelegramHTTPTransport {
    private let botID: Int64
    private let topicID: Int
    private(set) var renamedTopics: [String] = []

    init(botID: Int64, topicID: Int) {
        self.botID = botID
        self.topicID = topicID
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch url.lastPathComponent {
        case "getMe":
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot","has_topics_enabled":true}}"#.utf8
            ))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case "createForumTopic":
            let topic: [String: Any] = [
                "message_thread_id": topicID, "name": object?["name"] as? String ?? "",
            ]
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "result": topic]))
        case "editForumTopic":
            renamedTopics.append(object?["name"] as? String ?? "")
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "sendMessage":
            return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"},"date":0}}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}
