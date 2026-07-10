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
        #expect(descriptor.help.contains("/plan clear"))
        #expect(!descriptor.help.contains("/plan [goal]"))
    }

    @Test
    func planStatusRendersStructuredItemsWithoutDelegation() throws {
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

        #expect(isContinueChat(terminal.handlePlanCommand("/plan STATUS")))
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
    func planStatusWithoutActivePlanDoesNotRequireSubAgents() throws {
        let terminal = try makeTerminal()
        terminal.selectedToolKeys.remove("sub-agents")

        #expect(isContinueChat(terminal.handlePlanCommand("/plan status")))
        #expect(terminal.activePlan == nil)
    }

    @Test
    func barePlanCommandStopsBeforeDelegatingToPlanner() throws {
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

        let action = terminal.handlePlanCommand("/plan")

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
    func planCommandWithGoalRunsHiddenDelegationPrompt() throws {
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

        let action = terminal.handlePlanCommand("/plan fix the planner command")

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
    func successfulPlanOutputIsRecordedAndReplacementRequiresApprovalAgain() throws {
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
            originalGoal: "first goal",
            consolidatedText: "First consolidated plan",
            createdAt: firstDate,
            isApproved: false,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "First item")
            ]
        ))

        _ = terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == true)

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
        #expect(prompt.contains("todo.write"))
        #expect(prompt.contains("update it to \"completed\""))
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
    func approveRequiresACompletedPlanAndClearRemovesIt() throws {
        let terminal = try makeTerminal()

        #expect(isContinueChat(terminal.handlePlanCommand("/plan approve")))
        #expect(terminal.activePlan == nil)

        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan"
        )
        #expect(isContinueChat(terminal.handlePlanCommand("/plan approve")))
        #expect(terminal.activePlan?.isApproved == true)

        #expect(isContinueChat(terminal.handlePlanCommand("/plan clear")))
        #expect(terminal.activePlan == nil)
        #expect(isContinueChat(terminal.handlePlanCommand("/plan clear")))
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
    func planDelegationPromptCreatesPlannerSubAgentsForPlanImplementationReviewLoop() {
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
        #expect(prompt.contains("role \"Planner\""))
        #expect(prompt.contains("isolationMode \"report\""))
        #expect(prompt.contains("toolNames:"))
        #expect(prompt.contains("agent.wait"))
        #expect(prompt.contains("call todo.write once with mode \"upsert\""))
        #expect(prompt.contains("stable IDs \"plan-<token>-1\""))
        #expect(prompt.contains("/plan <goal> -> /plan approve"))
        #expect(prompt.contains("implementation work -> /review"))
        #expect(prompt.contains("Do not edit any files yourself in this planning turn"))
        #expect(!prompt.contains("infer the activity to plan"))
        #expect(!prompt.contains("local.writeFile"))
        #expect(!prompt.contains("local.exec"))
        #expect(!prompt.contains("git.add"))
        #expect(!prompt.contains("memory.write"))
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
}
