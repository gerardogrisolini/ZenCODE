//
//  GoalCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct GoalCommandTests {
    @Test
    func goalCommandCreatesAnActiveDelegatedGraphBeforePrompting() async throws {
        let terminal = try makeTerminal()

        let action = await terminal.submittedLineAction("/goal Ship delegated work")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("/goal should start its coordinator prompt")
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
        #expect(prompt.contains("Do not start a task attempt directly with tasks.update"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved and validated"))
        #expect(prompt.contains("ask the user a focused clarification question instead of guessing"))
    }

    @Test
    func goalCommandRejectsAnActivePlanWithoutCreatingOrReplacingAGraph() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            id: "active-plan",
            originalGoal: "Finish the existing plan",
            consolidatedText: "Keep this plan intact.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        terminal.activePlan = plan

        let action = await terminal.submittedLineAction("/goal Start another workflow")

        guard case .continueChat = action else {
            Issue.record("/goal must stop when an active plan exists")
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
    func goalCommandDoesNotOverlapAnUnfinishedPlannerDiscussion() async throws {
        let terminal = try makeTerminal()
        var discussion = PlanningCommandRuntimeState(goal: "clarify first")
        discussion.recordPlannerOutput(
            "Planner questions\n1. Choose the compatibility behavior?",
            agentID: "planner-goal-block",
            revision: 1
        )
        terminal.planBrainstorming = discussion

        guard case .continueChat = await terminal.submittedLineAction(
            "/goal must not overlap"
        ) else {
            Issue.record("/goal must not overlap an unfinished /plan discussion")
            return
        }
        #expect(terminal.planBrainstorming == discussion)
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ) == nil)
    }

    @Test
    func goalPromptRequiresDelegationWithoutAReadOnlyCoordinatorPolicy() {
        let prompt = TerminalChat.workflowPrompt(
            goal: "Ship delegated work",
            graphID: "workflow_test"
        )

        #expect(prompt.contains("canonical `agents` array"))
        #expect(prompt.contains("task ID in the item's `taskID` field"))
        #expect(prompt.contains("the task graph enforces sub-agent execution"))
        #expect(!prompt.contains("your only direct actions"))
        #expect(!prompt.localizedCaseInsensitiveContains("read-only"))
        #expect(prompt.contains("validation is negative, record the task as failed"))
        #expect(prompt.contains("call tasks.retry"))
        #expect(prompt.contains("new canonical agent.create item containing `taskID`"))
        #expect(prompt.contains("Do not use agent.message to request corrections"))
        #expect(prompt.contains("Stop without achieving the goal only for a genuine blocker"))
        #expect(prompt.contains("resume this same goal graph"))
        #expect(prompt.contains("exhaust the clarification, evidence, suitable-agent, and retry paths"))
        #expect(prompt.contains("acceptance criterion as a follow-up"))
        #expect(!prompt.contains("all tasks are completed or a real blocker is reached"))
        #expect(!prompt.contains("use agent.message to request corrections or"))
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
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
