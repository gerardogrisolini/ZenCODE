//
//  PlanCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct PlanCommandTests {
    @Test
    func planCommandIsVisibleWithStandardCommands() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(commands.contains("/plan"))
    }

    @Test
    func subAgentsCommandIsRemovedFromVisibleCommands() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(!commands.contains("/subagents"))
        #expect(!TerminalChat.isKnownSlashCommand("/subagents"))
    }

    @Test
    func planCommandRequiresExplicitGoalArgument() throws {
        let descriptor = try #require(
            TerminalChat.visibleCommandDescriptors(
                builderAgentEnabled: false,
                telegramEnabled: false,
                voiceEnabled: false
            ).first(where: { $0.command == "/plan" })
        )

        #expect(descriptor.requiresArgument)
        #expect(descriptor.help.contains("/plan <goal>"))
        #expect(descriptor.help.contains("/plan status"))
        #expect(descriptor.help.contains("/plan approve"))
        #expect(descriptor.help.contains("start implementation immediately"))
        #expect(descriptor.help.contains("/plan clear"))
        #expect(!descriptor.help.contains("/plan [goal]"))
    }

    @Test
    func planStatusRendersStructuredItemsWithoutDelegation() async throws {
        let terminal = try makeTerminal()
        terminal.selectedToolKeys.remove("sub-agents")
        let plan = TerminalSessionPlan(
            originalGoal: "Track implementation",
            consolidatedText: "Implement and validate.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-1",
                    text: "Implement | command",
                    status: .completed
                ),
                TerminalSessionPlanPoint(
                    id: "plan-2",
                    text: "Run tests",
                    status: .inProgress
                ),
            ]
        )
        terminal.activePlan = plan

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan STATUS")))
        #expect(terminal.activePlan == plan)

        let table = TerminalChat.planStatusTable(for: plan)
        #expect(table.contains("| # | Plan item | Status |"))
        #expect(table.contains("| 1 | Implement \\| command | `completed` |"))
        #expect(table.contains("| 2 | Run tests | `in_progress` |"))
        #expect(table.contains("**Overall status:** `in_progress`"))

        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 100,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume(table) + formatter.finish()
        #expect(!rendered.contains("|---:"))
        #expect(rendered.contains("Plan item"))
        #expect(rendered.contains("in_progress"))
    }

    @Test
    func planStatusDerivesFailureFromAnActiveGraph() {
        let now = Date(timeIntervalSince1970: 10)
        let plan = TerminalSessionPlan(
            id: "plan-failure",
            originalGoal: "Track failure",
            consolidatedText: "Implement.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(id: "plan-failure-1", text: "Implement")
            ]
        )
        let graph = TaskGraphSnapshot(
            id: plan.id,
            source: .plan(planID: plan.id),
            state: .active,
            tasks: [
                TaskRecord(
                    id: "plan-failure-1",
                    title: "Implement",
                    order: 1,
                    status: .failed,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
        let projected = TerminalChat.plan(plan, applying: graph)
        let table = TerminalChat.planStatusTable(for: projected, graph: graph)

        #expect(table.contains("**Overall status:** `failed`"))
        #expect(table.contains("| 1 | Implement | `failed` |"))
    }

    @Test
    func planStatusKeepsStatusesReadableWhenItemsAreLong() {
        let longItem = Array(
            repeating: "Implement the detailed compatibility and validation requirement",
            count: 16
        ).joined(separator: " ")
        let plan = TerminalSessionPlan(
            originalGoal: "Track a long implementation",
            consolidatedText: "Implement and validate.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-1",
                    text: longItem,
                    status: .completed
                ),
                TerminalSessionPlanPoint(
                    id: "plan-2",
                    text: longItem,
                    status: .inProgress
                ),
            ]
        )
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 90,
            supportsHyperlinks: false
        )

        let rendered = TerminalANSIText.stripANSI(
            formatter.consume(TerminalChat.planStatusTable(for: plan)) + formatter.finish()
        )
        let tableRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") }

        #expect(tableRows.contains { $0.contains("completed") })
        #expect(tableRows.contains { $0.contains("in_progress") })
        #expect(tableRows.contains { $0.contains("…") })
        #expect(tableRows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 90 })
    }

    @Test
    func planStatusWithoutActivePlanDoesNotRequireSubAgents() async throws {
        let terminal = try makeTerminal()
        terminal.selectedToolKeys.remove("sub-agents")

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan status")))
        #expect(terminal.activePlan == nil)
    }

    @Test
    func barePlanCommandStopsBeforeDelegatingToPlanner() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.handlePlanCommand("/plan")

        switch action {
        case .continueChat:
            break
        case .runHiddenPrompt(_, _):
            Issue.record("Bare /plan should not create a hidden delegation prompt")
        default:
            Issue.record("Bare /plan should only continue the chat after reporting the missing goal")
        }
    }

    @Test
    func planCommandWithGoalRunsHiddenDelegationPrompt() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.handlePlanCommand("/plan fix the planner command")

        switch action {
        case let .runHiddenPrompt(prompt, purpose):
            #expect(prompt.contains("Planning goal requested by the user: fix the planner command"))
            #expect(prompt.contains("agent.create"))
            #expect(purpose == .plan(originalGoal: "fix the planner command"))
        case .runPrompt(_):
            Issue.record("/plan <goal> should keep the generated delegation prompt hidden")
        default:
            Issue.record("/plan <goal> should start the planning delegation prompt")
        }
    }

    @Test
    func successfulPlanOutputIsRecordedAndReplacementRequiresApprovalAgain() async throws {
        let terminal = try makeTerminal()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        #expect(terminal.recordPlanIfNeeded(
            responseText: "  First consolidated plan  ",
            purpose: .plan(originalGoal: " first goal "),
            createdAt: firstDate,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "First item")
            ]
        ))
        #expect(terminal.activePlan == TerminalSessionPlan(
            id: terminal.activePlan?.id,
            originalGoal: "first goal",
            consolidatedText: "First consolidated plan",
            createdAt: firstDate,
            isApproved: false,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "First item")
            ]
        ))

        let approvalAction = await terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == true)
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Implement the active approved plan now"))
        #expect(prompt.contains("First consolidated plan"))

        #expect(terminal.recordPlanIfNeeded(
            responseText: "Second consolidated plan",
            purpose: .plan(originalGoal: "second goal"),
            createdAt: secondDate
        ))
        #expect(terminal.activePlan?.originalGoal == "second goal")
        #expect(terminal.activePlan?.consolidatedText == "Second consolidated plan")
        #expect(terminal.activePlan?.createdAt == secondDate)
        #expect(terminal.activePlan?.isApproved == false)
    }

    @Test
    func successfulTodoWritesSynchronizeApprovedPlanAndDetectCompletion() throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "Implement status tracking",
            consolidatedText: "Two steps",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "Implement command"),
                TerminalSessionPlanPoint(id: "plan-2", text: "Run tests"),
            ]
        )
        let result = DirectAgentToolResult(
            output: "updated",
            summary: "updated"
        )

        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "in_progress")
            ]),
            result: result
        ))
        #expect(terminal.activePlan?.points.map(\.status) == [.inProgress, .pending])

        #expect(terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "completed"),
                ("plan-2", "Run tests", "completed"),
            ]),
            result: result
        ))
        #expect(terminal.activePlan?.isCompleted == true)
        #expect(TerminalChat.planStatusTable(for: try #require(terminal.activePlan))
            .contains("**Overall status:** `completed`"))
    }

    @Test
    func failedOrUnrelatedTodoWritesDoNotChangePlanStatus() throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            originalGoal: "Keep status stable",
            consolidatedText: "One step",
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "plan-1", text: "Step")]
        )
        terminal.activePlan = plan

        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [("plan-1", "Step", "completed")]),
            result: DirectAgentToolResult(
                output: "Tool error: failed",
                summary: "failed",
                status: .failed
            )
        ))
        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [("other", "Unrelated", "completed")]),
            result: DirectAgentToolResult(output: "updated", summary: "updated")
        ))
        #expect(terminal.activePlan == plan)
    }

    @Test
    func approvedPlanAddsProgressInstructionsToSystemPrompt() throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "Track plan",
            consolidatedText: "One step",
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "plan-1", text: "Implement")]
        )

        let prompt = try #require(terminal.systemPromptWithActivePlanProgress("Base prompt"))

        #expect(prompt.contains("Active approved plan progress:"))
        #expect(prompt.contains("plan-1 [pending]: Implement"))
        #expect(prompt.contains("task.list"))
        #expect(prompt.contains("task.update"))
        #expect(!prompt.contains("todo.write"))
    }

    @Test
    func emptyOrNonPlanningOutputDoesNotReplaceActivePlan() throws {
        let terminal = try makeTerminal()
        let existing = TerminalSessionPlan(
            originalGoal: "existing",
            consolidatedText: "Keep this plan",
            createdAt: Date(timeIntervalSince1970: 10),
            isApproved: true
        )
        terminal.activePlan = existing

        #expect(!terminal.recordPlanIfNeeded(
            responseText: " \n ",
            purpose: .plan(originalGoal: "failed goal")
        ))
        #expect(!terminal.recordPlanIfNeeded(
            responseText: "ordinary response",
            purpose: .normal
        ))
        #expect(terminal.activePlan == existing)
    }

    @Test
    func approveRequiresACompletedPlanAndClearRemovesIt() async throws {
        let terminal = try makeTerminal()

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan approve")))
        #expect(terminal.activePlan == nil)

        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan"
        )
        let approvalAction = await terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == true)
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Goal: goal"))
        #expect(prompt.contains("Approved plan:\nplan"))

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
        #expect(terminal.activePlan == nil)
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
    }

    @Test
    func undoKeepsPlanWhileNewSessionClearsIt() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: true
        )
        terminal.activePlan = plan

        await terminal.handleUndoFileChangesCommand()
        #expect(terminal.activePlan == plan)

        await terminal.startNewSession()
        #expect(terminal.activePlan == nil)
    }

    @Test
    func plannerToolAllowlistExcludesMutatingTools() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: [
                "local.readFile",
                "local.inspectFile",
                "local.writeFile",
                "local.exec",
                "search.locate",
                "git.diff",
                "git.add",
                "memory.read",
                "memory.write",
                "task.list",
                "task.update",
                "web.search"
            ]
        )

        let tools = TerminalChat.plannerSubAgentToolNames(for: planner)

        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("local.inspectFile"))
        #expect(tools.contains("search.locate"))
        #expect(tools.contains("git.diff"))
        #expect(tools.contains("memory.read"))
        #expect(tools.contains("task.list"))
        #expect(tools.contains("web.search"))
        #expect(!tools.contains("local.writeFile"))
        #expect(!tools.contains("local.exec"))
        #expect(!tools.contains("git.add"))
        #expect(!tools.contains("memory.write"))
        #expect(!tools.contains("task.update"))
    }

    @Test
    func defaultPlannerToolGroupsResolveToReadOnlySubAgentTools() throws {
        let planner = try #require(
            AgentProfileStore.defaultProfiles().first(where: TerminalChat.isPlannerProfile)
        )

        let tools = TerminalChat.plannerSubAgentToolNames(for: planner)

        #expect(planner.tools == AgentProfileStore.plannerToolNames)
        #expect(!planner.tools.contains("shell"))
        #expect(!planner.tools.contains("local.readFile"))
        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("local.inspectFile"))
        #expect(tools.contains("search.locate"))
        #expect(tools.contains("git.diff"))
        #expect(tools.contains("memory.read"))
        #expect(tools.contains("web.search"))
        #expect(!tools.contains("local.exec"))
        #expect(!tools.contains("local.writeFile"))
        #expect(!tools.contains("git.add"))
        #expect(!tools.contains("memory.write"))
    }

    @Test
    func planDelegationPromptMakesOnePlannerTheSolePlanAuthor() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: []
        )

        let prompt = TerminalChat.planDelegationPrompt(
            goal: "add a Planner command",
            planner: planner
        )

        #expect(prompt.contains("Planning goal requested by the user: add a Planner command"))
        #expect(prompt.contains("agent.create"))
        #expect(prompt.contains("Create exactly one sub-agent"))
        #expect(prompt.contains("name \"plan-author\""))
        #expect(prompt.contains("role \"Planner\""))
        #expect(prompt.contains("profile \"\(planner.id)\""))
        #expect(prompt.contains("isolationMode \"report\""))
        #expect(prompt.contains("toolNames:"))
        #expect(prompt.contains("agent.wait"))
        #expect(prompt.contains("same Planner to correct it with agent.message"))
        #expect(prompt.contains("call todo.write once with mode \"upsert\""))
        #expect(prompt.contains("stable IDs \"plan-<token>-1\""))
        #expect(prompt.contains("/plan <goal> -> /plan approve"))
        #expect(prompt.contains("automatically starts implementation"))
        #expect(prompt.contains("must not tell the user to send another implementation prompt"))
        #expect(prompt.contains("Planner agent is the sole author of the final plan"))
        #expect(prompt.contains("exactly the Planner's latest output, verbatim"))
        #expect(prompt.contains("do not author, draft, consolidate, rewrite, or improve"))
        #expect(prompt.contains("Do not edit any files yourself in this planning turn"))
        #expect(!prompt.contains("infer the activity to plan"))
        #expect(!prompt.contains("spawn multiple Planners"))
        #expect(!prompt.contains("Read and consolidate their plans"))
        #expect(!prompt.contains("local.writeFile"))
        #expect(!prompt.contains("local.exec"))
        #expect(!prompt.contains("git.add"))
        #expect(!prompt.contains("memory.write"))
    }

    @Test
    func plannerAuthoredResponseIgnoresTheCurrentAgentsDraft() throws {
        let parentResponse = DirectAgentResponse(
            text: "Default rewrote the plan",
            stopReason: "end_turn",
            modelID: "default-model"
        )
        let response = try #require(TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: parentResponse,
            snapshots: [
                subAgentSnapshot(
                    name: "supporting-agent",
                    role: "Planner",
                    modelID: "other-model",
                    latestOutput: "Supporting notes",
                    updatedAt: Date(timeIntervalSince1970: 200)
                ),
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    modelID: "planner-model",
                    latestOutput: "Planner-authored final plan",
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        ))

        #expect(response.text == "Planner-authored final plan")
        #expect(response.stopReason == parentResponse.stopReason)
        #expect(response.modelID == "planner-model")
        #expect(response.text != parentResponse.text)
    }

    @Test
    func plannerAuthoredResponseRejectsAnIncompletePlanner() {
        let parentResponse = DirectAgentResponse(
            text: "Default fallback plan",
            stopReason: "end_turn",
            modelID: "default-model"
        )
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: parentResponse,
            snapshots: [
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    status: .running,
                    pending: true,
                    latestOutput: "Draft"
                ),
                subAgentSnapshot(
                    name: "default-agent",
                    role: "Default",
                    latestOutput: "Default fallback plan"
                ),
            ]
        )

        #expect(response == nil)
    }

    @Test
    func plannerAuthoredResponseRejectsAPlannerRoleUsingTheDefaultProfile() {
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    profileName: "Default",
                    latestOutput: "Impersonated plan"
                )
            ]
        )

        #expect(response == nil)
    }

    @Test
    func plannerAuthoredResponseRejectsAPreexistingPlanAuthor() {
        let staleAuthor = subAgentSnapshot(
            name: TerminalChat.planAuthorAgentName,
            role: "Planner",
            latestOutput: "Plan for the previous goal"
        )
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [staleAuthor],
            excludingAgentIDs: [staleAuthor.id]
        )

        #expect(response == nil)
    }

    @Test
    func plannerOutputReplacesCoordinatorTextInOperationalHistory() {
        let toolCall = AgentRuntimeToolCall(
            id: "create-planner",
            name: "agent.create",
            argumentsJSON: "{}"
        )
        let history = [
            AgentRuntimeMessage(role: .user, content: "Earlier question"),
            AgentRuntimeMessage(role: .assistant, content: "Earlier answer"),
            AgentRuntimeMessage(role: .user, content: "Hidden planning prompt"),
            AgentRuntimeMessage(role: .assistant, content: "I will coordinate the plan."),
            AgentRuntimeMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            AgentRuntimeMessage(
                role: .tool,
                content: "Planner completed",
                toolCallID: "create-planner",
                toolName: "agent.create"
            ),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Default-authored replacement plan",
                providerResponseID: "default-response"
            ),
        ]

        let corrected = TerminalChat.historyByReplacingPlanCoordinatorOutput(
            history,
            with: "Planner-authored final plan"
        )

        #expect(corrected.prefix(3) == history.prefix(3))
        #expect(corrected.contains { $0.toolCalls == [toolCall] })
        #expect(corrected.contains { $0.role == .tool })
        #expect(!corrected.contains { $0.content.contains("coordinate") })
        #expect(!corrected.contains { $0.content.contains("Default-authored") })
        #expect(corrected.last?.role == .assistant)
        #expect(corrected.last?.content == "Planner-authored final plan")
        #expect(corrected.last?.providerResponseID == nil)
    }

    @Test
    func validPlanCreatesDraftGraphAndApprovalActivatesProjectedStatus() async throws {
        let terminal = try makeTerminal()
        let points = [
            TerminalSessionPlanPoint(
                id: "plan-graph-1",
                text: "Implement model",
                dependsOn: [],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-graph-2",
                text: "Run validation",
                dependsOn: ["plan-graph-1"],
                hasExplicitDependencies: true
            ),
        ]

        #expect(try await terminal.recordPlanAndTaskGraphIfNeeded(
            responseText: "1. Implement model\n2. Run validation",
            purpose: .plan(originalGoal: "Ship graph"),
            points: points
        ))
        let draft = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        ))
        #expect(draft.state == .draft)
        #expect(draft.source == .plan(planID: "plan-graph"))
        #expect(draft.tasks.map(\.dependsOn) == [[], ["plan-graph-1"]])
        #expect(terminal.activePlan?.id == "plan-graph")

        let approval = await terminal.handlePlanCommand("/plan approve")
        guard case .runHiddenPrompt = approval else {
            Issue.record("Approval should activate the draft and start implementation")
            return
        }
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        )?.state == .active)

        let receipt = try #require(try await terminal.sessionRunner.taskOrchestrator.claimTasks(
            sessionID: terminal.sessionID,
            claims: [TaskClaim(taskID: "plan-graph-1", agentID: "worker")]
        ).first)
        _ = try await terminal.sessionRunner.taskOrchestrator.completeAttempt(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-1",
            attemptID: receipt.attemptID,
            output: "done",
            requiresValidation: false
        )
        _ = await terminal.handlePlanCommand("/plan status")
        #expect(terminal.activePlan?.points.map(\.status) == [.completed, .pending])
        #expect(try await terminal.sessionRunner.taskOrchestrator.task(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-2"
        ).isRunnable)
    }

    @Test
    func invalidReplacementLeavesPreviousPlanAndGraphUntouched() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.recordPlanAndTaskGraphIfNeeded(
            responseText: "1. Existing",
            purpose: .plan(originalGoal: "Existing"),
            points: [TerminalSessionPlanPoint(id: "plan-old-1", text: "Existing")]
        )
        let existingPlan = try #require(terminal.activePlan)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await terminal.recordPlanAndTaskGraphIfNeeded(
                responseText: "1. Invalid",
                purpose: .plan(originalGoal: "Invalid"),
                points: [
                    TerminalSessionPlanPoint(
                        id: "plan-new-1",
                        text: "Invalid",
                        dependsOn: ["missing"],
                        hasExplicitDependencies: true
                    )
                ]
            )
        }

        #expect(terminal.activePlan == existingPlan)
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        )?.id == "plan-old")
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }

    private func todoWriteCall(
        items: [(id: String, content: String, status: String)]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "todo-write",
            name: "todo.write",
            argumentsObject: [
                "mode": "upsert",
                "todos": items.map { item in
                    [
                        "id": item.id,
                        "content": item.content,
                        "status": item.status,
                    ]
                },
            ],
            argumentsJSON: "{}"
        )
    }

    private func subAgentSnapshot(
        name: String,
        role: String,
        status: DirectSubAgentRuntime.Status = .idle,
        pending: Bool = false,
        modelID: String? = nil,
        profileName: String? = AgentProfileStore.plannerAgentName,
        latestOutput: String?,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-\(name)",
            name: name,
            role: role,
            profileName: profileName,
            isolationMode: .report,
            status: status,
            pending: pending,
            modelID: modelID,
            latestOutput: latestOutput,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt
        )
    }
}
