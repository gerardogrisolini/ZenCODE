//
//  AgentCoreSessionRunner+Tasks.swift
//  ZenCODE
//

import Foundation

public extension AgentCoreSessionRunner {
    func taskGraphSnapshot(
        sessionID: String,
        graphID: String? = nil
    ) async throws -> TaskGraphSnapshot? {
        try await taskOrchestrator.graphSnapshot(
            sessionID: sessionID,
            graphID: graphID
        )
    }

    func taskGraphSnapshots(
        sessionID: String
    ) async throws -> [TaskGraphSnapshot] {
        try await taskOrchestrator.graphSnapshots(sessionID: sessionID)
    }

    @discardableResult
    func restoreTaskGraph(
        _ snapshot: TaskGraphSnapshot,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.restoreTaskGraph(
            snapshot,
            sessionID: sessionID
        )
    }

    @discardableResult
    func activateTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.activateGraph(
            id: graphID,
            sessionID: sessionID
        )
    }

    @discardableResult
    func archiveTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.archiveGraph(
            id: graphID,
            sessionID: sessionID
        )
    }

    @discardableResult
    func removeTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.removeGraph(
            id: graphID,
            sessionID: sessionID
        )
    }

    func clearTaskGraphs(sessionID: String) async throws {
        try await taskOrchestrator.clearTaskGraphs(sessionID: sessionID)
    }

    @discardableResult
    func retryTask(
        id taskID: String,
        sessionID: String,
        expectedRevision: Int? = nil
    ) async throws -> TaskRecordView {
        try await taskOrchestrator.retryTask(
            sessionID: sessionID,
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func cancelTask(
        id taskID: String,
        sessionID: String,
        reason: String? = nil
    ) async throws -> TaskCancellation {
        let cancellation = try await taskOrchestrator.cancelTask(
            sessionID: sessionID,
            taskID: taskID,
            reason: reason
        )
        if let agentID = cancellation.agentID {
            _ = await closeSubAgent(id: agentID)
        }
        return cancellation
    }
}
