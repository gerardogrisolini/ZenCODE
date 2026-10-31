//
//  TerminalChat+Plan.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// `/plan` and its subcommands, run by the shared controller (see
    /// ``ChatSessionController/runPlanCommand(line:)``).
    func handlePlanCommand(_ command: String) async -> TerminalSubmittedLineAction {
        await terminalAction(presenting: await chatSession.runPlanCommand(line: command))
    }

    /// Consumes the Goal requested by `/plan approve`. The reply is deliberately
    /// handled as control input: it is not submitted to the model and therefore
    /// cannot become part of a conversation checkpoint.
    func handlePlanApprovalGoalReply(
        _ reply: String
    ) async -> TerminalSubmittedLineAction? {
        guard let outcome = await chatSession.planApprovalGoalReplyAction(for: reply) else {
            return nil
        }
        return await terminalAction(presenting: outcome)
    }

    /// Routes plain text received while the Planner is collecting decisions.
    /// Slash commands and mentions are handled by `submittedLineAction` before
    /// this method is reached. When no Planner is visible to the project any
    /// longer, the reply is not recorded so it can be sent again after
    /// `/agents`.
    func handlePlanBrainstormingReply(_ reply: String) async -> TerminalSubmittedLineAction? {
        guard let outcome = await chatSession.planBrainstormingReplyAction(for: reply) else {
            return nil
        }
        return await terminalAction(presenting: outcome)
    }

    func abandonPlanBrainstorming(
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        await chatSession.abandonPlanBrainstorming(
            closeAllPlanAuthors: closeAllPlanAuthors,
            expectedCollectionID: expectedCollectionID
        )
    }

    nonisolated static let planMissingGoalMessage = ChatSessionNoticeText.planMissingGoalMessage

    nonisolated static let planUnavailableForApprovalMessage =
        ChatSessionNoticeText.planUnavailableForApprovalMessage

    nonisolated static let planDiscussionBlocksMutationMessage =
        ChatSessionNoticeText.planDiscussionBlocksMutationMessage

    nonisolated static let planUnavailableForSavingMessage =
        ChatSessionNoticeText.planUnavailableForSavingMessage

    nonisolated static let savedPlanUnavailableMessage =
        ChatSessionNoticeText.savedPlanUnavailableMessage

    nonisolated static let savedPlansAllTerminalMessage =
        ChatSessionNoticeText.savedPlansAllTerminalMessage

    nonisolated static let planDeleteUsageMessage = ChatSessionNoticeText.planDeleteUsageMessage

    typealias SavedPlanDeletionResolution = PlanningCommandKernel.SavedPlanDeletionResolution

    /// Resolves the target of /plan delete among the known saved-plan ids:
    /// `all` selects everything, an exact id wins, and otherwise a unique id
    /// prefix is accepted so users do not have to retype full plan UUIDs.
    nonisolated static func savedPlanDeletionTarget(
        _ target: String,
        in planIDs: [String]
    ) -> SavedPlanDeletionResolution {
        PlanningCommandKernel.savedPlanDeletionTarget(target, in: planIDs)
    }

    /// Extracts the delete target from the raw /plan argument, e.g.
    /// "delete plan-1234" → "plan-1234".
    nonisolated static func planDeleteTarget(from argument: String) -> String? {
        guard let separator = argument.firstIndex(where: \.isWhitespace) else {
            return nil
        }
        let target = argument[argument.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    /// A saved plan stays loadable only while its library graph is still a
    /// reusable draft; completed entries are historical.
    nonisolated static func loadableSavedPlan(
        from savedPlans: [SavedTaskPlan]
    ) -> SavedTaskPlan? {
        PlanningCommandKernel.loadableSavedPlan(from: savedPlans)
    }

    nonisolated static func planDeleteNotFoundMessage(
        availablePlanIDs: [String]
    ) -> String {
        PlanningCommandKernel.planDeleteNotFoundMessage(
            availablePlanIDs: availablePlanIDs
        )
    }

    nonisolated static func planDeleteAmbiguousMessage(
        matches: [String]
    ) -> String {
        PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
    }

    nonisolated static func planDeleteSuccessMessage(
        deletedPlanIDs: [String],
        activePlanAffected: Bool
    ) -> String {
        PlanningCommandKernel.planDeleteSuccessMessage(
            deletedPlanIDs: deletedPlanIDs,
            activePlanAffected: activePlanAffected
        )
    }

    nonisolated static func savedPlansListMessage(
        for savedPlans: [SavedTaskPlan]
    ) -> String {
        PlanningCommandKernel.savedPlansListMessage(for: savedPlans)
    }

    nonisolated static func planPreparedForSaving(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planPreparedForSaving(plan)
    }

    nonisolated static func planFromLatestAssistantMessage(
        in messages: [AgentRuntimeMessage],
        createdAt: Date = Date()
    ) -> TerminalSessionPlan? {
        PlanningCommandKernel.planFromLatestAssistantMessage(
            in: messages,
            createdAt: createdAt
        )
    }

    nonisolated static func planPreparedForReuse(
        _ savedPlan: SavedTaskPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planPreparedForReuse(savedPlan)
    }

    /// Gives a legacy text-only plan one stable task at approval time rather
    /// than attempting to infer an unreliable task breakdown from prose.
    /// This keeps every approved plan on the same task-graph control plane.
    nonisolated static func planMaterializedForApproval(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planMaterializedForApproval(plan)
    }

    nonisolated static func savedPlanContextMessage(
        _ savedPlan: SavedTaskPlan,
        plan: TerminalSessionPlan
    ) -> String {
        PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
    }

    nonisolated static let planAuthorAgentName = PlanningCommandKernel.planAuthorAgentName

    nonisolated static func planImplementationPrompt(for plan: TerminalSessionPlan) -> String {
        PlanningCommandKernel.planImplementationPrompt(for: plan)
    }

    nonisolated static func planStatusTable(for plan: TerminalSessionPlan) -> String {
        PlanningCommandKernel.planStatusTable(for: plan, graph: nil)
    }

    nonisolated static func planStatusTable(
        for plan: TerminalSessionPlan,
        graph: TaskGraphSnapshot?
    ) -> String {
        PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
    }

    nonisolated static func plan(
        _ plan: TerminalSessionPlan,
        applying graph: TaskGraphSnapshot
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.plan(plan, applying: graph)
    }

    nonisolated static func taskDefinitions(
        for points: [TerminalSessionPlanPoint]
    ) -> [TaskDefinition] {
        PlanningCommandKernel.taskDefinitions(for: points)
    }

    nonisolated static func planPointUpdates(
        from toolCall: DirectAgentToolCall
    ) -> (points: [TerminalSessionPlanPoint], mode: DirectTodoTaskRuntime.TodoWriteMode)? {
        PlanningCommandKernel.planPointUpdates(from: toolCall)
    }

    @discardableResult
    func synchronizeActivePlanStatus(
        from toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Bool {
        chatSession.synchronizeActivePlanStatus(from: toolCall, result: result)
    }

    func synchronizeTaskGraphFromLegacyTodo(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        await chatSession.synchronizeTaskGraphFromLegacyTodo(toolCall: toolCall, result: result)
    }

    /// Resolves the Planner profiles `/plan` may delegate to: every profile
    /// with the planner role visible to the project. An empty result means
    /// the command must stop.
    func plannerProfilesForDelegation() -> [AgentProfile] {
        chatSession.plannerProfilesForDelegation()
    }

    nonisolated static func plannerAuthoredPlanResponse(
        parentResponse: DirectAgentResponse,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        excludingAgentIDs: Set<String> = []
    ) -> DirectAgentResponse? {
        let eligibleSnapshots = snapshots.filter { !excludingAgentIDs.contains($0.id) }
        let baseline = PlannerTurnBaseline(
            state: nil,
            snapshots: [],
            rootSessionID: nil
        )
        return PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: eligibleSnapshots,
            baseline: baseline,
            rootSessionID: nil
        )?.response
    }
}

typealias TerminalPlanPointCollector = PlanningPointCollector
