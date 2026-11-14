//
//  TelegramTUITests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct TelegramTUITests {
    private static var testTelegramLease: TerminalTelegramRouteLease {
        .init(key: .init(chatID: 42, userID: 7, roomID: "terminal-room"), generation: 1)
    }

    /// Installs the test route of `roomID` (the terminal's session by
    /// default) in the router of the terminal's Telegram channel and makes
    /// it the link's route.
    private static func installTestRoute(
        on terminal: TerminalChat, roomID: String? = nil
    ) async -> TerminalTelegramRouteLease {
        let roomID = roomID ?? terminal.sessionID
        let route = AgentTelegramRouteManifest(roomID: roomID, generation: 1)
        await terminal.telegramChannel.router.refresh(
            linkedChatID: 42, ownerUserID: 7, routes: [route]
        )
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: roomID), generation: 1
        )
        terminal.telegramChannel.activeRouteLease = lease
        return lease
    }

    @Test
    func telegramSettingsFailClosedUnlessSchema2OwnerAndRoutesAreComplete() throws {
        let fixtures: [(String, Bool)] = [
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":1,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":3,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"routingVersion":2,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":2,"routes":[{"roomID":"one","lifecycle":"active","generation":1},{"roomID":"two","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":2,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, true)
        ]

        for (json, expectedEnabled) in fixtures {
            let settings = try JSONDecoder().decode(
                AgentTelegramSettingsManifest.self, from: Data(json.utf8)
            )
            #expect(settings.isEnabled == expectedEnabled)
        }
    }

    /// Round trip through the real settings store, isolated in a temporary
    /// support directory: the `default` route plus more than 32 closed topic
    /// routes is pruned to the 32 newest inactive topics, a session topic is
    /// rebound, the JSON keeps the same route keys and schema, the
    /// configuration stays enabled and a router rebuilt from disk honours the
    /// new lease while rejecting the previous one.
    @Test
    nonisolated func telegramRoutesPrunedAndReboundRoundTripThroughTheSettingsStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-prune-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let topicless = AgentTelegramRouteManifest(roomID: "default")
        let closed = (1...40).map { (topic: Int) in
            AgentTelegramRouteManifest(topicID: topic, roomID: "closed-\(topic)", lifecycle: .closed, generation: 2)
        }
        let routes = [topicless] + closed + [AgentTelegramRouteManifest(topicID: 41, roomID: "session-a")]

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true, botToken: "123456:ABCDEF",
                    linkedChatID: 42, ownerUserID: 7, routes: routes
                )
            ))
            let router = TerminalTelegramSessionRouter(
                linkedChatID: 42, ownerUserID: 7, routes: routes,
                persist: { ownerUserID, committed in
                    try AgentSettingsManifestStore.saveTelegramRoutes(committed, ownerUserID: ownerUserID)
                }
            )

            try await router.prune(keepingInactive: 32)
            let pruned = try #require(try AgentSettingsManifestStore.loadRequired().telegram)
            #expect(pruned.isEnabled)
            #expect(pruned.routes.count == 34)
            let previous = try await router.resolve(chatID: 42, userID: 7, topicID: 41)
            let rebound = try await router.rebind(previous, toRoomID: "session-b")

            let settings = try #require(try AgentSettingsManifestStore.loadRequired().telegram)
            let expected: [AgentTelegramRouteManifest] = [topicless] + closed.suffix(32) + [
                AgentTelegramRouteManifest(topicID: 41, roomID: "session-b", generation: 2),
            ]
            #expect(settings.isEnabled)
            #expect(settings.routes == expected)
            #expect(await router.snapshot() == expected)

            let data = try Data(contentsOf: AgentSettingsManifestStore.settingsURL())
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let telegram = try #require(object["telegram"] as? [String: Any])
            let storedRoutes = try #require(telegram["routes"] as? [[String: Any]])
            #expect(telegram["routingVersion"] as? Int == 2)
            #expect(storedRoutes.count == 34)
            #expect(storedRoutes.allSatisfy {
                Set($0.keys).isSubset(of: ["topicID", "roomID", "lifecycle", "generation"])
            })
            let expectedTopics: [Int?] = [nil] + (9...41).map { $0 }
            #expect(storedRoutes.map { $0["topicID"] as? Int } == expectedTopics)

            let reloaded = TerminalTelegramSessionRouter(
                linkedChatID: settings.linkedChatID, ownerUserID: settings.ownerUserID,
                routes: settings.routes
            )
            try await reloaded.validate(rebound)
            await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
                try await reloaded.validate(previous)
            }
            #expect(await reloaded.activeRoute(forRoomID: "session-b")?.topicID == 41)
            await #expect(throws: TerminalTelegramRouteDenial.routeClosed) {
                try await reloaded.resolve(chatID: 42, userID: 7, topicID: 9)
            }
            // A pruned topic is unknown again and falls back to `default`.
            let fallback = try await reloaded.resolve(chatID: 42, userID: 7, topicID: 8)
            #expect(fallback.key.roomID == "default")
            #expect(fallback.effectiveMessageThreadID == 8)
        }
    }

    @Test
    func settingsManifestPreservesTokenOnlyTelegramConfigurationWithoutEnablingCommand() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.telegram?.isConfigured == true)
        #expect(decoded.telegram?.isEnabled == false)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == nil)
    }

    @Test
    func telegramCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false,
                telegramEnabled: false,
                ds4ModelEnabled: false
            )
        ).map(\.command)
        let enabledCommands = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false,
                telegramEnabled: true,
                ds4ModelEnabled: false
            )
        ).map(\.command)

        #expect(!disabledCommands.contains("/agents-md"))
        #expect(!disabledCommands.contains("/make-agents"))
        #expect(!enabledCommands.contains("/agents-md"))
        #expect(!enabledCommands.contains("/make-agents"))
        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
    }

    @Test
    func telegramCommandActionAcceptsOnlyOnOffAndBareStatus() {
        #expect(TerminalTelegramCommandAction(argument: "") == .status)
        #expect(TerminalTelegramCommandAction(argument: " on ") == .turnOn)
        #expect(TerminalTelegramCommandAction(argument: "off") == .turnOff)
        #expect(TerminalTelegramCommandAction(argument: "status") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "start") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "stop") == .usage)
    }

    @Test
    func telegramStartPayloadIsRemoteCommandNotPrompt() {
        #expect(TerminalTelegramRemoteCommand(text: "/start") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start@zencode_bot 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/help") == .help)
        #expect(TerminalTelegramRemoteCommand(text: "ciao") == nil)
        #expect(TelegramChannel.commandWithoutBotMention("/review@zencode_bot routing") == "/review routing")
        #expect(TelegramChannel.commandWithoutBotMention("person@example.com") == "person@example.com")
    }

    @Test
    func telegramReturnsImmediateCoordinatorCommandOutputAndBotAddressedHelp() async throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")
        terminal.telegramChannel.linkedChatID = 42
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        let lease = await Self.installTestRoute(on: terminal)
        let messages = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { message, chatID in
            #expect(chatID == 42)
            messages.withLock { $0.append(message) }
            return true
        }

        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/review@zencode_bot routing", lease: lease
        ) else {
            Issue.record("Bot-addressed /review should be handled immediately when nothing is reviewable")
            return
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/help@zencode_bot", lease: lease
        ) else {
            Issue.record("Bot-addressed /help should remain a remote command")
            return
        }

        let output = messages.withLock { $0 }
        #expect(output.contains { $0.contains("No tracked session file changes to review") })
        #expect(output.contains { $0.contains("/review [focus]") })
    }

    @Test
    func immediateCommandUsesEffectiveFallbackTopic() async throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false
        )
        let route = AgentTelegramRouteManifest(roomID: terminal.sessionID)
        await terminal.telegramChannel.router.refresh(
            linkedChatID: 42, ownerUserID: 7, routes: [route]
        )
        let lease = try await terminal.telegramChannel.router.resolve(
            chatID: 42, userID: 7, topicID: 44
        )
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        let routed = Mutex<(Int64, Int?)?>(nil)
        terminal.telegramChannel.onTelegramRoutedSystemMessage = { _, chatID, topicID in
            routed.withLock { $0 = (chatID, topicID) }
            return true
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/status", lease: lease
        ) else {
            Issue.record("Expected immediate Telegram status command")
            return
        }
        let destination = try #require(routed.withLock { $0 })
        #expect(destination.0 == 42)
        #expect(destination.1 == 44)
    }

    @Test
    func telegramRoutesPlanGoalReviewAndClarificationWithoutAbsorbingCommandsOrMentions() async throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/telegram-plan-routing-\(UUID().uuidString)",
            isDirectory: true
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")
        let lease = await Self.installTestRoute(on: terminal, roomID: terminal.sessionID)
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
                try await terminal.sessionRunner.taskOrchestrator.registerSession(
            id: terminal.sessionID,
            workingDirectory: workingDirectory
        )

        guard case let .startTurn(prompt: startPrompt, purpose: startPurpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "/plan route all frontends", lease: lease
            ) else {
            Issue.record("Telegram /plan should use the local hidden planning router")
            return
        }
        #expect(startPrompt.contains("Planning goal requested by the user: route all frontends"))
        #expect(startPurpose == .plan(originalGoal: "route all frontends"))

        var discussion = try #require(terminal.chatSession.planBrainstorming)
        discussion.recordPlannerOutput(
            "Planner questions\n1. Keep it runtime-only?",
            agentID: "planner-telegram",
            revision: 1
        )
        terminal.chatSession.planBrainstorming = discussion

        guard case let .startTurn(prompt: replyPrompt, purpose: replyPurpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "Yes, runtime-only.", lease: lease
            ) else {
            Issue.record("A Telegram plain-text reply should continue the Planner")
            return
        }
        #expect(replyPurpose == .plan(originalGoal: "route all frontends"))
        #expect(replyPrompt.contains("planner-telegram"))
        #expect(replyPrompt.contains("Yes, runtime-only."))

        // Restore an awaiting state and verify higher-priority remote commands
        // and mentions are not consumed as planning answers.
        discussion = try #require(terminal.chatSession.planBrainstorming)
        discussion.recordPlannerOutput(
            "Planner questions\n1. Another choice?",
            agentID: "planner-telegram",
            revision: 2
        )
        terminal.chatSession.planBrainstorming = discussion
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/help", lease: lease
        ) else {
            Issue.record("Telegram /help must retain remote-command precedence")
            return
        }
        #expect(terminal.chatSession.planBrainstorming?.isAwaitingReply == true)
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "@coordinator keep this separate", lease: lease
        ) else {
            Issue.record("Telegram live mentions must retain mention routing precedence")
            return
        }
        #expect(terminal.chatSession.planBrainstorming?.isAwaitingReply == true)

        terminal.chatSession.planBrainstorming = nil
        guard case let .startTurn(prompt: goalPrompt, purpose: goalPurpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "/goal implement parity", lease: lease
            ) else {
            Issue.record("Telegram /goal should create a workflow and use its hidden prompt")
            return
        }
        let goalGraphID = try #require(terminal.chatSession.activeWorkflow?.graphID)
        #expect(goalPurpose == .workflow(
            originalGoal: "implement parity",
            graphID: goalGraphID
        ))
        #expect(goalPrompt.contains("Goal: implement parity"))

        guard case let .startTurn(prompt: reviewPrompt, purpose: reviewPurpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "/review focus on routing", lease: lease
            ) else {
            Issue.record("Telegram /review should use the local hidden review router")
            return
        }
        #expect(reviewPurpose == .review)
        #expect(reviewPrompt.contains("Review focus requested by the user: focus on routing"))
        #expect(reviewPrompt.contains("role \"Reviewer\""))
    }

    @Test(arguments: [false, true])
    func telegramRepliesContinueAnOpenWorkflowOnTheSameGraph(subAgentsEnabled: Bool) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-telegram-workflow",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        if subAgentsEnabled {
            terminal.selectedToolKeys.insert("sub-agents")
        } else {
            terminal.selectedToolKeys.remove("sub-agents")
        }
        let lease = await Self.installTestRoute(on: terminal, roomID: terminal.sessionID)
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()

        guard case .startTurn = await terminal.telegramChannel.lineAction(for:
            "/goal implement parity", lease: lease
        ) else {
            Issue.record("Telegram /goal should create a workflow and use its hidden prompt")
            return
        }
        let graphID = try #require(terminal.chatSession.activeWorkflow?.graphID)

        // Nothing is armed yet: an ordinary Telegram message stays ordinary.
        guard case .runPrompt = await terminal.telegramChannel.lineAction(for:
            "unrelated", lease: lease
        ) else {
            Issue.record("Telegram must not capture messages before the workflow asks")
            return
        }

        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
        _ = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: graphID, state: .awaitingUser,
            message: "Which surface should I cover first?", expectedRevision: graph.revision
        )
        await terminal.recordWorkflowTurnOutcome(
            graphID: graphID,
            coordinatorMessage: "Which surface should I cover first?"
        )
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == true)

        guard case let .startTurn(prompt: prompt, purpose: purpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "Start with Telegram", lease: lease
            ) else {
            Issue.record("a Telegram reply should continue the open workflow")
            return
        }
        #expect(purpose == .workflow(originalGoal: "implement parity", graphID: graphID))
        #expect(prompt.contains("Active workflow task graph: \(graphID)"))
        #expect(prompt.contains("Start with Telegram"))
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == false)

        // A slash command still takes precedence over the continuation.
        let resumed = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
        _ = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: graphID, state: .awaitingUser,
            message: "Anything else?", expectedRevision: resumed.revision
        )
        await terminal.recordWorkflowTurnOutcome(
            graphID: graphID,
            coordinatorMessage: "Anything else?"
        )
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/status", lease: lease
        ) else {
            Issue.record("Telegram commands must keep precedence over the workflow reply")
            return
        }
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == true)
        #expect(terminal.telegramChannel.remoteHelpText().contains(
            "While /goal is waiting for an answer"
        ))
    }

    @Test
    func telegramPlanApprovalConsumesTheDescriptiveGoalReply() async throws {
        let terminal = TerminalChat(configuration: try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZenCODE-telegram-plan-\(UUID().uuidString)", isDirectory: true)
        ), stdinIsTerminal: false)
        let lease = await Self.installTestRoute(on: terminal, roomID: terminal.sessionID)
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "old planner goal",
            consolidatedText: "Implement the Telegram plan approval flow."
        )

        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/plan approve", lease: lease
        ) else {
            Issue.record("Telegram /plan approve should first request a Goal")
            return
        }
        guard case let .startTurn(prompt: prompt, purpose: purpose, locksResponseLanguage: _) =
            await terminal.telegramChannel.lineAction(for:
                "Keep the approved plan's objective explicit", lease: lease
            ) else {
            Issue.record("Telegram should consume the Goal reply and start implementation")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Goal: Keep the approved plan's objective explicit"))
        #expect(terminal.activePlan?.originalGoal == "Keep the approved plan's objective explicit")
        #expect(terminal.activePlan?.isApproved == true)
    }

    @Test
    func telegramProgressReporterRequiresActiveTelegramSession() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        terminal.telegramChannel.controlState.isActive = false
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) == nil)

        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = nil
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) == nil)
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) != nil)
    }

    @Test
    func telegramEgressRestoreRejectsAmbiguousOrForeignRoomRoutes() async throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false
        )
        let settings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: "123456:ABCDEF",
            linkedChatID: 42,
            ownerUserID: 7,
            routes: [
                AgentTelegramRouteManifest(roomID: "another-session")
            ]
        )

        #expect(await terminal.telegramChannel.egressRoute(
            settings: settings,
            linkedChatID: 42
        ) == nil)
    }

    /// A generating session can be blocked on remote tool consent, so the busy
    /// gate must let that correlated reply reach the permission broker.
    @Test
    func busyTelegramSessionStillAcceptsAuthorizationReply() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let collector = TelegramTestMessageCollector()
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Busy.swift",
            kind: "destructive",
            command: "delete Sources/Busy.swift"
        )
        let authorization = Task {
            await terminal.telegramChannel.permissionBroker.authorize(
                request, lease: lease
            ) { message in
                await collector.append(message)
                return true
            }
        }
        let requestMessage = await collector.firstMessage()
        let requestID = try #require(Self.telegramPermissionRequestID(in: requestMessage))
        let busyNotices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            busyNotices.withLock { $0.append(text) }
            return true
        }
        // The session generates: the host holds a prompt reservation.
        let reservation = try terminal.sessionHost.reservePrompt(in: terminal.terminalSlotID)
        defer { terminal.sessionHost.releasePrompt(reservation) }

        _ = await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "unrelated prompt", voice: nil,
                messageID: 98, chatTitle: nil, username: nil
            )
        )

        let didQueue = await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "/deny \(requestID)", voice: nil,
                messageID: 99, chatTitle: nil, username: nil
            )
        )

        #expect(!didQueue)
        #expect(terminal.telegramChannel.promptQueue.isEmpty)
        #expect(busyNotices.withLock { messages in
            messages.filter { $0.contains("was not queued") }.count
        } == 1)
        #expect(await authorization.value == .denied)
    }

    @Test
    func telegramUnknownSlashAndArgumentedRemoteCommandsAreRejected() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let notices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }

        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/bogus now", lease: lease
        ) else {
            Issue.record("Unknown slash command must not reach the model")
            return
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/status foo", lease: lease
        ) else {
            Issue.record("/status with an argument must not run or reach the model")
            return
        }
        guard case .runPrompt = await terminal.telegramChannel.lineAction(for:
            "status report please", lease: lease
        ) else {
            Issue.record("Plain text starting with an alias word stays a prompt")
            return
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/help@zencode_bot", lease: lease
        ) else {
            Issue.record("/help@bot should resolve")
            return
        }
        let delivered = notices.withLock { $0 }
        #expect(delivered.count == 3)
        #expect(delivered[0].hasPrefix("ZenCODE: unknown command '/bogus'. Available commands: /help"))
        #expect(delivered[1] == "ZenCODE: /status does not accept arguments.")
        #expect(delivered[2].contains("Remote commands:"))
    }

    private static func activeTelegramTerminal(
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil
    ) async throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            permissionAuthorizer: permissionAuthorizer,
            telegramTransportFactory: nil
        )
        terminal.telegramChannel.linkedChatID = 42
        terminal.telegramChannel.controlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil,
            wireLifecycleEpoch: UUID()
        )
        terminal.telegramChannel.activeRouteLease = await Self.installTestRoute(on: terminal)
        return terminal
    }

    @Test
    func telegramProgressReporterPublishesAllowedPayloadsInFIFOOrder() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }

        await reporter.enqueue(.tasks("📋 Task graph\n\n1 running"))
        #expect(await reporter.send(.authorization("🔐 Permission required\nRequest ID: A1")))
        await reporter.enqueue(.subAgentResponse("Reviewer completed."))
        await reporter.enqueue(.agentResponse("*ZenCODE completed*\n\nDone."))
        await reporter.enqueue(.summary("🪬 Summary: 1 file  +1 -0"))
        await reporter.flush()

        #expect(await collector.allMessages() == [
            "📋 Task graph\n\n1 running",
            "🔐 Permission required\nRequest ID: A1",
            "Reviewer completed.",
            "*ZenCODE completed*\n\nDone.",
            "🪬 Summary: 1 file  +1 -0"
        ])
    }

    @Test
    func telegramFinalizationDeliversResponseBeforeSummary() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await collector.append(message)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.telegramChannel.activeProgressReporter?.enqueue(.tasks("📋 Task graph"))
        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 3)
        #expect(messages[1] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[2].hasPrefix("🪬 Summary:"))
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
    }

    @Test
    func telegramFinalizationDeliversOutcomeAndSummaryWithoutReporter() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        terminal.telegramChannel.onDirectTelegramTurnMessage = { payload, chatID in
            #expect(chatID == 42)
            await collector.append(payload.text)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 2)
        #expect(messages[0] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[1].hasPrefix("🪬 Summary:"))
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
        #expect(terminal.telegramChannel.activeTurnLease == nil)
    }

    // MARK: - Root responses in the chat

    @Test
    func telegramAggregatesRootResponseDeltasIntoOneMessageAtToolBoundary() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Inspecting ")
        await terminal.telegramChannel.appendRootResponseDelta("the reporter")
        await terminal.telegramChannel.appendRootResponseDelta(" first.\n")
        #expect((await collector.allMessages()).isEmpty)

        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await reporter.flush()

        #expect((await collector.allMessages()) == ["Inspecting the reporter first."])
    }

    @Test
    func telegramDoesNotDuplicateTrailingRootResponseAsFinalOutcome() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Intermediate.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        // Trailing content that no tool call closes is the final response.
        await terminal.telegramChannel.appendRootResponseDelta("All done, ")
        await terminal.telegramChannel.appendRootResponseDelta("everything works.")

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("All done, everything works."), fileChangeSummary: nil)

        #expect(
            (await collector.allMessages()) == [
                "Intermediate.",
                "All done, everything works."
            ]
        )
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
    }

    /// Reasoning reaches the chat only through the channel's presenter, as a
    /// completed block, and a tool call only as its title and outcome (see
    /// `TelegramChannelTurnActivityTests`). What the terminal renders on its
    /// own, its reasoning with the tool identity it mentions, has no path to
    /// the chat, and the responses travel without any tool detail.
    @Test
    func telegramSendsTheResponsesButNotTheThinkingTheTerminalRendersOrToolDetails() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        // A turn that reasons on the terminal, answers, calls a tool, and
        // answers again: only the visible responses reach the chat.
        await terminal.writeThought("Secret reasoning about local.delete.\n")
        await terminal.telegramChannel.appendRootResponseDelta("Reading the manifest.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await terminal.telegramChannel.appendRootResponseDelta("Manifest looks fine.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages == ["Reading the manifest.", "Manifest looks fine."])
        for message in messages {
            #expect(!message.contains("Secret reasoning"))
            #expect(!message.contains("thinking"))
            #expect(!message.contains("local.delete"))
            #expect(!message.contains("local.readFile"))
        }
    }

    @Test
    func telegramReporterTruncatesAggregatedRootResponseToMessageLimit() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        let limit = TerminalTelegramTurnProgressReporter.maximumMessageLength

        for _ in 0..<10 {
            await reporter.appendAgentResponseDelta(String(repeating: "a", count: 1_000))
        }
        #expect(await reporter.hasPendingAgentResponse)
        await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages.count == 1)
        #expect(messages.first?.count == limit)
    }

    @Test
    func telegramFinalResponseTextExcludesAlreadyPublishedIntermediateResponses() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Inspecting the manifest.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await terminal.telegramChannel.appendRootResponseDelta("All done, everything works.")

        // A turn's response text accumulates every block it produced.
        let accumulated = "Inspecting the manifest.All done, everything works."
        let finalText = await terminal.telegramChannel.finalResponseText(
            fallback: accumulated
        )
        #expect(finalText == "All done, everything works.")

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\n\(finalText)"), fileChangeSummary: nil)

        let messages = await collector.allMessages()
        #expect(
            messages == [
                "Inspecting the manifest.",
                "*ZenCODE completed*\n\nAll done, everything works."
            ]
        )
    }

    @discardableResult
    private static func attachTestReporter(
        to terminal: TerminalChat,
        collector: TelegramTestMessageCollector
    ) -> TerminalTelegramTurnProgressReporter {
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        terminal.telegramChannel.activeProgressReporter = reporter
        return reporter
    }

    @Test
    func telegramPairingCodeAcceptsPlainCodeAndStartPayload() {
        #expect(TerminalTelegramPairingService.pairingCode(in: " abcd1234 ") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start abcd1234") == "ABCD1234")
        #expect(
            TerminalTelegramPairingService.pairingCode(in: "/start@zencode_bot abcd1234")
                == "ABCD1234"
        )
        #expect(TerminalTelegramPairingService.pairingCode(in: "\n/start AbCd1234\n") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start") == nil)
    }

    @Test
    func telegramPairingOnlyAllowsPrivateChats() {
        #expect(TerminalTelegramPairingService.allowsPairing(chatType: "private"))
        #expect(TerminalTelegramPairingService.allowsPairing(chatType: "PRIVATE"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "group"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "supergroup"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "channel"))
        // Ingress is lossless after dispatcher admission; it no longer exposes
        // a dropping buffer bound.
    }

    @Test
    func telegramUpdateOffsetIsDurableMonotonicAndPerBot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("telegram-updates.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try TerminalTelegramUpdateOffsetStore.save(updateID: 41, botID: 100, to: url)
        try TerminalTelegramUpdateOffsetStore.save(updateID: 40, botID: 100, to: url)
        try TerminalTelegramUpdateOffsetStore.save(updateID: 7, botID: 200, to: url)

        #expect(TerminalTelegramUpdateOffsetStore.load(botID: 100, from: url) == 41)
        #expect(TerminalTelegramUpdateOffsetStore.load(botID: 200, from: url) == 7)
        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif

        try Data("corrupt".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try TerminalTelegramUpdateOffsetStore.loadRequired(botID: 100, from: url)
        }
    }

    @Test
    func telegramPermissionCommandsParseRemoteApprovalReplies() {
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/allow ABC123")
                == TerminalTelegramPermissionCommand(decision: .allowOnce, requestID: "ABC123")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/always@zencode_bot f00")
                == TerminalTelegramPermissionCommand(decision: .allowAlways, requestID: "F00")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/deny ABC123")
                == TerminalTelegramPermissionCommand(decision: .deny, requestID: "ABC123")
        )
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "sì abc-123") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "annulla") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "run the tests") == nil)
    }

    @Test
    func telegramPermissionBrokerWaitsForRemoteReply() async throws {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let collector = TelegramTestMessageCollector()
        let command = "remote-telegram-permission-test-\(UUID().uuidString)"
        let request = Self.localExecAuthorizationRequest(command: "\(command) --flag")

        let authorization = Task {
            await broker.authorize(
                request,
                lease: lease,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
                return true
            }
        }

        let message = await collector.firstMessage()
        #expect(message.contains("Permission required"))
        #expect(message.contains(command))
        let requestID = try #require(Self.telegramPermissionRequestID(in: message))

        let reminder = await broker.handleMessage("queue another prompt", lease: lease)
        #expect(reminder.isHandled)
        if case let .handled(reply) = reminder {
            #expect(reply?.contains("Permission request pending") == true)
        }

        let reply = await broker.handleMessage("/allow \(requestID)", lease: lease)
        #expect(reply.isHandled)
        if case let .handled(replyText) = reply {
            #expect(replyText?.contains("allowed once") == true)
        }
        #expect(await authorization.value == .allowedOnce)
    }

    /// The destructive direct tools are gated exactly like `local.exec`, so a
    /// remote turn can no longer perform them without being asked.
    @Test
    func telegramPermissionBrokerAsksForDestructiveTools() async throws {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let collector = TelegramTestMessageCollector()
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Old.swift",
            kind: "destructive",
            command: "delete Sources/Old.swift"
        )

        #expect(!(await broker.isAlreadyAuthorized(request, lease: lease)))

        let authorization = Task {
            await broker.authorize(
                request,
                lease: lease,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
                return true
            }
        }

        let message = await collector.firstMessage()
        #expect(message.contains("Permission required"))
        #expect(message.contains("local.delete"))
        #expect(message.contains("Delete Sources/Old.swift"))
        let requestID = try #require(Self.telegramPermissionRequestID(in: message))

        _ = await broker.handleMessage("/deny \(requestID)", lease: lease)
        #expect(await authorization.value == .denied)
    }

    /// A request that never reached the chat must fail closed immediately
    /// instead of holding the turn until the timeout expires.
    @Test
    func telegramPermissionBrokerFailsClosedWhenRequestCannotBeDelivered() async {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let request = Self.localExecAuthorizationRequest(
            command: "undeliverable-\(UUID().uuidString) --flag"
        )

        let outcome = await broker.authorize(
            request,
            lease: lease,
            timeoutNanoseconds: 600_000_000_000
        ) { _ in
            false
        }

        #expect(outcome == .undeliverable)
        #expect(!outcome.isApproved)
    }

    /// A tool outside the gated set never raises a remote dialogue.
    @Test
    func telegramPermissionBrokerSkipsUngatedTools() async {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let request = Self.authorizationRequest(
            toolName: "local.readFile",
            title: "Read Sources/Main.swift",
            kind: "read",
            command: "read Sources/Main.swift"
        )

        #expect(await broker.isAlreadyAuthorized(request, lease: lease))
        let outcome = await broker.authorize(request, lease: lease) { _ in
            Issue.record("An ungated tool must not raise a permission request.")
            return true
        }
        #expect(outcome == .notRequired)
        #expect(outcome.isApproved)
    }

    private static func telegramPermissionTestLease() -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "terminal-test"),
            generation: 1
        )
    }

    private static func localExecAuthorizationRequest(command: String) -> AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.exec",
            title: "Run \(command)",
            kind: "execute",
            command: command
        )
    }

    private static func authorizationRequest(
        toolName: String,
        title: String,
        kind: String,
        command: String
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

    private static func telegramPermissionRequestID(in message: String) -> String? {
        message
            .split(separator: "\n")
            .first { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("Request ID:")
            }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    // MARK: - Live-message card replies

    /// Cards forwarded by the terminal's own relay must resolve their sender:
    /// an agent is answered on its stable id, the coordinator on its reserved
    /// destination, and the operator's own traffic is carded too — it is
    /// evidence of what the operator said — but never gets a reply target that
    /// would address the Telegram user back to themselves.
    @Test
    func telegramCardRepliesResolveAgentAndCoordinatorSenders() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let receipts = TelegramCardReceiptRecorder()
        // Injected sender: the routing map is exercised end-to-end through the
        // terminal-owned relay without touching the Telegram transport.
        terminal.telegramChannel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay {
            text, chatID in
            await receipts.record(text, chatID: chatID)
        }
        let room = terminal.sessionID
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let relay = terminal.telegramChannel.sharedChatRelay
        await relay.activate(roomID: room, chatID: 42)

        await relay.forward(
            [
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .agent,
                    senderID: "agent-7",
                    name: "Worker",
                    text: "need a decision"
                ),
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .coordinator,
                    senderID: "coordinator",
                    name: "Coordinator",
                    text: "which option?"
                ),
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .operator,
                    senderID: "operator",
                    name: "operator",
                    text: "echo of my own line"
                )
            ],
            roomID: room
        )
        await relay.waitForPendingCards()

        let cards = await receipts.cards
        #expect(cards.count == 3)
        let agentReceipt = try #require(
            cards.first { $0.text.contains("need a decision") }?.receipt
        )
        let coordinatorReceipt = try #require(
            cards.first { $0.text.contains("which option?") }?.receipt
        )

        let agentTarget = await relay.replyTarget(
            forTelegramMessageID: agentReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(agentTarget?.replyDestination == .direct(["agent-7"]))
        #expect(agentTarget?.roomID == room)

        let coordinatorTarget = await relay.replyTarget(
            forTelegramMessageID: coordinatorReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(coordinatorTarget?.replyDestination == .coordinator)
        #expect(coordinatorTarget?.roomID == room)

        // The operator card is visible, and deliberately not answerable: routing
        // a Telegram reply back to the operator would loop the human onto
        // themselves. No target is recorded for it at all.
        let operatorReceipt = try #require(
            cards.first { $0.text.contains("echo of my own line") }?.receipt
        )
        let operatorTarget = await relay.replyTarget(
            forTelegramMessageID: operatorReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(operatorTarget == nil)
    }

    /// A quoted message the relay never produced, or one of a retired room, is
    /// not consumed as a live reply: it falls back to the ordinary prompt path
    /// instead of being routed to an arbitrary participant.
    @Test
    func telegramReplyToUnknownOrRetiredCardFallsBackToThePromptPath() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let receipts = TelegramCardReceiptRecorder()
        terminal.telegramChannel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay {
            text, chatID in
            await receipts.record(text, chatID: chatID)
        }
        let relay = terminal.telegramChannel.sharedChatRelay
        // Bound to a room that is not the live session: a card of that binding
        // must never be routed into the current room.
        await relay.activate(roomID: "retired-room", chatID: 42)
        await relay.forward(
            [
                Self.sharedChatMessage(
                    roomID: "retired-room",
                    kind: .agent,
                    senderID: "agent-9",
                    name: "Worker",
                    text: "stale card"
                )
            ],
            roomID: "retired-room"
        )
        await relay.waitForPendingCards()
        let staleReceipt = try #require(await receipts.cards.first?.receipt)

        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: staleReceipt),
                lease: Self.testTelegramLease
            ) == false
        )
        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: staleReceipt + 1),
                lease: Self.testTelegramLease
            ) == false
        )
        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: nil),
                lease: Self.testTelegramLease
            ) == false
        )
    }

    /// Quoting a card must not change what an explicitly addressed line means:
    /// remote commands, slash commands and resolving mentions keep precedence,
    /// while ordinary text — including an `@` that resolves to nothing — stays
    /// replyable.
    @Test
    func telegramReplyRoutingYieldsToCommandsAndResolvingMentions() async throws {
        let terminal = try await Self.activeTelegramTerminal()

        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/help"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/start 233B0EC4"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/plan route it"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@coordinator status"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@all status"))
        // A recognised mention without text keeps its own diagnostic.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@coordinator"))
        // Not mentions, so a reply keeps its meaning.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@nobody hi") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "yes, ship it") == false)
        #expect(
            await terminal.telegramChannel.replyRoutingHasPrecedence(
                over: "answer with an email like a@b.com"
            ) == false
        )
        // A plain-word command alias is an answer to the quoted card, as in
        // the TUI; only its slash form keeps command precedence.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "diff") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "status") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/diff"))
    }

    private static func sharedChatMessage(
        roomID: String,
        kind: AgentSharedChat.ParticipantKind,
        senderID: String,
        name: String,
        text: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: AgentSharedChat.Participant(id: senderID, name: name, kind: kind),
            recipientIDs: [AgentSharedChat.operatorID(for: roomID)],
            text: text
        )
    }

    private static func incomingTelegramMessage(
        replyToMessageID: Int?
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42,
            userID: 7,
            text: "answer",
            voice: nil,
            messageID: 1,
            chatTitle: nil,
            username: nil,
            replyToMessageID: replyToMessageID
        )
    }

}

/// Hands the relay synthetic Telegram receipts so card routing can be asserted
/// without a transport.
private actor TelegramCardReceiptRecorder {
    struct Card: Equatable {
        let text: String
        let chatID: Int64
        let receipt: Int
    }

    private(set) var cards: [Card] = []
    private var nextReceipt = 9_000

    func record(_ text: String, chatID: Int64) -> Int {
        nextReceipt += 1
        cards.append(Card(text: text, chatID: chatID, receipt: nextReceipt))
        return nextReceipt
    }
}

private actor TelegramTestMessageCollector {
    private var messages: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func append(_ message: String) {
        messages.append(message)
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: message)
        }
    }

    func firstMessage() async -> String {
        if let message = messages.first {
            return message
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func allMessages() -> [String] {
        messages
    }
}

extension TerminalChat {
    /// The Telegram channel of the terminal's slot, created on first use
    /// without attaching it, so a test drives it as the terminal's loop
    /// never does.
    var telegramChannel: TelegramChannel {
        sessionHost.telegramChannelCreatingIfNeeded(in: terminalSlotID)!
    }
}
