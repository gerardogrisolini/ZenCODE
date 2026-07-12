//
//  SessionTaskOrchestrator+Support.swift
//  ZenCODE
//

import Foundation

extension SessionTaskOrchestrator {
    func normalizedSessionID(_ rawValue: String) throws -> String {
        guard let value = rawValue.nilIfBlank else {
            throw SessionTaskOrchestratorError.invalidSessionID
        }
        return value
    }

    func normalizedGraphID(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= limits.maximumIDLength else {
            throw SessionTaskOrchestratorError.invalidGraphID(rawValue)
        }
        return value
    }

    func resolvedRootSessionID(_ rawValue: String) throws -> String {
        let sessionID = try normalizedSessionID(rawValue)
        return executionScopes[sessionID]?.rootSessionID ?? sessionID
    }

    func requireRootAccess(_ rawValue: String) throws -> String {
        let sessionID = try normalizedSessionID(rawValue)
        guard executionScopes[sessionID] == nil else {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated sub-agent cannot mutate the task graph or control task lifecycle."
            )
        }
        return sessionID
    }

    func selectedGraph(
        sessionID: String,
        graphID: String?
    ) throws -> TaskGraphSnapshot? {
        guard let state = sessionStates[sessionID] else {
            return nil
        }
        let resolvedID = graphID?.nilIfBlank ?? state.currentGraphID
        guard let resolvedID else {
            return nil
        }
        guard let graph = state.graphs[resolvedID] else {
            throw SessionTaskOrchestratorError.graphNotFound(resolvedID)
        }
        return graph
    }

    func mutableTaskLocation(
        sessionID: String,
        graphID: String?,
        taskID: String
    ) throws -> (SessionState, TaskGraphSnapshot, Int) {
        guard let sessionState = sessionStates[sessionID] else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        let resolvedGraphID = graphID?.nilIfBlank ?? sessionState.currentGraphID
        guard let resolvedGraphID,
              let graph = sessionState.graphs[resolvedGraphID],
              let taskIndex = graph.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        return (sessionState, graph, taskIndex)
    }

    func makeTaskRecords(
        _ definitions: [TaskDefinition],
        existingTasks: [TaskRecord],
        now: Date
    ) throws -> [TaskRecord] {
        guard existingTasks.count + definitions.count <= limits.maximumTasksPerGraph else {
            throw SessionTaskOrchestratorError.taskLimitExceeded(limits.maximumTasksPerGraph)
        }

        var usedIDs = Set(existingTasks.map(\.id))
        let nextOrder = (existingTasks.map(\.order).max() ?? 0) + 1
        var records: [TaskRecord] = []
        records.reserveCapacity(definitions.count)

        for (offset, definition) in definitions.enumerated() {
            let id = definition.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "task_\(UUID().uuidString.lowercased())"
            guard !id.isEmpty,
                  id.count <= limits.maximumIDLength else {
                throw SessionTaskOrchestratorError.invalidTaskID(id)
            }
            guard usedIDs.insert(id).inserted else {
                throw SessionTaskOrchestratorError.duplicateTaskID(id)
            }

            let title = definition.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw SessionTaskOrchestratorError.emptyTitle(id)
            }
            if let details = definition.details?.nilIfBlank {
                try validateLength(details, field: "details", limit: limits.maximumDetailsLength)
            }
            for criterion in definition.acceptanceCriteria {
                try validateLength(
                    criterion,
                    field: "acceptanceCriteria",
                    limit: limits.maximumAcceptanceCriterionLength
                )
            }
            let sanitizedOutput: String?
            if let output = definition.output?.nilIfBlank {
                try validateLength(
                    output,
                    field: "output",
                    limit: limits.maximumAttemptOutputLength
                )
                sanitizedOutput = sanitizedPersistedText(output)
            } else {
                sanitizedOutput = nil
            }

            let result = sanitizedOutput.map {
                TaskResult(output: $0, finishedAt: definition.status == .completed ? now : nil)
            }
            records.append(
                TaskRecord(
                    id: id,
                    title: title,
                    details: definition.details,
                    order: definition.order ?? (nextOrder + offset),
                    status: definition.status,
                    priority: definition.priority,
                    dependsOn: Self.uniqueIdentifiers(definition.dependsOn),
                    execution: definition.execution,
                    acceptanceCriteria: definition.acceptanceCriteria,
                    result: result,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        return records
    }

    func validate(_ graph: TaskGraphSnapshot) throws {
        guard graph.schemaVersion == TaskGraphSnapshot.currentSchemaVersion else {
            throw SessionTaskOrchestratorError.invalidSnapshot(
                "unsupported graph schema version \(graph.schemaVersion)"
            )
        }
        _ = try normalizedGraphID(graph.id)
        guard graph.tasks.count <= limits.maximumTasksPerGraph else {
            throw SessionTaskOrchestratorError.taskLimitExceeded(limits.maximumTasksPerGraph)
        }

        var tasksByID: [String: TaskRecord] = [:]
        for task in graph.tasks {
            guard !task.id.isEmpty,
                  task.id.count <= limits.maximumIDLength else {
                throw SessionTaskOrchestratorError.invalidTaskID(task.id)
            }
            guard tasksByID.updateValue(task, forKey: task.id) == nil else {
                throw SessionTaskOrchestratorError.duplicateTaskID(task.id)
            }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionTaskOrchestratorError.emptyTitle(task.id)
            }
            if let details = task.details {
                try validateLength(details, field: "details", limit: limits.maximumDetailsLength)
            }
            if task.attempts.count > limits.maximumAttemptsPerTask {
                throw SessionTaskOrchestratorError.attemptLimitExceeded(task.id)
            }
            if let activeAttemptID = task.activeAttemptID {
                guard let attempt = task.attempts.first(where: { $0.id == activeAttemptID }),
                      attempt.status.isActive else {
                    throw SessionTaskOrchestratorError.invalidSnapshot(
                        "task \(task.id) references a non-active attempt"
                    )
                }
            }
        }

        for task in graph.tasks {
            for dependencyID in task.dependsOn {
                if dependencyID == task.id {
                    throw SessionTaskOrchestratorError.dependencyOnSelf(task.id)
                }
                guard tasksByID[dependencyID] != nil else {
                    throw SessionTaskOrchestratorError.missingDependency(
                        taskID: task.id,
                        dependencyID: dependencyID
                    )
                }
            }
        }

        try validateAcyclicDependencies(tasksByID)
    }

    func validateAcyclicDependencies(_ tasksByID: [String: TaskRecord]) throws {
        enum Mark {
            case visiting
            case visited
        }
        var marks: [String: Mark] = [:]
        var path: [String] = []

        func visit(_ id: String, depth: Int) throws {
            if depth > limits.maximumGraphDepth {
                throw SessionTaskOrchestratorError.graphTooDeep(limits.maximumGraphDepth)
            }
            if marks[id] == .visited { return }
            if marks[id] == .visiting {
                let cycleStart = path.firstIndex(of: id) ?? 0
                throw SessionTaskOrchestratorError.dependencyCycle(
                    Array(path[cycleStart...]) + [id]
                )
            }

            marks[id] = .visiting
            path.append(id)
            for dependencyID in tasksByID[id]?.dependsOn ?? [] {
                try visit(dependencyID, depth: depth + 1)
            }
            _ = path.popLast()
            marks[id] = .visited
        }

        for id in tasksByID.keys.sorted() {
            try visit(id, depth: 1)
        }
    }

    func sanitizedPersistedText(_ value: String) -> String {
        var output = value
        let replacements: [(String, String)] = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [REDACTED]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|authorization)\b\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
        ]
        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return output
    }

    func validateLength(_ value: String, field: String, limit: Int) throws {
        guard value.count <= limit else {
            throw SessionTaskOrchestratorError.valueTooLong(field: field, limit: limit)
        }
    }

    func isRunnable(_ task: TaskRecord, in graph: TaskGraphSnapshot) -> Bool {
        guard graph.state == .active,
              task.status == .pending,
              task.activeAttemptID == nil else {
            return false
        }
        let statuses = Dictionary(uniqueKeysWithValues: graph.tasks.map { ($0.id, $0.status) })
        return task.dependsOn.allSatisfy { statuses[$0] == .completed }
    }

    func view(for task: TaskRecord, in graph: TaskGraphSnapshot) -> TaskRecordView {
        let tasksByID = Dictionary(uniqueKeysWithValues: graph.tasks.map { ($0.id, $0) })
        let blockedBy = task.dependsOn.filter { tasksByID[$0]?.status != .completed }
        let blockedReason: String?
        if let statusReason = task.statusReason?.nilIfBlank {
            blockedReason = statusReason
        } else if graph.state != .active {
            blockedReason = "graph is \(graph.state.rawValue)"
        } else if let failedDependency = blockedBy.first(where: {
            tasksByID[$0]?.status.preventsDependentExecution == true
        }), let status = tasksByID[failedDependency]?.status {
            blockedReason = "dependency \(failedDependency) \(status.rawValue)"
        } else if !blockedBy.isEmpty {
            blockedReason = "waiting for dependencies: \(blockedBy.joined(separator: ", "))"
        } else if task.status != .pending {
            blockedReason = "task status is \(task.status.rawValue)"
        } else {
            blockedReason = nil
        }
        let dependents = graph.tasks
            .filter { $0.dependsOn.contains(task.id) }
            .sorted(by: Self.taskSortOrder)
            .map(\.id)
        return TaskRecordView(
            graphID: graph.id,
            graphRevision: graph.revision,
            graphState: graph.state,
            task: task,
            isRunnable: isRunnable(task, in: graph),
            blockedBy: blockedBy,
            blockedReason: blockedReason,
            dependents: dependents
        )
    }

    static func isTransitionAllowed(from: TaskStatus, to: TaskStatus) -> Bool {
        switch (from, to) {
        case (.pending, .inProgress),
             (.pending, .blocked),
             (.pending, .cancelled),
             (.inProgress, .awaitingValidation),
             (.inProgress, .completed),
             (.inProgress, .failed),
             (.inProgress, .blocked),
             (.inProgress, .cancelled),
             (.awaitingValidation, .completed),
             (.awaitingValidation, .failed),
             (.awaitingValidation, .blocked),
             (.awaitingValidation, .cancelled):
            true
        default:
            false
        }
    }

    static func uniqueIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { rawValue in
            guard let value = rawValue.nilIfBlank,
                  seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    static func taskSortOrder(_ lhs: TaskRecord, _ rhs: TaskRecord) -> Bool {
        if lhs.priority.sortRank != rhs.priority.sortRank {
            return lhs.priority.sortRank > rhs.priority.sortRank
        }
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    static func graphSortOrder(_ lhs: TaskGraphSnapshot, _ rhs: TaskGraphSnapshot) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    func touchTask(_ task: inout TaskRecord, at date: Date) {
        task.revision += 1
        task.updatedAt = date
    }

    func touchGraph(_ graph: inout TaskGraphSnapshot, at date: Date) {
        graph.revision += 1
        graph.updatedAt = date
    }

    func updateGraphCompletion(_ graph: inout TaskGraphSnapshot, at date: Date) {
        let allCompleted = !graph.tasks.isEmpty
            && graph.tasks.allSatisfy { $0.status == .completed }
        if allCompleted, graph.state == .active {
            graph.state = .completed
            graph.updatedAt = date
        } else if !allCompleted, graph.state == .completed {
            graph.state = .active
            graph.updatedAt = date
        }
    }

    func checkpoint(
        sessionID: String,
        state: SessionState
    ) -> SessionTaskGraphCheckpoint {
        SessionTaskGraphCheckpoint(
            sessionID: sessionID,
            currentGraphID: state.currentGraphID,
            graphs: state.graphs.values.sorted(by: Self.graphSortOrder),
            savedAt: Date()
        )
    }

    func persist(sessionID: String, state: SessionState) throws {
        guard let store,
              let workingDirectory = workingDirectories[sessionID] else {
            return
        }
        try store.save(
            checkpoint(sessionID: sessionID, state: state),
            workingDirectory: workingDirectory
        )
    }

    func commit(
        sessionID: String,
        state: SessionState,
        eventKind: TaskGraphEvent.Kind,
        graphID: String?
    ) throws {
        try persist(sessionID: sessionID, state: state)
        sessionStates[sessionID] = state
        let revision = graphID.flatMap { state.graphs[$0]?.revision }
        emit(
            sessionID: sessionID,
            graphID: graphID,
            revision: revision,
            kind: eventKind
        )
    }

    func emit(
        sessionID: String,
        graphID: String?,
        revision: Int?,
        kind: TaskGraphEvent.Kind
    ) {
        let event = TaskGraphEvent(
            sessionID: sessionID,
            graphID: graphID,
            revision: revision,
            kind: kind,
            emittedAt: Date()
        )
        for continuation in eventContinuations[sessionID]?.values ?? [:].values {
            continuation.yield(event)
        }
    }
}
