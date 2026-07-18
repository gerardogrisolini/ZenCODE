//
//  WorkflowCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct WorkflowCommandTests {
    @Test
    func workflowCommandCreatesAnActiveDelegatedGraphBeforePrompting() async throws {
        let terminal = try makeTerminal()

        let action = await terminal.handleWorkflowCommand("/workflow Ship delegated work")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("/workflow should start its coordinator prompt")
            return
        }

        #expect(purpose == .workflow(originalGoal: "Ship delegated work"))
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))
        #expect(graph.source == .workflow)
        #expect(graph.state == .active)
        #expect(graph.tasks.isEmpty)
        #expect(graph.id.hasPrefix("workflow_"))
        #expect(prompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(prompt.contains("execution.executor set to sub_agent"))
        #expect(prompt.contains("do not start a task attempt directly with tasks.update"))
    }

    @Test
    func workflowCommandRejectsAnActivePlanWithoutCreatingOrReplacingAGraph() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            id: "active-plan",
            originalGoal: "Finish the existing plan",
            consolidatedText: "Keep this plan intact.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        terminal.activePlan = plan

        let action = await terminal.handleWorkflowCommand("/workflow Start another workflow")

        guard case .continueChat = action else {
            Issue.record("/workflow must stop when an active plan exists")
            return
        }
        #expect(terminal.activePlan == plan)
        #expect(TerminalChat.workflowActivePlanMessage.contains("active plan"))
        #expect(TerminalChat.workflowActivePlanMessage.contains("/plan clear"))
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ) == nil)
    }

    @Test
    func workflowPromptRequiresDelegationWithoutAReadOnlyCoordinatorPolicy() {
        let prompt = TerminalChat.workflowPrompt(
            goal: "Ship delegated work",
            graphID: "workflow_test"
        )

        #expect(prompt.contains("Every workflow task is delegated through agent.create(taskID:)"))
        #expect(prompt.contains("the task graph enforces sub-agent execution"))
        #expect(!prompt.contains("your only direct actions"))
        #expect(!prompt.localizedCaseInsensitiveContains("read-only"))
        #expect(prompt.contains("validation is negative, record the task as failed"))
        #expect(prompt.contains("call tasks.retry"))
        #expect(prompt.contains("new agent.create(taskID:)"))
        #expect(prompt.contains("Do not use agent.message to request corrections"))
        #expect(!prompt.contains("use agent.message to request corrections or"))
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-workflow-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }
}
