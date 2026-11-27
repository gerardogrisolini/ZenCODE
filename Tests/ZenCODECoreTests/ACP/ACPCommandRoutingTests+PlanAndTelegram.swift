//
//  ACPCommandRoutingTests+PlanAndTelegram.swift
//  ZenCODE
//
//  The first half of the ACP command routing tests: the shared hidden routing
//  of the planning commands, the failed-workflow recovery, and the Telegram
//  command lines, with the helpers only these tests use.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension ACPCommandRoutingTests {
    @Test
    func acpPlanQuestionsFinalPlanApprovalAndGoalUseSharedHiddenRouting() async throws {
        let fixture = try await makeFixture(sessionID: "acp-command-routing")
        let bridge = fixture.bridge
        let backend = fixture.backend
        let wire = fixture.wire
        let sessionID = fixture.sessionID

        try await bridge.prompt(id: .number(1), params: [
            "sessionId": sessionID,
            "prompt": "/plan unify ACP and Telegram",
        ])

        var state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan == nil)
        #expect(state.brainstorming?.isAwaitingReply == true)
        #expect(state.brainstorming?.plannerAgentID == "acp-plan-author")
        #expect(wire.updateTexts(kind: "user_message_chunk").contains(
            "/plan unify ACP and Telegram"
        ))
        let firstTurnMessages = wire.updateTexts(kind: "agent_message_chunk")
        #expect(firstTurnMessages.first?.hasPrefix("Agent:") == true)
        #expect(Array(firstTurnMessages.dropFirst()) == [
            "# Planner questions\n1. Keep the discussion only in runtime memory?"
        ])
        #expect(!wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("COORDINATOR INTERNAL")
        })
        #expect(wire.stopReason(for: 1) == "end_turn")

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID,
            "prompt": "Yes, keep it runtime-only.",
        ])

        state = await bridge.planStateForTesting(sessionID: sessionID)
        let activePlan = try #require(state.activePlan)
        #expect(state.brainstorming == nil)
        #expect(activePlan.id == "plan-acp12345")
        #expect(activePlan.points.map(\.id) == ["plan-acp12345-1"])
        #expect(!activePlan.isApproved)
        let agentTexts = wire.updateTexts(kind: "agent_message_chunk")
        #expect(agentTexts.last?.hasPrefix("Specifiche concordate") == true)
        #expect(!agentTexts.contains { $0.contains("COORDINATOR INTERNAL") })

        let prompts = await backend.recordedPrompts()
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Planning goal requested by the user: unify ACP and Telegram"))
        #expect(!prompts[0].contains("/plan unify ACP and Telegram\n"))
        #expect(prompts[1].contains("agent.message"))
        #expect(prompts[1].contains("acp-plan-author"))
        #expect(prompts[1].contains("Yes, keep it runtime-only."))

        let history = try #require(
            await bridge.sessionRunner.snapshotSession(id: sessionID)
        ).history
        #expect(history.last?.content.hasPrefix("Specifiche concordate") == true)
        #expect(!history.contains { $0.content.contains("COORDINATOR INTERNAL") })

        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID,
            "prompt": "/plan save",
        ])
        try await bridge.prompt(id: .number(4), params: [
            "sessionId": sessionID,
            "prompt": "/plan status",
        ])
        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID,
            "prompt": "/plan list",
        ])
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("Saved plan: plan-acp12345")
        })
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("## Plan status")
        })
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("## Saved plans")
        })

        try await bridge.prompt(id: .number(6), params: [
            "sessionId": sessionID,
            "prompt": "/plan approve",
        ])
        try await bridge.prompt(id: .number(7), params: [
            "sessionId": sessionID,
            "prompt": "Unify ACP and Telegram plan execution",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.isApproved == true)
        #expect(state.activePlan?.originalGoal == "Unify ACP and Telegram plan execution")
        let planGraph = try #require(
            try await bridge.sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: activePlan.id
            )
        )
        #expect(planGraph.state == .active)
        #expect(planGraph.tasks.map(\.id) == ["plan-acp12345-1"])
        #expect((await backend.recordedPrompts()).last?.contains(
            "Implement the active approved plan now"
        ) == true)

        try await bridge.prompt(id: .number(8), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan == nil)
        #expect(state.brainstorming == nil)

        try await bridge.prompt(id: .number(9), params: [
            "sessionId": sessionID,
            "prompt": "/plan load",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.id == "plan-acp12345")
        #expect(state.activePlan?.isApproved == false)
        #expect(try #require(
            await bridge.sessionRunner.snapshotSession(id: sessionID)
        ).history.contains { $0.content.contains("[Saved plan handoff]") })

        try await bridge.prompt(id: .number(10), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        try await bridge.prompt(id: .number(11), params: [
            "sessionId": sessionID,
            "prompt": "/goal validate shared workflow routing",
        ])
        let workflowGraphs = try await bridge.sessionRunner.taskOrchestrator.graphSnapshots(
            sessionID: sessionID
        ).filter { graph in
            if case .workflow = graph.source { return true }
            return false
        }
        #expect(workflowGraphs.count == 1)
        #expect((await backend.recordedPrompts()).last?.contains(
            "Goal: validate shared workflow routing"
        ) == true)
        #expect(wire.updateTexts(kind: "user_message_chunk").suffix(4) == [
            "/plan clear",
            "/plan load",
            "/plan clear",
            "/goal validate shared workflow routing",
        ])

        try await bridge.prompt(id: .number(12), params: [
            "sessionId": sessionID,
            "prompt": "/review focus on ACP routing",
        ])
        let reviewPrompt = try #require(await backend.recordedPrompts().last)
        #expect(reviewPrompt.contains("read-only review requested through ACP"))
        #expect(reviewPrompt.contains("Review focus requested by the user: focus on ACP routing"))
        #expect(reviewPrompt.contains("profile \"\(AgentProfileRole.reviewer.rawValue)\""))
        #expect(reviewPrompt.contains("graph=workflow_"))
        #expect(wire.updateTexts(kind: "user_message_chunk").last
            == "/review focus on ACP routing")
        #expect(wire.stopReason(for: 11) == "end_turn")
    }

    @Test
    func acpPlanSavePromotesStructuredHistoryResponseWithEveryTask() async throws {
        let planText = """
        Specifiche concordate
        - Keep compatibility.

        Implementation plan
        1. Add the shared model.
           Dependencies: none
        2. Wire the ACP command.
           Dependencies: 1
        3. Validate every frontend.
           Dependencies: 1, 2
        """
        let fixture = try await makeFixture(
            sessionID: "acp-command-structured-save",
            history: [
                AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
                AgentRuntimeMessage(role: .assistant, content: planText),
            ]
        )
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID

        try await bridge.prompt(id: .number(1), params: [
            "sessionId": sessionID,
            "prompt": "/plan save",
        ])

        let promoted = try #require(
            await bridge.planStateForTesting(sessionID: sessionID).activePlan
        )
        let taskIDs = (1...3).map { "\(promoted.id)-\($0)" }
        let titles = [
            "Add the shared model.",
            "Wire the ACP command.",
            "Validate every frontend.",
        ]
        let dependencies = [[], [taskIDs[0]], [taskIDs[0], taskIDs[1]]]
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("Saved plan: \(promoted.id)")
        })
        #expect(promoted.originalGoal == "Ship the shared routing")
        #expect(promoted.points.map(\.id) == taskIDs)
        #expect(promoted.points.map(\.dependsOn) == dependencies)

        let stored = try #require(await bridge.sessionRunner.savedTaskPlans(
            workingDirectory: bridge.configuration.workingDirectory
        ).first)
        #expect(stored.graph.id == promoted.id)
        #expect(stored.graph.tasks.map(\.id) == taskIDs)
        #expect(stored.graph.tasks.map(\.title) == titles)
        #expect(stored.graph.tasks.map(\.dependsOn) == dependencies)

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID,
            "prompt": "/plan load",
        ])
        let loaded = try #require(
            await bridge.planStateForTesting(sessionID: sessionID).activePlan
        )
        #expect(loaded.id == promoted.id)
        #expect(loaded.points.map(\.id) == taskIDs)
        #expect(loaded.points.map(\.dependsOn) == dependencies)

        try await bridge.prompt(id: .number(4), params: [
            "sessionId": sessionID,
            "prompt": "/plan approve",
        ])
        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID,
            "prompt": "Ship the shared routing safely",
        ])
        let graph = try #require(
            try await bridge.sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: promoted.id
            )
        )
        #expect(graph.state == .active)
        #expect(graph.tasks.map(\.id) == taskIDs)
        #expect(graph.tasks.map(\.dependsOn) == dependencies)
        #expect(!graph.tasks.contains { $0.id.hasSuffix("-implementation") })
    }

    @Test
    func acpFailedWorkflowTurnKeepsANonEmptyGraphAndArmsRecovery() async throws {
        let fixture = try await makeFixture(sessionID: "acp-workflow-recovery")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        let graphID = "workflow_recovery_case"
        _ = try await bridge.sessionRunner.taskOrchestrator.createGraph(
            sessionID: sessionID,
            id: graphID,
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "t1",
                    title: "Delegated work",
                    execution: TaskExecutionSpec(executor: .subAgent)
                ),
            ]
        )

        // The session controller handles the failed turn while that turn is
        // still the current one.
        let controller = try #require(await bridge.chatSessionControllerForTesting(sessionID: sessionID))
        let token = await controller.beginTurnToken()
        await controller.handleFailedWorkflowTurn(
            graphID: graphID,
            reason: "the turn was cancelled",
            token: token,
            turnSessionID: sessionID
        )

        let graph = try #require(try await bridge.sessionRunner.taskGraphSnapshot(
            sessionID: sessionID
        ))
        #expect(graph.id == graphID)
        #expect(graph.tasks.count == 1)
        let recovery = try #require(await bridge.workflowStateForTesting(sessionID: sessionID))
        #expect(recovery.graphID == graphID)
        #expect(recovery.isAwaitingReply)
        #expect(recovery.pendingSignal?.transcriptMessage.contains("the turn was cancelled") == true)
    }

    @Test(arguments: [false, true], [TaskGraphWorkflowState.running, .awaitingUser, .blocked])
    func realSessionCancelRearmsFirstTurnAndConsumedReply(afterReply: Bool, state: TaskGraphWorkflowState) async throws {
        let fixture = try await makeFixture(sessionID: "acp-real-cancel-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        if afterReply {
            try await bridge.prompt(id: .number(1), params: [
                "sessionId": sessionID, "prompt": "/goal Keep cancel objective",
            ])
        }
        await fixture.backend.setWorkflowPauseState(state)
        await fixture.backend.interruptWorkflow(fail: false, afterPause: state != .running)
        let generation = Task {
            try await bridge.prompt(id: .number(2), params: [
                "sessionId": sessionID,
                "prompt": afterReply ? "First answer" : "/goal Keep cancel objective",
            ])
        }
        defer { generation.cancel() }
        for _ in 0..<500 {
            if await fixture.backend.isWorkflowSuspended() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.backend.isWorkflowSuspended())
        let before = try #require(try await bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID))
        try await bridge.cancel(id: .number(3), params: ["sessionId": sessionID])
        _ = try await generation.value
        #expect(await bridge.workflowStateForTesting(sessionID: sessionID)?.isAwaitingReply == true)
        await fixture.backend.setWorkflowPauseState(.awaitingUser)
        try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "Retry after real cancel"])
        let prompts = await fixture.backend.recordedPrompts()
        let resumed = try #require(prompts.first { $0.contains("Retry after real cancel") })
        #expect(resumed.contains("Continue the goal workflow"))
        #expect(resumed.contains("Goal: Keep cancel objective"))
        #expect(resumed.contains("Active workflow task graph: \(before.id)"))
        if state != .running {
            #expect(resumed.contains("Persisted pause before interruption"))
        }
        if afterReply {
            #expect(resumed.contains("First answer"))
        }
        let after = try #require(try await bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID))
        #expect(after.id == before.id)
        #expect(after.workflow?.originalGoal == before.workflow?.originalGoal)
        #expect(after.tasks == before.tasks)
    }

    /// Replaces the characterization of task 1
    /// (`telegramOnIsRoutedToTheModelAsAnOrdinaryPrompt`), on purpose: a line
    /// whose command is `/telegram` is now answered at once and never reaches
    /// the model, whether Telegram is configured or not. Without Telegram
    /// settings every such line gets the terminal's unknown-command text
    /// (without its trailing newline, like every immediate ACP reply). With
    /// them, the lines that need no Bot API are answered as in the terminal.
    @Test(arguments: [false, true])
    func telegramLinesAreAnsweredAtOnceAndNeverReachTheModel(telegramConfigured: Bool) async throws {
        try await withTelegramSupportDirectory(telegramConfigured: telegramConfigured) {
            let fixture = try await makeFixture(sessionID: "acp-telegram-route-\(UUID().uuidString)")
            #expect(CoordinatorCommandParser.parse("/telegram on") == nil)

            let expectations: [(line: String, text: String)] = telegramConfigured
                ? [
                    ("/telegram", "Telegram: Configured"),
                    ("/telegram off", "Telegram remote control stopped."),
                    ("/telegram later", "Usage: /telegram [on|off]"),
                ]
                : ["/telegram", "/telegram on", "/telegram off", "/telegram later"].map {
                    ($0, "ZenCODE: unknown command '/telegram'.")
                }
            for expectation in expectations {
                let route = try await fixture.bridge.commandRouteForTesting(
                    sessionID: fixture.sessionID, prompt: expectation.line
                )
                guard case let .immediate(text) = route else {
                    Issue.record("\(expectation.line) must be answered at once, got \(route)")
                    continue
                }
                #expect(text == expectation.text)
            }

            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": telegramConfigured ? "/telegram" : "/telegram on",
            ])
            #expect(await fixture.backend.recordedPrompts().isEmpty)
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == [expectations[0].text])
            #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        }
    }

    /// `/telegram on` hands the session's slot to its Telegram channel
    /// through the scripted Bot API, which reads the linked chat; `/telegram`
    /// reports the link as the channel does; `/telegram off` takes the slot
    /// back and stops the link. None of them reaches the model, and while
    /// Telegram drives the slot the editor's prompts are refused.
    @Test(.timeLimit(.minutes(1)))
    func telegramOnHandsTheSlotOverStatusReportsAndOffTakesItBack() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let transport = ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            let sessionID = "acp-telegram-on-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [sessionID], transport: transport
            )
            let bridge = fixture.bridge

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram")
                == "Telegram: Configured")
            #expect(await fixture.telegramChannel(sessionID: sessionID) == nil)

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram on")
                == "Telegram remote control is active.\nLinked chat: Test")
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            #expect(await channel.isActive)
            #expect(await channel.readsIngress)
            #expect(await channel.drivesSlot)
            #expect(await channel.primaryChannelDescription == "editor")
            #expect(await ACPTelegramTestSupport.waitUntil { await transport.pollCount > 0 })

            // The editor is dormant: a prompt is refused without reaching the
            // model, the status is still answered.
            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "Hello from the editor")
                == "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.")
            #expect(await fixture.backend.prompts.isEmpty)
            let status = try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram")
            #expect(status == (await channel.statusText()))
            #expect(status?.hasPrefix("Telegram: ") == true)
            #expect(status?.contains("Linked chat: Test") == true)

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram off")
                == "Telegram remote control stopped.")
            #expect(await !channel.isActive)
            #expect(await !channel.readsIngress)
            #expect(await !channel.drivesSlot)
            #expect(await fixture.telegramChannel(sessionID: sessionID) === channel)

            // A failed start answers the terminal's failure text.
            await transport.setGetMeFails(true)
            let failure = try #require(
                try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram on")
            )
            let lastError = try #require(await channel.controlState.lastError)
            #expect(failure == "ZenCODE: \(lastError)")
            #expect(await !channel.isActive)
            #expect(await !channel.drivesSlot)
            #expect(await fixture.backend.prompts.isEmpty)
            await bridge.shutdown()
        }
    }

    /// A line the editor sends while Telegram drives the slot is refused and
    /// changes nothing, its leading `@Agent` mention included: the session is
    /// not routed to that agent, with its other tools and its own model.
    @Test(.timeLimit(.minutes(1)))
    func aRefusedEditorLineDoesNotRouteTheSessionThroughItsAgentMention() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let transport = ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            let sessionID = "acp-telegram-mention-\(UUID().uuidString)"
            let profiles = AgentProfileStore.defaultProfiles()
            let developer = try #require(profiles.first { $0.id == AgentProfileRole.developer.rawValue })
            let planner = try #require(profiles.first { $0.id == AgentProfileRole.planner.rawValue })
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root,
                sessionIDs: [sessionID],
                selectedAgent: developer,
                transport: transport
            )
            let bridge = fixture.bridge

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram on")
                == "Telegram remote control is active.\nLinked chat: Test")
            #expect(await ACPTelegramTestSupport.waitUntil { await transport.pollCount > 0 })

            let agentBefore = await bridge.selectedAgentIDForTesting(sessionID: sessionID)
            await fixture.prompt("@\(planner.name) inspect this", id: 2, sessionID: sessionID)

            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(
                fixture.wire.updateTexts(kind: "agent_message_chunk")
                    == ["ZenCODE: this session is driven from Telegram. Use /telegram off to take it back."]
            )
            #expect(agentBefore == developer.id)
            #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == agentBefore)
            #expect(await fixture.backend.prompts.isEmpty)
            await bridge.shutdown()
        }
    }

    /// Runs `body` in a fresh UUID support directory of its own, holding a
    /// complete routing-v2 Telegram `settings.json` when `telegramConfigured`.
    /// Every test case gets its own directory, so a configured case can never
    /// leak its settings into an unconfigured one.
    private func withTelegramSupportDirectory(
        telegramConfigured: Bool,
        _ body: () async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-telegram-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            if telegramConfigured {
                try AgentSettingsManifestStore.save(AgentSettingsManifest(
                    models: [],
                    telegram: AgentTelegramSettingsManifest(
                        enabled: true,
                        botToken: "123456:ABCDEF",
                        linkedChatID: 42,
                        ownerUserID: 7,
                        routingVersion: 2,
                        routes: [.init(roomID: "default")]
                    )
                ))
            }
            #expect((AgentSettingsManifestStore.load()?.telegram?.isEnabled == true) == telegramConfigured)
            try await body()
        }
    }
}

extension ZenCODEACPBridge {
    /// The text of the immediate answer to `prompt`, routed as
    /// `session/prompt` routes it; `nil` when the line would start a turn.
    fileprivate func immediateTextForTesting(sessionID: String, prompt: String) async throws -> String? {
        guard case let .immediate(text) = try await commandRouteForTesting(sessionID: sessionID, prompt: prompt) else {
            return nil
        }
        return text
    }

    /// Routes `prompt` the way `session/prompt` does once it holds the
    /// reservation, and returns the route instead of running the turn.
    fileprivate func commandRouteForTesting(
        sessionID: String,
        prompt: String,
        agentMention: AgentProfile? = nil
    ) async throws -> ACPCommandTurnRoute {
        guard let session = sessions[sessionID] else { throw CancellationError() }
        let reservation = try await host.reservePrompt(in: session.slotID)
        let route: ACPCommandTurnRoute
        do {
            route = try await routeACPCommandTurn(
                operatorLine: prompt,
                normalPrompt: prompt,
                agentMention: agentMention,
                turn: ACPPromptTurn(requestID: nil, sessionID: sessionID, epoch: reservation.epoch, promptID: reservation.promptID)
            )
        } catch {
            await host.releasePrompt(reservation)
            throw error
        }
        await host.releasePrompt(reservation)
        return route
    }
}
