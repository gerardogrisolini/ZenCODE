//
//  ChatPlanningCommandsTests+Support.swift
//  ZenCODE
//
//  Support of the planning command tests: the Planner discussion fixture and
//  the driver that completes the live graph of a plan in another session of
//  the project.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension ChatPlanningCommandsTests {
    /// A Planner discussion waiting for the operator's answer.
    static func plannerDiscussion(goal: String) -> PlanningCommandRuntimeState {
        var state = PlanningCommandRuntimeState(goal: goal)
        state.recordPlannerOutput(
            "Planner questions\n1. Which parser?",
            agentID: "planner-1",
            revision: 1
        )
        return state
    }

    /// Drives a live graph of `plan` to completion in another session of the
    /// project, so the saved-plan library mirrors it as completed.
    @ChatSessionActor
    static func completeLivePlanGraph(
        _ plan: TerminalSessionPlan,
        harness: ChatManagementHarness
    ) async throws {
        let orchestrator = harness.runtime.taskOrchestrator
        let sessionID = "implementation-\(UUID().uuidString.lowercased())"
        try await orchestrator.registerSession(id: sessionID, workingDirectory: harness.workspace)
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: plan.id,
            source: .plan(planID: plan.id),
            state: .active,
            tasks: PlanningCommandKernel.taskDefinitions(for: plan.points)
        )
        for point in plan.points {
            for status in [TaskStatus.inProgress, .completed] {
                _ = try await orchestrator.updateTask(
                    sessionID: sessionID,
                    taskID: point.id,
                    graphID: plan.id,
                    update: TaskUpdate(status: status, output: status.rawValue)
                )
            }
        }
    }
}
