//
//  SessionTaskOrchestrator.swift
//  ZenCODE
//

import Foundation

public enum SessionTaskOrchestratorError: LocalizedError, Equatable {
    case invalidSessionID
    case invalidGraphID(String)
    case graphNotFound(String)
    case graphAlreadyExists(String)
    case graphNotMutable(String)
    case graphNotActive(String)
    case invalidTaskID(String)
    case duplicateTaskID(String)
    case taskNotFound(String)
    case emptyTitle(String)
    case dependencyOnSelf(String)
    case missingDependency(taskID: String, dependencyID: String)
    case dependencyCycle([String])
    case graphTooDeep(Int)
    case taskLimitExceeded(Int)
    case valueTooLong(field: String, limit: Int)
    case invalidTransition(taskID: String, from: TaskStatus, to: TaskStatus)
    case taskNotRunnable(String)
    case taskAlreadyClaimed(String)
    case duplicateClaim(String)
    case staleRevision(expected: Int, actual: Int)
    case retryNotAllowed(String)
    case attemptLimitExceeded(String)
    case permissionDenied(String)
    case invalidSnapshot(String)
    case tasklessDelegationRequiresTaskID(String)
    case tasklessDelegationConflict
    case activeGraphBlockedByTasklessDelegation

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return "A non-empty session id is required for task orchestration."
        case let .invalidGraphID(id):
            return "Invalid task graph id '\(id)'."
        case let .graphNotFound(id):
            return "No task graph matched '\(id)'."
        case let .graphAlreadyExists(id):
            return "Task graph '\(id)' already exists."
        case let .graphNotMutable(id):
            return "Task graph '\(id)' is not mutable in its current state."
        case let .graphNotActive(id):
            return "Task graph '\(id)' is not active."
        case let .invalidTaskID(id):
            return "Invalid task id '\(id)'."
        case let .duplicateTaskID(id):
            return "Task id '\(id)' is duplicated."
        case let .taskNotFound(id):
            return "No task matched '\(id)'."
        case let .emptyTitle(id):
            return "Task '\(id)' requires a non-empty title."
        case let .dependencyOnSelf(id):
            return "Task '\(id)' cannot depend on itself."
        case let .missingDependency(taskID, dependencyID):
            return "Task '\(taskID)' depends on missing task '\(dependencyID)'."
        case let .dependencyCycle(path):
            return "Task dependencies contain a cycle: \(path.joined(separator: " -> "))."
        case let .graphTooDeep(limit):
            return "Task graph exceeds the maximum dependency depth of \(limit)."
        case let .taskLimitExceeded(limit):
            return "Task graph exceeds the maximum of \(limit) tasks."
        case let .valueTooLong(field, limit):
            return "Task field '\(field)' exceeds the maximum length of \(limit)."
        case let .invalidTransition(taskID, from, to):
            return "Task '\(taskID)' cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .taskNotRunnable(id):
            return "Task '\(id)' is not runnable because its graph is inactive or its dependencies are incomplete."
        case let .taskAlreadyClaimed(id):
            return "Task '\(id)' already has an active execution attempt."
        case let .duplicateClaim(id):
            return "Task '\(id)' appears more than once in the claim batch."
        case let .staleRevision(expected, actual):
            return "Task revision is stale (expected \(expected), actual \(actual))."
        case let .retryNotAllowed(id):
            return "Task '\(id)' can only be retried after failure or blocking."
        case let .attemptLimitExceeded(id):
            return "Task '\(id)' reached the retained attempt limit."
        case let .permissionDenied(message):
            return message
        case let .invalidSnapshot(message):
            return "Invalid task graph snapshot: \(message)"
        case let .tasklessDelegationRequiresTaskID(graphID):
            return "Active task graph '\(graphID)' requires every delegated sub-agent to include taskID."
        case .tasklessDelegationConflict:
            return "Coordinated delegation requires a task graph before more than one taskless sub-agent can run."
        case .activeGraphBlockedByTasklessDelegation:
            return "Cannot activate a task graph while a taskless delegated sub-agent is active. Wait for it to finish or close it first."
        }
    }
}

public actor SessionTaskOrchestrator {
    public struct Limits: Equatable, Sendable {
        public var maximumTasksPerGraph: Int
        public var maximumIDLength: Int
        public var maximumDetailsLength: Int
        public var maximumAcceptanceCriterionLength: Int
        public var maximumAttemptOutputLength: Int
        public var maximumAttemptsPerTask: Int
        public var maximumGraphDepth: Int

        public init(
            maximumTasksPerGraph: Int = 256,
            maximumIDLength: Int = 128,
            maximumDetailsLength: Int = 16_384,
            maximumAcceptanceCriterionLength: Int = 2_048,
            maximumAttemptOutputLength: Int = 64 * 1_024,
            maximumAttemptsPerTask: Int = 32,
            maximumGraphDepth: Int = 64
        ) {
            self.maximumTasksPerGraph = maximumTasksPerGraph
            self.maximumIDLength = maximumIDLength
            self.maximumDetailsLength = maximumDetailsLength
            self.maximumAcceptanceCriterionLength = maximumAcceptanceCriterionLength
            self.maximumAttemptOutputLength = maximumAttemptOutputLength
            self.maximumAttemptsPerTask = maximumAttemptsPerTask
            self.maximumGraphDepth = maximumGraphDepth
        }
    }

    struct SessionState: Sendable {
        var currentGraphID: String?
        var graphs: [String: TaskGraphSnapshot]
    }

    public let limits: Limits
    let store: SessionTaskGraphStore?
    var sessionStates: [String: SessionState] = [:]
    var workingDirectories: [String: URL] = [:]
    var restoredSessionIDs = Set<String>()
    var executionScopes: [String: TaskExecutionScope] = [:]
    var tasklessDelegationReservations: [String: Set<UUID>] = [:]
    var eventContinuations: [String: [UUID: AsyncStream<TaskGraphEvent>.Continuation]] = [:]

    public init(
        limits: Limits = Limits(),
        store: SessionTaskGraphStore? = nil
    ) {
        self.limits = limits
        self.store = store
    }

    public func registerSession(
        id rawSessionID: String,
        workingDirectory: URL,
        restoreIfAvailable: Bool = true
    ) throws {
        let sessionID = try normalizedSessionID(rawSessionID)
        let workingDirectory = workingDirectory.standardizedFileURL
        workingDirectories[sessionID] = workingDirectory

        guard restoreIfAvailable,
              !restoredSessionIDs.contains(sessionID) else {
            return
        }
        guard sessionStates[sessionID] == nil,
              let store else {
            restoredSessionIDs.insert(sessionID)
            return
        }

        do {
            if let checkpoint = try store.load(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            ) {
                try restoreCheckpoint(
                    checkpoint,
                    interruptActiveAttempts: true,
                    persist: true
                )
            }
            restoredSessionIDs.insert(sessionID)
        } catch {
            restoredSessionIDs.remove(sessionID)
            throw error
        }
    }

    public func graphSnapshot(
        sessionID rawSessionID: String,
        graphID: String? = nil
    ) throws -> TaskGraphSnapshot? {
        let sessionID = try resolvedRootSessionID(rawSessionID)
        guard let state = sessionStates[sessionID] else {
            return nil
        }
        let resolvedGraphID = graphID?.nilIfBlank ?? state.currentGraphID
        guard let resolvedGraphID else {
            return nil
        }
        return state.graphs[resolvedGraphID]
    }

    public func graphSnapshots(sessionID rawSessionID: String) throws -> [TaskGraphSnapshot] {
        let sessionID = try resolvedRootSessionID(rawSessionID)
        return sessionStates[sessionID]?.graphs.values.sorted(by: Self.graphSortOrder) ?? []
    }

    /// Atomically verifies that a taskless delegation can begin and retains a
    /// lease that prevents a graph from becoming active until that delegation
    /// is finished or closed. The lease closes the gap between checking graph
    /// state and creating or resuming an agent in another actor.
    func reserveTasklessDelegations(
        sessionID rawSessionID: String,
        count: Int,
        retainingReservationIDs: Set<UUID> = [],
        requiresExclusiveAccess: Bool
    ) throws -> [UUID] {
        let sessionID = try requireRootAccess(rawSessionID)
        let existingReservations = tasklessDelegationReservations[sessionID] ?? []
        if let activeGraphID = sessionStates[sessionID]?.graphs.values
            .first(where: { $0.state == .active })?.id {
            throw SessionTaskOrchestratorError.tasklessDelegationRequiresTaskID(activeGraphID)
        }
        guard retainingReservationIDs.isSubset(of: existingReservations) else {
            throw SessionTaskOrchestratorError.tasklessDelegationConflict
        }
        guard count >= 0 else {
            throw SessionTaskOrchestratorError.invalidSnapshot(
                "Taskless delegation reservation count cannot be negative."
            )
        }
        if requiresExclusiveAccess {
            guard existingReservations == retainingReservationIDs,
                  retainingReservationIDs.count + count == 1 else {
                throw SessionTaskOrchestratorError.tasklessDelegationConflict
            }
        }

        let reservationIDs = (0..<count).map { _ in UUID() }
        if !reservationIDs.isEmpty {
            tasklessDelegationReservations[sessionID, default: []]
                .formUnion(reservationIDs)
        }
        return reservationIDs
    }

    func releaseTasklessDelegationReservation(
        sessionID rawSessionID: String,
        reservationID: UUID
    ) throws {
        let sessionID = try requireRootAccess(rawSessionID)
        guard var reservations = tasklessDelegationReservations[sessionID] else {
            return
        }
        reservations.remove(reservationID)
        if reservations.isEmpty {
            tasklessDelegationReservations.removeValue(forKey: sessionID)
        } else {
            tasklessDelegationReservations[sessionID] = reservations
        }
    }

    public func registeredSessionIDs() -> [String] {
        Array(Set(sessionStates.keys).union(workingDirectories.keys)).sorted()
    }

    public func checkpoint(sessionID rawSessionID: String) throws -> SessionTaskGraphCheckpoint? {
        let sessionID = try resolvedRootSessionID(rawSessionID)
        guard let state = sessionStates[sessionID] else {
            return nil
        }
        return checkpoint(sessionID: sessionID, state: state)
    }

    @discardableResult
    public func createGraph(
        sessionID rawSessionID: String,
        id rawGraphID: String,
        source: TaskGraphSource,
        state graphState: TaskGraphState = .draft,
        tasks definitions: [TaskDefinition],
        makeCurrent: Bool = true,
        archivePreviousCurrent: Bool = true
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        if graphState == .active {
            try requireNoTasklessDelegations(sessionID: sessionID)
        }
        let graphID = try normalizedGraphID(rawGraphID)
        var sessionState = sessionStates[sessionID] ?? SessionState(
            currentGraphID: nil,
            graphs: [:]
        )
        guard sessionState.graphs[graphID] == nil else {
            throw SessionTaskOrchestratorError.graphAlreadyExists(graphID)
        }

        let now = Date()
        let records = try makeTaskRecords(definitions, existingTasks: [], now: now)
        var graph = TaskGraphSnapshot(
            id: graphID,
            source: source,
            state: graphState,
            tasks: records,
            createdAt: now,
            updatedAt: now
        )
        try validate(graph)

        if makeCurrent {
            if archivePreviousCurrent,
               let previousID = sessionState.currentGraphID,
               previousID != graphID,
               var previous = sessionState.graphs[previousID],
               previous.state != .archived {
                guard !previous.tasks.contains(where: { $0.activeAttemptID != nil }) else {
                    throw SessionTaskOrchestratorError.graphNotMutable(previousID)
                }
                previous.state = .archived
                touchGraph(&previous, at: now)
                sessionState.graphs[previousID] = previous
            }
            sessionState.currentGraphID = graphID
        }
        updateGraphCompletion(&graph, at: now)
        sessionState.graphs[graphID] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .created, graphID: graphID)
        return graph
    }

    @discardableResult
    public func createTasks(
        sessionID rawSessionID: String,
        graphID rawGraphID: String? = nil,
        source: TaskGraphSource = .manual,
        initialGraphState: TaskGraphState = .active,
        tasks definitions: [TaskDefinition]
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        var sessionState = sessionStates[sessionID] ?? SessionState(
            currentGraphID: nil,
            graphs: [:]
        )
        let now = Date()

        let requestedGraphID = rawGraphID?.nilIfBlank
        let graphID: String
        if let requestedGraphID {
            graphID = try normalizedGraphID(requestedGraphID)
        } else if let currentGraphID = sessionState.currentGraphID,
                  let current = sessionState.graphs[currentGraphID],
                  !current.state.isTerminal {
            graphID = currentGraphID
        } else {
            graphID = "tasks_\(UUID().uuidString.lowercased())"
        }

        if sessionState.graphs[graphID] == nil, initialGraphState == .active {
            try requireNoTasklessDelegations(sessionID: sessionID)
        }

        var graph: TaskGraphSnapshot
        if let existing = sessionState.graphs[graphID] {
            guard existing.state == .draft || existing.state == .active else {
                throw SessionTaskOrchestratorError.graphNotMutable(graphID)
            }
            graph = existing
        } else {
            if let previousID = sessionState.currentGraphID,
               var previous = sessionState.graphs[previousID],
               previous.state != .archived {
                guard !previous.tasks.contains(where: { $0.activeAttemptID != nil }) else {
                    throw SessionTaskOrchestratorError.graphNotMutable(previousID)
                }
                previous.state = .archived
                touchGraph(&previous, at: now)
                sessionState.graphs[previousID] = previous
            }
            graph = TaskGraphSnapshot(
                id: graphID,
                source: source,
                state: initialGraphState,
                tasks: [],
                createdAt: now,
                updatedAt: now
            )
            sessionState.currentGraphID = graphID
        }

        let additions = try makeTaskRecords(
            definitions,
            existingTasks: graph.tasks,
            now: now
        )
        graph.tasks.append(contentsOf: additions)
        touchGraph(&graph, at: now)
        try validate(graph)
        updateGraphCompletion(&graph, at: now)
        sessionState.graphs[graphID] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .updated, graphID: graphID)
        return graph
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
        let callerSessionID = try normalizedSessionID(rawSessionID)
        let scope = executionScopes[callerSessionID]
        let sessionID = scope?.rootSessionID ?? callerSessionID
        guard let graph = try selectedGraph(sessionID: sessionID, graphID: graphID) else {
            return []
        }
        if let scopedGraphID = scope?.graphID,
           graph.id != scopedGraphID {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated sub-agent may only read its assigned task graph."
            )
        }

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
        let callerSessionID = try normalizedSessionID(rawSessionID)
        let scope = executionScopes[callerSessionID]
        let sessionID = scope?.rootSessionID ?? callerSessionID
        guard let graph = try selectedGraph(sessionID: sessionID, graphID: graphID),
              let task = graph.tasks.first(where: { $0.id == taskID }) else {
            throw SessionTaskOrchestratorError.taskNotFound(taskID)
        }
        if let scopedGraphID = scope?.graphID,
           graph.id != scopedGraphID {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated sub-agent may only read its assigned task graph."
            )
        }
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
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated sub-agent may only update its assigned task graph."
            )
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

        let changesMetadata = update.title != nil
            || update.details != nil
            || update.clearsDetails
            || update.priority != nil
            || update.complexity != nil
        if changesMetadata,
           (task.status != .pending || !task.attempts.isEmpty) {
            throw SessionTaskOrchestratorError.graphNotMutable(graph.id)
        }
        if update.dependsOn != nil,
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
            task.complexity = complexity
        }
        if let dependencies = update.dependsOn {
            task.dependsOn = Self.uniqueIdentifiers(dependencies)
        }

        let persistedOutput: String?
        if let output = update.output?.nilIfBlank {
            try validateLength(output, field: "output", limit: limits.maximumAttemptOutputLength)
            persistedOutput = sanitizedPersistedText(output)
        } else {
            persistedOutput = nil
        }
        let persistedError: String?
        if let error = update.error?.nilIfBlank {
            try validateLength(error, field: "error", limit: limits.maximumAttemptOutputLength)
            persistedError = sanitizedPersistedText(error)
        } else {
            persistedError = nil
        }

        if update.status != nil,
           let activeAttempt = task.activeAttempt,
           activeAttempt.executor != .coordinator {
            throw SessionTaskOrchestratorError.permissionDenied(
                "An assigned task is controlled by its active execution attempt."
            )
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
                var result = task.result ?? TaskResult()
                result.finishedAt = now
                if newStatus == .completed, previousStatus == .awaitingValidation {
                    result.validatedAt = now
                }
                task.result = result
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
            var result = task.result ?? TaskResult()
            result.output = output
            task.result = result
        }
        if let error = persistedError {
            var result = task.result ?? TaskResult()
            result.error = error
            task.result = result
        }
        if !update.evidence.isEmpty {
            var result = task.result ?? TaskResult()
            result.evidence.append(contentsOf: update.evidence.map { evidence in
                var sanitized = evidence
                sanitized.summary = sanitizedPersistedText(evidence.summary)
                return sanitized
            })
            task.result = result
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

    @discardableResult
    public func activateGraph(
        id graphID: String,
        sessionID rawSessionID: String
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        try requireNoTasklessDelegations(sessionID: sessionID)
        guard var sessionState = sessionStates[sessionID],
              var graph = sessionState.graphs[graphID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID)
        }
        guard graph.state == .draft || graph.state == .active else {
            throw SessionTaskOrchestratorError.graphNotMutable(graphID)
        }

        let now = Date()
        for otherID in sessionState.graphs.keys where otherID != graphID {
            guard let other = sessionState.graphs[otherID],
                  other.state == .active else { continue }
            guard !other.tasks.contains(where: { $0.activeAttemptID != nil }) else {
                throw SessionTaskOrchestratorError.graphNotMutable(otherID)
            }
        }
        for otherID in sessionState.graphs.keys where otherID != graphID {
            guard var other = sessionState.graphs[otherID],
                  other.state == .active else { continue }
            other.state = .archived
            touchGraph(&other, at: now)
            sessionState.graphs[otherID] = other
        }
        graph.state = .active
        touchGraph(&graph, at: now)
        sessionState.currentGraphID = graphID
        sessionState.graphs[graphID] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .activated, graphID: graphID)
        return graph
    }

    @discardableResult
    public func archiveGraph(
        id graphID: String,
        sessionID rawSessionID: String
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        guard var sessionState = sessionStates[sessionID],
              var graph = sessionState.graphs[graphID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID)
        }
        guard !graph.tasks.contains(where: { $0.activeAttemptID != nil }) else {
            throw SessionTaskOrchestratorError.graphNotMutable(graphID)
        }
        graph.state = .archived
        touchGraph(&graph, at: Date())
        sessionState.graphs[graphID] = graph
        if sessionState.currentGraphID == graphID {
            sessionState.currentGraphID = nil
        }
        try commit(sessionID: sessionID, state: sessionState, eventKind: .archived, graphID: graphID)
        return graph
    }

    public func clearTaskGraphs(sessionID rawSessionID: String) throws {
        let sessionID = try requireRootAccess(rawSessionID)
        let active = sessionStates[sessionID]?.graphs.values.flatMap(\.tasks)
            .contains(where: { $0.activeAttemptID != nil }) ?? false
        guard !active else {
            throw SessionTaskOrchestratorError.permissionDenied(
                "Cannot clear task graphs while execution attempts are active."
            )
        }
        let empty = SessionState(currentGraphID: nil, graphs: [:])
        try commit(sessionID: sessionID, state: empty, eventKind: .cleared, graphID: nil)
    }

    public func discardSession(
        id rawSessionID: String,
        deleteCheckpoint: Bool = true
    ) throws {
        let sessionID = try normalizedSessionID(rawSessionID)
        let workingDirectory = workingDirectories[sessionID]
        if deleteCheckpoint,
           let store,
           let workingDirectory {
            _ = try store.delete(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            )
        }
        sessionStates.removeValue(forKey: sessionID)
        workingDirectories.removeValue(forKey: sessionID)
        restoredSessionIDs.remove(sessionID)
        executionScopes = executionScopes.filter { $0.value.rootSessionID != sessionID }
        tasklessDelegationReservations.removeValue(forKey: sessionID)
        emit(sessionID: sessionID, graphID: nil, revision: nil, kind: .cleared)
    }

    public func flush(sessionID rawSessionID: String? = nil) throws {
        if let rawSessionID {
            let sessionID = try resolvedRootSessionID(rawSessionID)
            guard let state = sessionStates[sessionID] else { return }
            try persist(sessionID: sessionID, state: state)
            return
        }
        for (sessionID, state) in sessionStates {
            try persist(sessionID: sessionID, state: state)
        }
    }

    public func registerExecutionScope(
        executionSessionID: String,
        scope: TaskExecutionScope
    ) throws {
        let executionSessionID = try normalizedSessionID(executionSessionID)
        let rootSessionID = try normalizedSessionID(scope.rootSessionID)
        guard executionSessionID != rootSessionID else {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated execution session must differ from its root session."
            )
        }
        guard let state = sessionStates[rootSessionID],
              let graphID = scope.graphID ?? state.currentGraphID,
              let graph = state.graphs[graphID],
              let task = graph.tasks.first(where: { $0.id == scope.taskID }),
              task.activeAttemptID == scope.attemptID else {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A delegated execution scope must reference an active claimed task attempt."
            )
        }
        executionScopes[executionSessionID] = TaskExecutionScope(
            rootSessionID: rootSessionID,
            graphID: graphID,
            taskID: scope.taskID,
            attemptID: scope.attemptID
        )
    }

    public func unregisterExecutionScope(executionSessionID: String) {
        executionScopes.removeValue(forKey: executionSessionID)
    }

    public func executionScope(for sessionID: String) -> TaskExecutionScope? {
        executionScopes[sessionID]
    }

    public func events(sessionID: String) -> AsyncStream<TaskGraphEvent> {
        let observerID = UUID()
        return AsyncStream { continuation in
            eventContinuations[sessionID, default: [:]][observerID] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeEventContinuation(sessionID: sessionID, id: observerID) }
            }
        }
    }

    func removeEventContinuation(sessionID: String, id: UUID) {
        eventContinuations[sessionID]?.removeValue(forKey: id)
        if eventContinuations[sessionID]?.isEmpty == true {
            eventContinuations.removeValue(forKey: sessionID)
        }
    }
}
