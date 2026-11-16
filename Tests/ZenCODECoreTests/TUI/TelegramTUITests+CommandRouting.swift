//
//  TelegramTUITests+CommandRouting.swift
//  ZenCODE
//
//  Tests for Telegram remote command handling and the routing of plan, goal,
//  review and clarification replies, with the route and terminal fixtures
//  they share.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TelegramTUITests {
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
    func telegramReturnsImmediateCoordinatorCommandOutputAndBotAddressedHelp() async throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false,
            telegramTransportFactory: nil
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
            stdinIsTerminal: false,
            telegramTransportFactory: nil
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
            stdinIsTerminal: false,
            telegramTransportFactory: nil
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
        #expect(reviewPrompt.contains("Reviewers must not edit files."))
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
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false, telegramTransportFactory: nil)
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
        await terminal.chatSession.recordWorkflowTurnOutcome(
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
        await terminal.chatSession.recordWorkflowTurnOutcome(
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
        ), stdinIsTerminal: false, telegramTransportFactory: nil)
        let lease = await Self.installTestRoute(on: terminal, roomID: terminal.sessionID)
        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        terminal.chatSession.activePlan = TerminalSessionPlan(
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
        #expect(terminal.chatSession.activePlan?.originalGoal == "Keep the approved plan's objective explicit")
        #expect(terminal.chatSession.activePlan?.isApproved == true)
    }

    static func activeTelegramTerminal(
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
}
