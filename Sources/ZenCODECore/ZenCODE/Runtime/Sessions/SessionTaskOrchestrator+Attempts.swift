//
//  SessionTaskOrchestrator+Attempts.swift
//  ZenCODE
//

import Foundation

extension SessionTaskOrchestrator {
    public func claimTasks(
        sessionID rawSessionID: String,
        graphID: String? = nil,
        claims: [TaskClaim]
    ) throws -> [TaskClaimReceipt] {
        let sessionID = try requireRootAccess(rawSessionID)
        guard !claims.isEmpty else { return [] }
        guard var sessionState = sessionStates[sessionID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID ?? "current")
        }
        let resolvedGraphID = graphID?.nilIfBlank ?? sessionState.currentGraphID
        guard let resolvedGraphID,
              var graph = sessionState.graphs[resolvedGraphID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID ?? "current")
        }
        guard graph.state == .active else {
            throw SessionTaskOrchestratorError.graphNotActive(graph.id)
        }

        var seenTaskIDs = Set<String>()
        var taskIndexes: [Int] = []
        taskIndexes.reserveCapacity(claims.count)
        for claim in claims {
            guard seenTaskIDs.insert(claim.taskID).inserted else {
                throw SessionTaskOrchestratorError.duplicateClaim(claim.taskID)
            }
            guard let index = graph.tasks.firstIndex(where: { $0.id == claim.taskID }) else {
                throw SessionTaskOrchestratorError.taskNotFound(claim.taskID)
            }
            let task = graph.tasks[index]
            guard task.activeAttemptID == nil else {
                throw SessionTaskOrchestratorError.taskAlreadyClaimed(task.id)
            }
            guard isRunnable(task, in: graph) else {
                throw SessionTaskOrchestratorError.taskNotRunnable(task.id)
            }
            guard task.attempts.count < limits.maximumAttemptsPerTask else {
                throw SessionTaskOrchestratorError.attemptLimitExceeded(task.id)
            }
            taskIndexes.append(index)
        }

        let now = Date()
        var receipts: [TaskClaimReceipt] = []
        receipts.reserveCapacity(claims.count)
        for (claim, taskIndex) in zip(claims, taskIndexes) {
            var task = graph.tasks[taskIndex]
            let attemptID = "attempt_\(UUID().uuidString.lowercased())"
            let ordinal = task.attempts.count + 1
            task.attempts.append(
                TaskAttempt(
                    id: attemptID,
                    ordinal: ordinal,
                    agentID: claim.agentID,
                    executor: claim.executor,
                    status: .queued,
                    startedAt: now
                )
            )
            task.activeAttemptID = attemptID
            task.status = .inProgress
            task.statusReason = nil
            touchTask(&task, at: now)
            graph.tasks[taskIndex] = task
            receipts.append(
                TaskClaimReceipt(
                    graphID: graph.id,
                    taskID: task.id,
                    attemptID: attemptID,
                    ordinal: ordinal,
                    agentID: claim.agentID
                )
            )
        }

        touchGraph(&graph, at: now)
        try validate(graph)
        sessionState.graphs[graph.id] = graph
        try commit(
            sessionID: sessionID,
            state: sessionState,
            eventKind: .updated,
            graphID: graph.id
        )
        return receipts
    }

    @discardableResult
    public func markAttemptRunning(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String
    ) throws -> Bool {
        try mutateActiveAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID
        ) { task, attempt, _ in
            guard attempt.status == .queued else { return }
            attempt.status = .running
            task.status = .inProgress
        }
    }

    @discardableResult
    public func recordAttemptProgress(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        output: String
    ) throws -> Bool {
        let normalizedOutput = sanitizedPersistedText(
            output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try validateLength(
            normalizedOutput,
            field: "output",
            limit: limits.maximumAttemptOutputLength
        )
        return try mutateActiveAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID
        ) { _, attempt, _ in
            attempt.output = normalizedOutput
        }
    }

    @discardableResult
    public func completeAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        output: String?,
        requiresValidation: Bool
    ) throws -> Bool {
        if let output = output?.nilIfBlank {
            try validateLength(
                output,
                field: "output",
                limit: limits.maximumAttemptOutputLength
            )
        }
        return try finishAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID,
            attemptStatus: .completed,
            taskStatus: requiresValidation ? .awaitingValidation : .completed,
            output: output,
            error: nil,
            statusReason: requiresValidation ? "implementation completed; validation required" : nil
        )
    }

    @discardableResult
    public func failAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        error: String,
        output: String? = nil
    ) throws -> Bool {
        try validateLength(error, field: "error", limit: limits.maximumAttemptOutputLength)
        if let output = output?.nilIfBlank {
            try validateLength(output, field: "output", limit: limits.maximumAttemptOutputLength)
        }
        return try finishAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID,
            attemptStatus: .failed,
            taskStatus: .failed,
            output: output,
            error: error,
            statusReason: error
        )
    }

    @discardableResult
    public func cancelAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        reason: String = "Cancelled."
    ) throws -> Bool {
        try finishAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID,
            attemptStatus: .cancelled,
            taskStatus: .cancelled,
            output: nil,
            error: reason,
            statusReason: reason
        )
    }

    @discardableResult
    public func interruptAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        reason: String = "Execution interrupted."
    ) throws -> Bool {
        try finishAttempt(
            sessionID: rawSessionID,
            taskID: taskID,
            attemptID: attemptID,
            attemptStatus: .interrupted,
            taskStatus: .blocked,
            output: nil,
            error: reason,
            statusReason: reason
        )
    }

    @discardableResult
    public func validateTaskResult(
        sessionID rawSessionID: String,
        taskID: String,
        succeeded: Bool,
        evidence: [TaskEvidence] = [],
        failureReason: String? = nil,
        blocked: Bool = false,
        expectedRevision: Int? = nil
    ) throws -> TaskRecordView {
        let sessionID = try requireRootAccess(rawSessionID)
        var (sessionState, graph, taskIndex) = try mutableTaskLocation(
            sessionID: sessionID,
            graphID: nil,
            taskID: taskID
        )
        var task = graph.tasks[taskIndex]
        if let expectedRevision, expectedRevision != task.revision {
            throw SessionTaskOrchestratorError.staleRevision(
                expected: expectedRevision,
                actual: task.revision
            )
        }
        guard task.status == .awaitingValidation else {
            throw SessionTaskOrchestratorError.invalidTransition(
                taskID: taskID,
                from: task.status,
                to: succeeded ? .completed : (blocked ? .blocked : .failed)
            )
        }

        let now = Date()
        var result = task.result ?? TaskResult()
        result.evidence.append(contentsOf: evidence.map { evidence in
            var sanitized = evidence
            sanitized.summary = sanitizedPersistedText(evidence.summary)
            return sanitized
        })
        if succeeded {
            task.status = .completed
            task.statusReason = nil
            result.error = nil
            result.finishedAt = now
            result.validatedAt = now
        } else {
            task.status = blocked ? .blocked : .failed
            task.statusReason = failureReason?.nilIfBlank.map(sanitizedPersistedText)
                ?? "validation failed"
            result.error = task.statusReason
            result.finishedAt = now
        }
        task.result = result
        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        touchGraph(&graph, at: now)
        updateGraphCompletion(&graph, at: now)
        sessionState.graphs[graph.id] = graph
        try commit(
            sessionID: sessionID,
            state: sessionState,
            eventKind: .updated,
            graphID: graph.id
        )
        return view(for: task, in: graph)
    }

    private func mutateActiveAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        mutation: (inout TaskRecord, inout TaskAttempt, Date) -> Void
    ) throws -> Bool {
        let sessionID = try resolvedRootSessionID(rawSessionID)
        guard var sessionState = sessionStates[sessionID],
              let graphID = sessionState.currentGraphID,
              var graph = sessionState.graphs[graphID],
              let taskIndex = graph.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        var task = graph.tasks[taskIndex]
        guard task.activeAttemptID == attemptID,
              let attemptIndex = task.attempts.firstIndex(where: { $0.id == attemptID }) else {
            return false
        }
        var attempt = task.attempts[attemptIndex]
        let now = Date()
        mutation(&task, &attempt, now)
        task.attempts[attemptIndex] = attempt
        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        touchGraph(&graph, at: now)
        try validate(graph)
        sessionState.graphs[graph.id] = graph
        try commit(
            sessionID: sessionID,
            state: sessionState,
            eventKind: .updated,
            graphID: graph.id
        )
        return true
    }

    private func finishAttempt(
        sessionID rawSessionID: String,
        taskID: String,
        attemptID: String,
        attemptStatus: TaskAttemptStatus,
        taskStatus: TaskStatus,
        output: String?,
        error: String?,
        statusReason: String?
    ) throws -> Bool {
        let sessionID = try resolvedRootSessionID(rawSessionID)
        let output = output?.nilIfBlank.map(sanitizedPersistedText)
        let error = error?.nilIfBlank.map(sanitizedPersistedText)
        guard var sessionState = sessionStates[sessionID],
              let graphID = sessionState.currentGraphID,
              var graph = sessionState.graphs[graphID],
              let taskIndex = graph.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        var task = graph.tasks[taskIndex]
        guard task.activeAttemptID == attemptID,
              let attemptIndex = task.attempts.firstIndex(where: { $0.id == attemptID }) else {
            return false
        }

        let now = Date()
        task.attempts[attemptIndex].status = attemptStatus
        task.attempts[attemptIndex].finishedAt = now
        task.attempts[attemptIndex].output = output?.nilIfBlank
            ?? task.attempts[attemptIndex].output
        task.attempts[attemptIndex].error = error?.nilIfBlank
        task.activeAttemptID = nil
        task.status = taskStatus
        task.statusReason = statusReason?.nilIfBlank.map(sanitizedPersistedText)

        var result = task.result ?? TaskResult()
        result.output = output?.nilIfBlank ?? result.output
        result.error = error?.nilIfBlank
        result.finishedAt = now
        task.result = result
        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        touchGraph(&graph, at: now)
        updateGraphCompletion(&graph, at: now)
        try validate(graph)
        sessionState.graphs[graph.id] = graph
        try commit(
            sessionID: sessionID,
            state: sessionState,
            eventKind: .updated,
            graphID: graph.id
        )
        return true
    }
}
