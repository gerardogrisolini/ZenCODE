//
//  TerminalChat+Goal.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func handleWorkflowCommand(_ command: String) async -> TerminalSubmittedLineAction {
        guard case let .goal(argument) = CoordinatorCommandParser.parse(command) else {
            await writeFailureMessage(Self.workflowMissingGoalMessage)
            return .continueChat
        }

        guard !argument.isEmpty else {
            await writeFailureMessage(Self.workflowMissingGoalMessage)
            return .continueChat
        }

        guard activePlan == nil, planBrainstorming == nil else {
            await writeFailureMessage(Self.workflowActivePlanMessage)
            return .continueChat
        }

        if !isSubAgentToolEnabled {
            await writeFailureMessage(
                """
                ZenCODE: /goal requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await sessionRunner.taskOrchestrator.createGraph(
                sessionID: sessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: []
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return .continueChat
        }

        await writeSubmittedPrompt(command)

        return .runHiddenPrompt(
            Self.workflowPrompt(goal: argument, graphID: graphID),
            purpose: .workflow(originalGoal: argument)
        )
    }

    nonisolated static let workflowMissingGoalMessage =
        "ZenCODE: /goal requires a goal. "
        + "Use /goal <goal> to describe what should be planned and delegated.\n"

    nonisolated static let workflowActivePlanMessage =
        "ZenCODE: /goal cannot start while an active plan or planning discussion exists. "
        + "Finish it or use /plan clear before starting a workflow.\n"

    nonisolated static func workflowPrompt(goal: String, graphID: String) -> String {
        PlanningCommandKernel.workflowPrompt(goal: goal, graphID: graphID)
    }
}
