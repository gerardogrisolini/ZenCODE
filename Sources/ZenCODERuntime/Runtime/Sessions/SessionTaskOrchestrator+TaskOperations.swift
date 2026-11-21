//
//  SessionTaskOrchestrator+TaskOperations.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension SessionTaskOrchestrator {
    /// A delegated caller reads through its root session; returns that scope.
    private func readScope(_ rawSessionID: String) throws -> (scope: TaskExecutionScope?, sessionID: String) {
        let callerSessionID = try normalizedSessionID(rawSessionID)
        let scope = executionScopes[callerSessionID]
        return (scope, scope?.rootSessionID ?? callerSessionID)
    }

    private func requireReadableGraph(_ graph: TaskGraphSnapshot, scope: TaskExecutionScope?) throws {
        if let scopedGraphID = scope?.graphID, graph.id != scopedGraphID {
            throw SessionTaskOrchestratorError.permissionDenied("A delegated sub-agent may only read its assigned task graph.")
        }
    }

    public func listTasks(
        sessionID rawSessionID: String,
        graphID: String? = nil,
        status: TaskStatus? = nil,
        assigneeAgentID: String? = nil,
        runnableOnly: Bool = false,
        includeTerminal: Bool = true,
        limit: Int = 256
    ) throws -> [TaskRecordView] {
        let (scope, sessionID) = try readScope(rawSessionID)
        guard let graph = try selectedGraph(sessionID: sessionID, graphID: graphID) else {
            return []
        }
        try requireReadableGraph(graph, scope: scope)

        let visibleTaskIDs: Set<String>?
        if let scope {
            guard let ownTask = graph.tasks.first(where: { $0.id == scope.taskID }) else {
                return []
            }
            visibleTaskIDs = Set([scope.taskID] + ownTask.dependsOn)
        } else {
            visibleTaskIDs = nil
        }

        return graph.tasks
            .filter { task in
                if let visibleTaskIDs, !visibleTaskIDs.contains(task.id) { return false }
                if let status, task.status != status { return false }
                if let assigneeAgentID, task.assigneeAgentID != assigneeAgentID { return false }
                if !includeTerminal, task.status.isTerminal { return false }
                if runnableOnly, !isRunnable(task, in: graph) { return false }
                return true
            }
            .sorted(by: Self.taskSortOrder)
            .prefix(max(0, min(limit, limits.maximumTasksPerGraph)))
            .map { view(for: $0, in: graph) }
    }

    public func task(
        sessionID rawSessionID: String,
        taskID: String,
        graphID: String? = nil
    ) throws -> TaskRecordView {
        let (scope, sessionID) = try readScope(rawSessionID)
        guard let graph = try selectedGraph(sessionID: sessionID, graphID: graphID),
              let task = graph.tasks.first(where: { $0.id == taskID }) else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        try requireReadableGraph(graph, scope: scope)
        if let scope,
           task.id != scope.taskID,
           !(graph.tasks.first(where: { $0.id == scope.taskID })?.dependsOn.contains(task.id) ?? false) {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated sub-agent may only read its assigned task and direct dependencies."
            )
        }
        return view(for: task, in: graph)
    }

    @discardableResult
    public func updateTask(
        sessionID rawSessionID: String,
        taskID: String,
        graphID: String? = nil,
        update: TaskUpdate
    ) throws -> TaskRecordView {
        let callerSessionID = try normalizedSessionID(rawSessionID)
        let scope = executionScopes[callerSessionID]
        let sessionID = scope?.rootSessionID ?? callerSessionID
        if let scopedGraphID = scope?.graphID,
           let requestedGraphID = graphID?.nilIfBlank,
           requestedGraphID != scopedGraphID {
            throw SessionTaskOrchestratorError.permissionDenied("A delegated sub-agent may only update its assigned task graph.")
        }
        let effectiveGraphID = scope?.graphID ?? graphID
        var (sessionState, graph, taskIndex) = try mutableTaskLocation(
            sessionID: sessionID,
            graphID: effectiveGraphID,
            taskID: taskID
        )
        var task = graph.tasks[taskIndex]

        if let scope {
            guard scope.taskID == taskID,
                  scope.attemptID == task.activeAttemptID else {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "A delegated sub-agent may only update its active assigned task attempt."
                )
            }
            guard update.title == nil,
                  update.details == nil,
                  !update.clearsDetails,
                  update.priority == nil,
                  update.dependsOn == nil,
                  update.status == nil,
                  update.error == nil,
                  update.evidence.isEmpty,
                  update.complexity == nil else {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "A delegated sub-agent may only append progress output to its own attempt."
                )
            }
        }

        if let expectedRevision = update.expectedRevision,
           expectedRevision != task.revision {
            throw SessionTaskOrchestratorError.staleRevision(
                expected: expectedRevision,
                actual: task.revision
            )
        }

        let changesDefinition = update.title != nil
            || update.details != nil
            || update.clearsDetails
            || update.priority != nil
            || update.complexity != nil
            || update.dependsOn != nil
        if changesDefinition,
           (task.status != .pending || !task.attempts.isEmpty) {
            throw SessionTaskOrchestratorError.graphNotMutable(graph.id)
        }

        if let title = update.title {
            task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if update.clearsDetails {
            task.details = nil
        } else if let details = update.details {
            task.details = details.nilIfBlank
        }
        if let priority = update.priority {
            task.priority = priority
        }
        if let complexity = update.complexity {
            task.complexity = TaskRecord.clampedComplexity(complexity)
        }
        if let dependencies = update.dependsOn {
            task.dependsOn = Self.uniqueIdentifiers(dependencies)
        }

        func persisted(_ raw: String?, field: String) throws -> String? {
            guard let value = raw?.nilIfBlank else { return nil }
            try validateLength(value, field: field, limit: limits.maximumAttemptOutputLength)
            return sanitizedPersistedText(value)
        }
        func amendResult(_ change: (inout TaskResult) -> Void) {
            var result = task.result ?? TaskResult()
            change(&result)
            task.result = result
        }
        let persistedOutput = try persisted(update.output, field: "output")
        let persistedError = try persisted(update.error, field: "error")

        if update.status != nil,
           let activeAttempt = task.activeAttempt,
           activeAttempt.executor != .coordinator {
            throw SessionTaskOrchestratorError.permissionDenied("An assigned task is controlled by its active execution attempt.")
        }

        let now = Date()
        if let newStatus = update.status,
           newStatus != task.status {
            let previousStatus = task.status
            guard Self.isTransitionAllowed(from: previousStatus, to: newStatus) else {
                throw SessionTaskOrchestratorError.invalidTransition(
                    taskID: task.id,
                    from: previousStatus,
                    to: newStatus
                )
            }
            if previousStatus == .pending,
               newStatus == .inProgress {
                guard isRunnable(task, in: graph) else {
                    throw SessionTaskOrchestratorError.taskNotRunnable(task.id)
                }
                guard task.attempts.count < limits.maximumAttemptsPerTask else {
                    throw SessionTaskOrchestratorError.attemptLimitExceeded(task.id)
                }
                let attemptID = "attempt_\(UUID().uuidString.lowercased())"
                task.attempts.append(
                    TaskAttempt(
                        id: attemptID,
                        ordinal: task.attempts.count + 1,
                        agentID: nil,
                        executor: .coordinator,
                        status: .running,
                        startedAt: now,
                        output: persistedOutput
                    )
                )
                task.activeAttemptID = attemptID
            } else if previousStatus == .inProgress,
                      let activeAttemptID = task.activeAttemptID,
                      let attemptIndex = task.attempts.firstIndex(where: {
                          $0.id == activeAttemptID && $0.executor == .coordinator
                      }) {
                let attemptStatus: TaskAttemptStatus
                switch newStatus {
                case .completed, .awaitingValidation: attemptStatus = .completed
                case .failed: attemptStatus = .failed
                case .blocked: attemptStatus = .interrupted
                case .cancelled: attemptStatus = .cancelled
                case .pending, .inProgress: attemptStatus = task.attempts[attemptIndex].status
                }
                task.attempts[attemptIndex].status = attemptStatus
                task.attempts[attemptIndex].finishedAt = now
                task.attempts[attemptIndex].output = persistedOutput
                    ?? task.attempts[attemptIndex].output
                task.attempts[attemptIndex].error = persistedError
                    ?? update.statusReason?.nilIfBlank.map(sanitizedPersistedText)
                task.activeAttemptID = nil
            }
            task.status = newStatus
            if newStatus == .completed || newStatus == .awaitingValidation
                || newStatus == .failed || newStatus == .blocked || newStatus == .cancelled {
                amendResult {
                    $0.finishedAt = now
                    if newStatus == .completed, previousStatus == .awaitingValidation {
                        $0.validatedAt = now
                    }
                }
            }
            if newStatus == .inProgress || newStatus == .awaitingValidation
                || newStatus == .completed {
                task.statusReason = nil
            }
        }

        if update.statusReason != nil {
            task.statusReason = update.statusReason?.nilIfBlank.map(sanitizedPersistedText)
        }
        if let output = persistedOutput {
            if let activeAttemptID = task.activeAttemptID,
               let attemptIndex = task.attempts.firstIndex(where: { $0.id == activeAttemptID }) {
                task.attempts[attemptIndex].output = output
            }
            amendResult { $0.output = output }
        }
        if let error = persistedError {
            amendResult { $0.error = error }
        }
        if !update.evidence.isEmpty {
            amendResult {
                $0.evidence.append(contentsOf: update.evidence.map { evidence in
                    var sanitized = evidence
                    sanitized.summary = sanitizedPersistedText(evidence.summary)
                    return sanitized
                })
            }
        }

        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        try validate(graph)
        touchGraph(&graph, at: now)
        updateGraphCompletion(&graph, at: now)
        sessionState.graphs[graph.id] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .updated, graphID: graph.id)
        return view(for: task, in: graph)
    }

    @discardableResult
    public func retryTask(
        sessionID rawSessionID: String,
        taskID: String,
        graphID: String? = nil,
        expectedRevision: Int? = nil
    ) throws -> TaskRecordView {
        let sessionID = try requireRootAccess(rawSessionID)
        var (sessionState, graph, taskIndex) = try mutableTaskLocation(
            sessionID: sessionID,
            graphID: graphID,
            taskID: taskID
        )
        var task = graph.tasks[taskIndex]
        if let expectedRevision, expectedRevision != task.revision {
            throw SessionTaskOrchestratorError.staleRevision(
                expected: expectedRevision,
                actual: task.revision
            )
        }
        guard task.status == .failed || task.status == .blocked else {
            throw SessionTaskOrchestratorError.retryNotAllowed(taskID)
        }

        if graph.state == .completed {
            try requireNoTasklessDelegations(sessionID: sessionID)
        }

        let now = Date()
        task.status = .pending
        task.statusReason = nil
        task.activeAttemptID = nil
        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        if graph.state == .completed {
            graph.state = .active
        }
        touchGraph(&graph, at: now)
        sessionState.graphs[graph.id] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .updated, graphID: graph.id)
        return view(for: task, in: graph)
    }

    @discardableResult
    public func cancelTask(
        sessionID rawSessionID: String,
        taskID: String,
        graphID: String? = nil,
        reason: String? = nil
    ) throws -> TaskCancellation {
        let sessionID = try requireRootAccess(rawSessionID)
        var (sessionState, graph, taskIndex) = try mutableTaskLocation(
            sessionID: sessionID,
            graphID: graphID,
            taskID: taskID
        )
        var task = graph.tasks[taskIndex]
        let reason = reason?.nilIfBlank.map(sanitizedPersistedText)
        guard task.status != .completed,
              task.status != .cancelled else {
            throw SessionTaskOrchestratorError.invalidTransition(
                taskID: taskID,
                from: task.status,
                to: .cancelled
            )
        }

        let activeAttempt = task.activeAttempt
        let now = Date()
        if let activeAttemptID = task.activeAttemptID,
           let index = task.attempts.firstIndex(where: { $0.id == activeAttemptID }) {
            task.attempts[index].status = .cancelled
            task.attempts[index].finishedAt = now
            task.attempts[index].error = reason?.nilIfBlank ?? "Cancelled."
        }
        task.activeAttemptID = nil
        task.status = .cancelled
        task.statusReason = reason?.nilIfBlank
        touchTask(&task, at: now)
        graph.tasks[taskIndex] = task
        touchGraph(&graph, at: now)
        sessionState.graphs[graph.id] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .updated, graphID: graph.id)
        return TaskCancellation(
            graphID: graph.id,
            taskID: task.id,
            attemptID: activeAttempt?.id,
            agentID: activeAttempt?.agentID
        )
    }
}
