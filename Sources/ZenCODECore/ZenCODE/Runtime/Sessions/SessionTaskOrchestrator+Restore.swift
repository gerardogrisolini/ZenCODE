//
//  SessionTaskOrchestrator+Restore.swift
//  ZenCODE
//

import Foundation

extension SessionTaskOrchestrator {
    @discardableResult
    public func restoreTaskGraph(
        _ snapshot: TaskGraphSnapshot,
        sessionID rawSessionID: String,
        interruptActiveAttempts: Bool = true
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        var graph = snapshot
        try validate(graph)
        if interruptActiveAttempts {
            markActiveAttemptsInterrupted(in: &graph)
        }
        try validate(graph)
        let state = SessionState(
            currentGraphID: graph.id,
            graphs: [graph.id: graph]
        )
        try commit(
            sessionID: sessionID,
            state: state,
            eventKind: .restored,
            graphID: graph.id
        )
        return graph
    }

    public func restoreCheckpoint(
        _ checkpoint: SessionTaskGraphCheckpoint,
        interruptActiveAttempts: Bool = true
    ) throws {
        try restoreCheckpoint(
            checkpoint,
            interruptActiveAttempts: interruptActiveAttempts,
            persist: true
        )
    }

    func restoreCheckpoint(
        _ checkpoint: SessionTaskGraphCheckpoint,
        interruptActiveAttempts: Bool,
        persist shouldPersist: Bool
    ) throws {
        guard checkpoint.schemaVersion == SessionTaskGraphCheckpoint.currentSchemaVersion else {
            throw SessionTaskOrchestratorError.invalidSnapshot(
                "unsupported checkpoint schema version \(checkpoint.schemaVersion)"
            )
        }
        let sessionID = try normalizedSessionID(checkpoint.sessionID)
        var graphs: [String: TaskGraphSnapshot] = [:]
        for var graph in checkpoint.graphs {
            guard graphs[graph.id] == nil else {
                throw SessionTaskOrchestratorError.invalidSnapshot(
                    "duplicate graph id \(graph.id)"
                )
            }
            try validate(graph)
            if interruptActiveAttempts {
                markActiveAttemptsInterrupted(in: &graph)
            }
            try validate(graph)
            graphs[graph.id] = graph
        }
        if let currentGraphID = checkpoint.currentGraphID,
           graphs[currentGraphID] == nil {
            throw SessionTaskOrchestratorError.invalidSnapshot(
                "current graph \(currentGraphID) is missing"
            )
        }

        let state = SessionState(
            currentGraphID: checkpoint.currentGraphID,
            graphs: graphs
        )
        if shouldPersist {
            try commit(
                sessionID: sessionID,
                state: state,
                eventKind: .restored,
                graphID: checkpoint.currentGraphID
            )
        } else {
            sessionStates[sessionID] = state
            emit(
                sessionID: sessionID,
                graphID: checkpoint.currentGraphID,
                revision: checkpoint.currentGraphID.flatMap { graphs[$0]?.revision },
                kind: .restored
            )
        }
    }

    func markActiveAttemptsInterrupted(in graph: inout TaskGraphSnapshot) {
        let now = Date()
        var graphChanged = false
        for index in graph.tasks.indices {
            var task = graph.tasks[index]
            var taskChanged = false
            for attemptIndex in task.attempts.indices
            where task.attempts[attemptIndex].status.isActive {
                task.attempts[attemptIndex].status = .interrupted
                task.attempts[attemptIndex].finishedAt = now
                task.attempts[attemptIndex].error =
                    "execution interrupted during session restore"
                taskChanged = true
            }
            if task.activeAttemptID != nil || task.status == .inProgress {
                task.activeAttemptID = nil
                task.status = .blocked
                task.statusReason = "execution interrupted during session restore"
                taskChanged = true
            }
            if taskChanged {
                touchTask(&task, at: now)
                graph.tasks[index] = task
                graphChanged = true
            }
        }
        if graphChanged {
            if graph.state == .completed {
                graph.state = .active
            }
            touchGraph(&graph, at: now)
        }
    }
}
