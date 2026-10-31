//
//  ZenCODEACPBridge+PlanLibrary.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    func saveACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        savedAt: Date = Date()
    ) async -> String {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return "ZenCODE: the ACP session changed while saving the plan."
        }
        let snapshot = await sessionRunner.snapshotSession(id: sessionID)
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            return "ZenCODE: the ACP session changed while saving the plan."
        }
        guard let plan = session.activePlan
                ?? PlanningCommandKernel.planFromLatestAssistantMessage(
                    in: snapshot?.history ?? session.configuration.history,
                    createdAt: savedAt
                ),
              plan.consolidatedText.nilIfBlank != nil else {
            return "ZenCODE: no completed plan is available to save."
        }
        let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
        let savedPlan = TaskGraphSavedPlan(
            plan: storedPlan,
            savedAt: savedAt,
            savingAgentID: session.selectedAgent?.id,
            savingAgentName: session.selectedAgent?.name
        )
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(for: workingDirectory)
        do {
            try await sessionRunner.taskOrchestrator.registerSession(
                id: librarySessionID,
                workingDirectory: workingDirectory
            )
            _ = try await sessionRunner.taskOrchestrator.savePlanDraft(
                savedPlan,
                sessionID: librarySessionID,
                tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
            )
            guard updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.activePlan = plan }
            ) else {
                return "ZenCODE: the ACP session changed while saving the plan."
            }
            return "Saved plan: \(plan.id). Use /plan load in a new session to review or revise it."
        } catch {
            return "ZenCODE: \(error.localizedDescription)"
        }
    }

    func loadACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> String {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return "ZenCODE: the ACP session changed while loading the plan."
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(for: sessionID) else {
            return "ZenCODE: the ACP session changed while loading the plan."
        }
        guard session.activePlan == nil else {
            return "ZenCODE: an active plan already exists. Use /plan clear before loading a saved plan."
        }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let savedPlans = await sessionRunner.savedTaskPlans(workingDirectory: workingDirectory)
        guard let savedPlan = PlanningCommandKernel.loadableSavedPlan(from: savedPlans) else {
            return savedPlans.isEmpty
                ? "ZenCODE: no saved plan is available for this project."
                : "ZenCODE: every saved plan for this project is already completed."
        }
        let plan = PlanningCommandKernel.planPreparedForReuse(savedPlan)
        let contextMessage = AgentRuntimeMessage(
            role: .user,
            content: PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
        )
        let history = (await sessionRunner.snapshotSession(id: sessionID))?.history
            ?? session.configuration.history
        guard await sessionRunner.replaceSessionHistory(
            id: sessionID,
            history: history + [contextMessage],
            expectedSessionGeneration: runnerGeneration
        ) else {
            return "ZenCODE: the saved plan could not be added to the current ACP session."
        }
        await refreshSessionStateIfAvailable(
            sessionID: sessionID,
            preservingAllowedToolNames: session.allowedToolNames,
            expectedEpoch: epoch,
            expectedPromptID: promptID
        )
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.activePlan = plan }
        ) else {
            if let installed = await sessionRunner.snapshotSession(id: sessionID),
               installed.history == history + [contextMessage] {
                _ = await sessionRunner.replaceSessionHistory(
                    id: sessionID,
                    history: history,
                    expectedSessionGeneration: runnerGeneration
                )
            }
            return "ZenCODE: the saved plan could not be added to the current ACP session."
        }
        return "Loaded saved plan `\(plan.id)` as an unapproved active plan.\n\n\(plan.consolidatedText)\n\nUse /plan approve when it is ready."
    }

    func listACPPlans(session: SessionState) async -> String {
        let savedPlans = await sessionRunner.savedTaskPlans(workingDirectory: URL(fileURLWithPath: session.cwd))
        guard !savedPlans.isEmpty else {
            return "ZenCODE: no saved plan is available for this project."
        }
        return PlanningCommandKernel.savedPlansListMessage(for: savedPlans)
    }

    func deleteACPPlan(target: String?, session: SessionState) async -> String {
        guard let target = target?.nilIfBlank else {
            return "ZenCODE: /plan delete requires a plan id, unique prefix, or all."
        }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let savedPlans = await sessionRunner.savedTaskPlans(workingDirectory: workingDirectory)
        guard !savedPlans.isEmpty else {
            return "ZenCODE: no saved plan is available for this project."
        }
        switch PlanningCommandKernel.savedPlanDeletionTarget(target, in: savedPlans.map(\.graph.id)) {
        case .notFound:
            return PlanningCommandKernel.planDeleteNotFoundMessage(availablePlanIDs: savedPlans.map(\.graph.id))
        case let .ambiguous(matches):
            return PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
        case let .ids(planIDs):
            do {
                let deleted = try await sessionRunner.deleteSavedTaskPlans(
                    planIDs: planIDs,
                    workingDirectory: workingDirectory
                )
                return PlanningCommandKernel.planDeleteSuccessMessage(
                    deletedPlanIDs: deleted,
                    activePlanAffected: session.activePlan.map {
                        planIDs.contains($0.id)
                    } ?? false
                )
            } catch {
                return "ZenCODE: \(error.localizedDescription)"
            }
        }
    }

    func acpPlanStatus(session: SessionState) async -> String {
        var sections: [String] = []
        if let brainstorming = session.planBrainstorming {
            sections.append("Planner clarification is active for: \(brainstorming.goal)")
        }
        if session.pendingPlanApprovalPlanID != nil {
            sections.append("A descriptive Goal is required before plan approval can continue.")
        }
        guard let plan = session.activePlan else {
            sections.append("No active plan.")
            return sections.joined(separator: "\n\n")
        }
        let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: session.id, graphID: plan.id)
        let projected = graph.map { PlanningCommandKernel.plan(plan, applying: $0) } ?? plan
        sections.append(PlanningCommandKernel.planStatusTable(for: projected, graph: graph))
        return sections.joined(separator: "\n\n")
    }

    func requestACPPlanApprovalGoal(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID), let plan = session.activePlan,
           plan.consolidatedText.nilIfBlank != nil else {
            return .immediate("ZenCODE: no completed plan is available to approve. Run /plan <goal> first.")
        }
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.pendingPlanApprovalPlanID = plan.id }
        ) else {
            return .immediate("ZenCODE: the ACP session changed before plan approval started.")
        }
        return .immediate("Before approving this plan, provide a descriptive Goal for the work it represents.")
    }

    private func persistACPPlanGoal(
        _ plan: TerminalSessionPlan,
        workingDirectory: URL
    ) async throws {
        let savedPlans = await sessionRunner.savedTaskPlans(workingDirectory: workingDirectory)
        guard let saved = savedPlans.first(where: { $0.graph.id == plan.id }) else {
            return
        }
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(for: workingDirectory)
        let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
        let savedCopy = TaskGraphSavedPlan(
            plan: storedPlan,
            savedAt: saved.snapshot.savedAt,
            savingAgentID: saved.snapshot.savingAgentID,
            savingAgentName: saved.snapshot.savingAgentName
        )
        try await sessionRunner.taskOrchestrator.registerSession(
            id: librarySessionID,
            workingDirectory: workingDirectory
        )
        _ = try await sessionRunner.taskOrchestrator.savePlanDraft(
            savedCopy,
            sessionID: librarySessionID,
            tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
        )
    }

    func approveACPPlan(
        originalGoal: String,
        planID: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID), session.pendingPlanApprovalPlanID == planID,
           let sourcePlan = session.activePlan,
           sourcePlan.id == planID else {
            return .immediate("ZenCODE: no pending plan approval is available.")
        }
        guard sourcePlan.consolidatedText.nilIfBlank != nil else {
            return .immediate("ZenCODE: no completed plan is available to approve.")
        }
        var plan = sourcePlan
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(for: sessionID), reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            return .immediate("ZenCODE: the ACP session changed before plan approval completed.")
        }
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.pendingPlanApprovalPlanID = nil }
        ) else {
            return .immediate("ZenCODE: the ACP session changed before plan approval completed.")
        }
        plan = TerminalSessionPlan(
            id: plan.id,
            originalGoal: originalGoal,
            consolidatedText: plan.consolidatedText,
            createdAt: plan.createdAt,
            isApproved: plan.isApproved,
            points: plan.points
        )
        plan = PlanningCommandKernel.planMaterializedForApproval(plan)
        var previousGraph: TaskGraphSnapshot?
        var graphWasMutated = false
        do {
            previousGraph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: plan.id)
            if !plan.isApproved || previousGraph == nil || previousGraph?.tasks.isEmpty == true {
                if previousGraph != nil {
                    graphWasMutated = true
                    _ = try await sessionRunner.removeTaskGraph(id: plan.id, sessionID: sessionID)
                }
                graphWasMutated = true
                _ = try await sessionRunner.taskOrchestrator.createGraph(
                    sessionID: sessionID,
                    id: plan.id,
                    source: .plan(planID: plan.id),
                    state: .draft,
                    tasks: PlanningCommandKernel.taskDefinitions(for: plan.points),
                    makeCurrent: true,
                    archivePreviousCurrent: true
                )
            }
            graphWasMutated = true
            _ = try await sessionRunner.activateTaskGraph(id: plan.id, sessionID: sessionID)
        } catch {
            if graphWasMutated {
                await rollbackACPTaskGraph(previousGraph, graphID: plan.id, sessionID: sessionID, expectedRunnerGeneration: runnerGeneration)
            }
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        plan.isApproved = true
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            {
                $0.activePlan = plan
                $0.pendingPlanApprovalPlanID = nil
            }
        ) else {
            await rollbackACPTaskGraph(previousGraph, graphID: plan.id, sessionID: sessionID, expectedRunnerGeneration: runnerGeneration)
            return .immediate("ZenCODE: the ACP session changed before plan approval completed.")
        }
        do {
            // Update the saved-plan library only after the active graph and
            // active session plan are valid. If persistence fails, the catch
            // below restores both to their pre-approval state.
            try await persistACPPlanGoal(plan, workingDirectory: URL(fileURLWithPath: session.cwd))
        } catch {
            await rollbackACPTaskGraph(previousGraph, graphID: plan.id, sessionID: sessionID, expectedRunnerGeneration: runnerGeneration)
            _ = updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.activePlan = sourcePlan }
            )
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        return .generate(
            prompt: PlanningCommandKernel.planImplementationPrompt(for: plan),
            purpose: .implementation,
            prelude: "Approved the active plan and activated its task graph. Starting implementation now."
        )
    }

    private func rollbackACPTaskGraph(
        _ previousGraph: TaskGraphSnapshot?,
        graphID: String,
        sessionID: String,
        expectedRunnerGeneration: AgentCoreSessionRunner.SessionGeneration
    ) async {
        guard await sessionRunner.isCurrentSessionGeneration(
            expectedRunnerGeneration,
            for: sessionID
        ) else {
            return
        }
        if (try? await sessionRunner.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: graphID
        )) != nil {
            _ = try? await sessionRunner.removeTaskGraph(id: graphID, sessionID: sessionID)
        }
        if let previousGraph {
            _ = try? await sessionRunner.restoreTaskGraph(previousGraph, sessionID: sessionID)
        }
    }

    func clearACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let original = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        let hadDiscussion = original.planBrainstorming != nil
        await clearACPPlanBrainstorming(sessionID: sessionID, epoch: epoch)
        guard let current = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        guard let plan = current.activePlan else {
            return .immediate(
                hadDiscussion
                    ? "Cleared the unfinished planning discussion."
                    : "No active plan or planning discussion to clear."
            )
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(for: sessionID) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        var previousGraph: TaskGraphSnapshot?
        do {
            previousGraph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: plan.id)
            if previousGraph != nil {
                _ = try await sessionRunner.archiveTaskGraph(id: plan.id, sessionID: sessionID)
            }
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.activePlan = nil; $0.pendingPlanApprovalPlanID = nil }
        ) else {
            await rollbackACPTaskGraph(previousGraph, graphID: plan.id, sessionID: sessionID, expectedRunnerGeneration: runnerGeneration)
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        return .immediate(
            "Cleared the active plan and archived its task graph. Saved-plan library copies are unaffected."
        )
    }
}
