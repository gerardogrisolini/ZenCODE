//
//  SessionTaskOrchestrator+PlanDrafts.swift
//  ZenCODE
//
//  Saving unapproved plans as non-current draft graphs, replacing earlier
//  copies of the same plan in one checkpoint commit.
//

import Foundation
import ToolCore

extension SessionTaskOrchestrator {
    /// Atomically materializes an unapproved plan as a non-current draft graph.
    /// Existing copies with the same plan ID are replaced in one checkpoint
    /// commit, so a failure cannot erase the last saved version.
    @discardableResult
    public func savePlanDraft(
        _ savedPlan: TaskGraphSavedPlan,
        sessionID rawSessionID: String,
        tasks definitions: [TaskDefinition]
    ) throws -> TaskGraphSnapshot {
        let snapshots = try savePlanDrafts(
            [SavedPlanDraft(savedPlan: savedPlan, tasks: definitions)],
            sessionID: rawSessionID
        )
        guard let snapshot = snapshots.first else {
            throw SessionTaskOrchestratorError.invalidSnapshot("the plan draft was not saved")
        }
        return snapshot
    }

    /// Atomically materializes several unapproved plans as non-current draft
    /// graphs in ONE checkpoint commit: either every draft is saved or none is,
    /// and a failure cannot erase the last saved version of any of them. Each
    /// draft follows the `savePlanDraft` rules; two drafts that share a
    /// normalized plan ID are rejected. An empty batch returns `[]` without
    /// committing. Snapshots are returned in the order of `drafts`.
    @discardableResult
    public func savePlanDrafts(
        _ drafts: [SavedPlanDraft],
        sessionID rawSessionID: String
    ) throws -> [TaskGraphSnapshot] {
        let sessionID = try requireRootAccess(rawSessionID)
        guard !drafts.isEmpty else {
            return []
        }

        var sessionState = sessionStates[sessionID] ?? .empty
        let now = Date()
        var seenGraphIDs = Set<String>()
        var savedGraphs: [(graph: TaskGraphSnapshot, eventKind: TaskGraphEvent.Kind)] = []
        for draft in drafts {
            let savedPlan = draft.savedPlan
            let graphID = try normalizedGraphID(savedPlan.plan.id)
            guard !savedPlan.plan.isApproved else {
                throw SessionTaskOrchestratorError.invalidSnapshot("an approved plan cannot be saved as a draft")
            }
            guard seenGraphIDs.insert(graphID).inserted else {
                throw SessionTaskOrchestratorError.invalidSnapshot(
                    "plan '\(graphID)' appears more than once in the batch"
                )
            }

            let isNewGraph = sessionState.graphs[graphID] == nil
            let records = try makeTaskRecords(draft.tasks, existingTasks: [], now: now)
            var graph: TaskGraphSnapshot
            if let existing = sessionState.graphs[graphID] {
                guard existing.source.planID == graphID,
                      existing.state != .active,
                      !existing.hasActiveAttempt else {
                    throw SessionTaskOrchestratorError.graphNotMutable(graphID)
                }
                graph = existing
                graph.state = .draft
                graph.tasks = records
                graph.savedPlan = savedPlan
                touchGraph(&graph, at: now)
                if sessionState.currentGraphID == graphID {
                    sessionState.currentGraphID = nil
                }
            } else {
                graph = TaskGraphSnapshot(
                    id: graphID,
                    source: .plan(planID: graphID),
                    state: .draft,
                    tasks: records,
                    savedPlan: savedPlan,
                    createdAt: now,
                    updatedAt: now
                )
            }
            try validate(graph)
            sessionState.graphs[graphID] = graph
            savedGraphs.append((graph, isNewGraph ? .created : .updated))
        }

        try commitSavedPlanDrafts(
            sessionID: sessionID,
            state: sessionState,
            saved: savedGraphs.map { ($0.graph.id, $0.eventKind) }
        )
        return savedGraphs.map(\.graph)
    }

    /// Batch counterpart of `commit(sessionID:state:eventKind:graphID:)`: persists
    /// and installs `state` once, then runs the post-persist steps (library
    /// mirror and event) for every saved graph in order.
    private func commitSavedPlanDrafts(
        sessionID: String,
        state: SessionState,
        saved: [(graphID: String, eventKind: TaskGraphEvent.Kind)]
    ) throws {
        try persist(sessionID: sessionID, state: state)
        sessionStates[sessionID] = state
        for (graphID, eventKind) in saved {
            mirrorCompletedPlanToSavedPlanLibrary(
                sessionID: sessionID,
                state: state,
                graphID: graphID
            )
            emit(
                sessionID: sessionID,
                graphID: graphID,
                revision: state.graphs[graphID]?.revision,
                kind: eventKind
            )
        }
    }
}
