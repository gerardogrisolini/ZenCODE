//
//  TerminalChatSessionHostTests.swift
//  ZenCODE
//
//  The terminal as one slot of a `ChatSessionHost`: the slot it opens, the
//  incarnation it follows, `/sessions new` from the launch profile and
//  `/sessions load` with the saved selection, the Telegram companion that
//  follows the slot with its topic renamed, the session id adopted in place,
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
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
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
            #expect(controller.presenter as? TerminalChatSessionPresenter === terminal.chatSessionPresenter)
            #expect(controller.host as? TerminalInteractionHost === terminal.interactionHost)
            #expect(controller.channelHooks === terminal)
            #expect(controller.commandRegistry.descriptor(forLine: "/setup")?.scope == .channel)
            #expect(controller.hostBinding?.slotID == slot)
            #expect(terminal.telegramCompanion.controller === controller)
            #expect(terminal.telegramSessionRouter === host.telegramRouter())

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

            // After `/setup` the first session is the one the setup interrupted.
            let resumed = TerminalChat(
                configuration: try environment.configuration(),
                stdinIsTerminal: false,
                sessionRunner: environment.makeRunner(),
                runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot(
                    sessionID: "terminal-before-setup", cacheKey: nil, history: [],
                    transcriptHistory: [], activePlan: nil, checkpointTree: nil, savedSessionName: nil
                )
            )
            #expect(resumed.sessionID == "terminal-before-setup")
            resumed.applyRuntimeSetupResumeSnapshotIfNeeded()
            #expect(resumed.sessionID == "terminal-before-setup")
            #expect(resumed.sessionHost.incarnation(in: resumed.terminalSlotID)?.sessionID == "terminal-before-setup")
            await host.shutdown()
            await resumed.sessionHost.shutdown()
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
            terminal.manualModelIDOverride = "other-model"
            terminal.manualThinkingSelectionOverride = .high
            terminal.selectedToolKeys = ["local"]
            terminal.selectedSkillIDs = ["skill"]
            terminal.activeSessionHistory = [AgentRuntimeMessage(role: .user, content: "Before")]
            await terminal.startNewSession()

            let next = terminal.chatSession
            #expect(next !== previous)
            #expect(terminal.sessionID != previousSessionID)
            #expect(terminal.sessionID.hasPrefix("terminal-"))
            #expect(next.selection == launchSelection)
            #expect(terminal.manualModelIDOverride == launchSelection.modelIDOverride)
            #expect(terminal.manualThinkingSelectionOverride == nil)
            #expect(terminal.selectedToolKeys.isEmpty)
            #expect(terminal.selectedSkillIDs.isEmpty)
            #expect(terminal.activeSessionHistory.isEmpty)
            #expect(previous.selection.modelIDOverride == "other-model")
            // The slot is the same and runs the new incarnation; the companion
            // and the sub-agent event handler follow it.
            #expect(terminal.terminalSlotID == slot)
            let incarnation = try #require(host.incarnation(in: slot))
            #expect(incarnation.controller === next)
            #expect(terminal.telegramCompanion.controller === next)
            #expect(terminal.didInstallSubAgentToolEventHandler == false)
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
            terminal.manualThinkingSelectionOverride = .high
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
            #expect(terminal.activeSessionHistory == history)
            // The selection is the saved session's, not the previous one's.
            #expect(terminal.manualModelIDOverride == "test-model")
            #expect(terminal.manualThinkingSelectionOverride == nil)
            #expect(terminal.selectedToolKeys.isEmpty)
            #expect(host.incarnation(in: slot)?.controller === next)
            #expect(terminal.telegramCompanion.controller === next)
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

    // MARK: - Telegram companion

    @Test
    nonisolated func theTelegramCompanionFollowsNewAndLoadedSessionsWithItsTopicRenamed() async throws {
        try await withEnvironment(telegram: Self.pairedTelegram) { environment in
            let transport = TerminalHostTopicTransport(botID: 9801, topicID: 701)
            let terminal = try environment.makeTerminal(stdinIsTerminal: true, transport: transport)
            let companion = try #require(terminal.telegramCompanion)
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let firstSessionID = terminal.sessionID

            await terminal.startTelegramControl()
            #expect(companion.isActive)
            #expect(companion.sessionTopic?.lease.key.topicID == 701)
            #expect(companion.sessionTopic?.lease.key.roomID == firstSessionID)
            let controlService = companion.controlService
            let router = companion.router

            // `/sessions new`: the companion moves to the new controller with
            // its link, and the topic follows the new session, renamed.
            await terminal.startNewSession()
            let newSessionID = terminal.sessionID
            #expect(newSessionID != firstSessionID)
            #expect(companion.controller === terminal.chatSession)
            #expect(companion.isActive)
            #expect(companion.controlService === controlService)
            #expect(companion.router === router)
            #expect(companion.sessionTopic?.lease.key.topicID == 701)
            #expect(companion.sessionTopic?.lease.key.roomID == newSessionID)
            #expect(companion.activeRouteLease == companion.sessionTopic?.lease)
            let newTopicName = TelegramSessionCompanion.defaultTopicName(
                workingDirectory: environment.workspace, sessionID: newSessionID
            )
            #expect(await transport.renamedTopics == [newTopicName])
            #expect(companion.sessionTopic?.name == newTopicName)
            #expect(await router.activeRoute(forRoomID: newSessionID)?.topicID == 701)
            #expect(await router.activeRoute(forRoomID: firstSessionID) == nil)

            // `/sessions load`: the same, named after the saved session.
            let saved = environment.savedSession(
                name: "kept", sessionID: "terminal-kept",
                history: [AgentRuntimeMessage(role: .user, content: "Saved")]
            )
            try await terminal.loadSavedSession(saved)
            #expect(companion.controller === terminal.chatSession)
            #expect(terminal.sessionID == "terminal-kept")
            #expect(companion.isActive)
            #expect(companion.sessionTopic?.lease.key.roomID == "terminal-kept")
            #expect(companion.sessionTopic?.name == "kept")
            #expect(await transport.renamedTopics == [newTopicName, "kept"])
            #expect(await router.activeRoute(forRoomID: "terminal-kept")?.topicID == 701)
            #expect(await router.activeRoute(forRoomID: newSessionID) == nil)

            await terminal.stopTaskGraphObserver()
            await companion.shutdown()
            await terminal.sessionHost.shutdown()
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
