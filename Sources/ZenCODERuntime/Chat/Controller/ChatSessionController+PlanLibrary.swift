//
//  ChatSessionController+PlanLibrary.swift
//  ZenCODE
//
//  The saved-plan library of `/plan`: save, load, list, and delete.
//

import Foundation
import ToolCore

extension ChatSessionController {
    // MARK: - Saved-plan library

    /// `/plan save`: stores the active plan and its queued plans, or the
    /// latest plans an agent wrote, in the project's saved-plan library in one
    /// commit, and makes the first the active plan and the others its queue.
    /// A plan the library already holds keeps its original save time; new
    /// plans get increasing save times in sequence order, so `/plan load`
    /// restores the sequence from its first unfinished plan.
    func saveReusablePlan(
        fence: ChatCommandFence?,
        source: ChatPlanningCommandPolicy.PlanSave,
        savedAt: Date = Date()
    ) async -> [ChatSessionNotice] {
        let candidates: [TerminalSessionPlan]
        let savingAgent: AgentProfile?
        switch source {
        case .terminal:
            candidates = reusablePlanCandidates(createdAt: savedAt)
            savingAgent = selection.agent
        case let .acp(agent, fallbackHistory):
            let plans: [TerminalSessionPlan]
            if let activePlan {
                plans = [activePlan] + queuedPlans
            } else {
                let snapshot = await runtime.snapshotSession(id: sessionID)
                plans = PlanningCommandKernel.plansFromLatestAssistantMessage(
                    in: snapshot?.history ?? fallbackHistory,
                    createdAt: savedAt
                )
            }
            // A plan without text is not saveable, and neither is a sequence
            // that holds one.
            candidates = plans.allSatisfy { $0.consolidatedText.nilIfBlank != nil } ? plans : []
            savingAgent = agent
        }
        guard let firstPlan = candidates.first else {
            return [.planUnavailableForSaving]
        }

        let existingSavedAt = Dictionary(
            await runtime.taskOrchestrator.savedTaskPlans(workingDirectory: workingDirectory)
                .map { ($0.graph.id, $0.snapshot.savedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let drafts = candidates.enumerated().map { index, plan in
            let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
            return SavedPlanDraft(
                savedPlan: TaskGraphSavedPlan(
                    plan: storedPlan,
                    savedAt: existingSavedAt[plan.id]
                        ?? savedAt.addingTimeInterval(Double(index) * 0.001),
                    savingAgentID: savingAgent?.id,
                    savingAgentName: savingAgent?.name
                ),
                tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
            )
        }
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        do {
            try await runtime.taskOrchestrator.registerSession(
                id: librarySessionID,
                workingDirectory: workingDirectory
            )
            _ = try await runtime.taskOrchestrator.savePlanDrafts(
                drafts,
                sessionID: librarySessionID
            )
        } catch {
            return [.operationFailed(description: error.localizedDescription)]
        }

        let queue = Array(candidates.dropFirst())
        guard commitCommandState(fence, { state in
            state.activePlan = firstPlan
            state.queuedPlans = queue
        }) else {
            return []
        }
        guard candidates.count > 1 else {
            return [.planSaved(planID: firstPlan.id)]
        }
        return [.planSequenceSaved(planIDs: candidates.map(\.id))]
    }

    /// The plans `/plan save` stores, in sequence order: the active plan and
    /// its queued plans when the active plan has a goal and a text, otherwise
    /// the latest plans in the transcript, then in the history.
    func reusablePlanCandidates(createdAt: Date = Date()) -> [TerminalSessionPlan] {
        if let activePlan,
           activePlan.originalGoal.nilIfBlank != nil,
           activePlan.consolidatedText.nilIfBlank != nil {
            return [activePlan] + queuedPlans
        }
        let transcriptPlans = PlanningCommandKernel.plansFromLatestAssistantMessage(
            in: transcript,
            createdAt: createdAt
        )
        if !transcriptPlans.isEmpty {
            return transcriptPlans
        }
        return PlanningCommandKernel.plansFromLatestAssistantMessage(
            in: history,
            createdAt: createdAt
        )
    }

    /// `/plan load`: makes the first saved plan that is not completed, i.e.
    /// the oldest save, the unapproved active plan with an empty queue, and
    /// adds it to the session context.
    func loadReusablePlan(
        fence: ChatCommandFence?,
        source: ChatPlanningCommandPolicy.PlanLoad
    ) async -> [ChatSessionNotice] {
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if case .acp = source {
            guard let current = await runtime.currentSessionGeneration(for: sessionID) else {
                return [.runtimeSessionUnavailable]
            }
            generation = current
        }
        guard activePlan == nil else {
            return [.activePlanAlreadyExists]
        }
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.savedPlanUnavailable]
        }
        guard let savedPlan = PlanningCommandKernel.loadableSavedPlan(from: savedPlans) else {
            return [.savedPlansAllCompleted]
        }

        let plan = PlanningCommandKernel.planPreparedForReuse(savedPlan)
        let contextMessage = AgentRuntimeMessage(
            role: .user,
            content: PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
        )

        switch source {
        case .terminal:
            let replacementHistory = history + [contextMessage]
            if await runtime.snapshotSession(id: sessionID) != nil {
                guard await replaceRuntimeSessionHistory(replacementHistory) else {
                    return [.savedPlanContextNotAdded]
                }
            }

            history = replacementHistory
            appendTranscript(contextMessage)
            guard commitCommandState(fence, { state in
                state.activePlan = plan
                state.queuedPlans = []
            }) else {
                return []
            }
            return [.savedPlanLoaded(plan)]
        case let .acp(fallbackHistory):
            guard let generation else {
                return [.runtimeSessionUnavailable]
            }
            let baseHistory = (await runtime.snapshotSession(id: sessionID))?.history
                ?? fallbackHistory
            let replacementHistory = baseHistory + [contextMessage]
            guard isCommandCurrent(fence) else {
                return []
            }
            guard await runtime.replaceSessionHistory(
                id: sessionID,
                history: replacementHistory,
                expectedSessionGeneration: generation
            ) else {
                return [.savedPlanContextNotAdded]
            }
            guard commitCommandState(fence, { state in
                state.activePlan = plan
                state.queuedPlans = []
            }) else {
                // Superseded after the replacement: put the history back while
                // the replacement is still the installed one.
                if let installed = await runtime.snapshotSession(id: sessionID),
                   installed.history == replacementHistory {
                    _ = await runtime.replaceSessionHistory(
                        id: sessionID,
                        history: baseHistory,
                        expectedSessionGeneration: generation
                    )
                }
                return []
            }
            return [.savedPlanLoaded(plan)]
        }
    }

    /// Replaces the conversation of the runtime session at its current
    /// generation; `false` when the session has none or the replacement fails.
    private func replaceRuntimeSessionHistory(_ history: [AgentRuntimeMessage]) async -> Bool {
        guard let generation = await runtime.currentSessionGeneration(for: sessionID) else {
            return false
        }
        return await runtime.replaceSessionHistory(
            id: sessionID,
            history: history,
            expectedSessionGeneration: generation
        )
    }

    /// `/plan list`: every saved plan for this project, newest save first,
    /// including entries that were already mirrored as completed so the
    /// library stays inspectable.
    func listSavedPlans() async -> [ChatSessionNotice] {
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.noSavedPlans]
        }
        return [.savedPlans(savedPlans)]
    }

    /// `/plan delete`: deletes saved plans from the project library. The
    /// target can be a full plan id, a unique id prefix, or `all`; the parser
    /// hands it over trimmed, `nil` when the command names none. The active
    /// plan of the session and its live task graph are never touched here:
    /// that is `/plan clear`'s session-scoped role.
    func deleteSavedPlans(
        target: String?,
        style: ChatPlanningCommandPolicy.Style
    ) async -> [ChatSessionNotice] {
        if style == .acp, target == nil {
            return [.planDeleteUsage]
        }
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.savedPlanUnavailable]
        }
        guard let target else {
            return [.planDeleteUsage]
        }
        switch PlanningCommandKernel.savedPlanDeletionTarget(
            target,
            in: savedPlans.map(\.graph.id)
        ) {
        case .notFound:
            return [.savedPlanNotFound(availablePlanIDs: savedPlans.map(\.graph.id))]
        case let .ambiguous(matches):
            return [.savedPlanAmbiguous(matches: matches)]
        case let .ids(planIDs):
            do {
                let deletedPlanIDs = try await requiredManagementRuntime().deleteSavedTaskPlans(
                    planIDs: planIDs,
                    workingDirectory: workingDirectory
                )
                return [
                    .savedPlansDeleted(
                        planIDs: deletedPlanIDs,
                        activePlanAffected: activePlan.map { planIDs.contains($0.id) } ?? false
                    ),
                ]
            } catch {
                return [.operationFailed(description: error.localizedDescription)]
            }
        }
    }
}
