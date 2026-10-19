//
//  SessionTaskOrchestrator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
    case taskRequiresSubAgentExecution(String)

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
        case let .taskRequiresSubAgentExecution(taskID):
            return "Task '\(taskID)' belongs to a workflow graph and must be executed by a delegated sub-agent."
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

        static let empty = SessionState(currentGraphID: nil, graphs: [:])

        /// The current non-terminal workflow graph (if it is not `graphID`),
        /// which no other graph may displace.
        func blockingWorkflowGraphID(otherThan graphID: String) -> String? {
            guard let currentGraphID, currentGraphID != graphID,
                  let current = graphs[currentGraphID],
                  current.source.isWorkflow, !current.state.isTerminal else { return nil }
            return currentGraphID
        }

        /// Archives the current graph before another becomes current; a graph
        /// with a live attempt cannot be superseded.
        mutating func archiveCurrentGraph(except graphID: String, at now: Date) throws {
            guard let previousID = currentGraphID,
                  previousID != graphID,
                  var previous = graphs[previousID],
                  previous.state != .archived else { return }
            guard !previous.hasActiveAttempt else {
                throw SessionTaskOrchestratorError.graphNotMutable(previousID)
            }
            previous.state = .archived
            previous.revision += 1
            previous.updatedAt = now
            graphs[previousID] = previous
        }
    }

    public let limits: Limits
    let store: SessionTaskGraphStore?
    var sessionStates: [String: SessionState] = [:]
    var workingDirectories: [String: URL] = [:]
    var persistedCheckpoints: [String: SessionTaskGraphCheckpoint] = [:]
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
        if let existingWorkingDirectory = workingDirectories[sessionID],
           existingWorkingDirectory != workingDirectory {
            throw SessionTaskOrchestratorError.invalidSnapshot(
                "session \(sessionID) is already registered for \(existingWorkingDirectory.path), not \(workingDirectory.path)"
            )
        }
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
                persistedCheckpoints[sessionID] = checkpoint
                try restoreCheckpoint(
                    checkpoint,
                    interruptActiveAttempts: true,
                    persist: true
                )
            } else {
                // No checkpoint on disk (e.g. a discarded session re-registered in
                // this process): keep the CAS precondition in sync with disk.
                persistedCheckpoints.removeValue(forKey: sessionID)
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

    /// Atomically verifies that a taskless delegation can begin and leases it,
    /// preventing a graph from becoming active until it finishes or closes; this
    /// closes the gap between checking graph state and creating an agent in
    /// another actor.
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
            throw SessionTaskOrchestratorError.invalidSnapshot("Taskless delegation reservation count cannot be negative.")
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
        archivePreviousCurrent: Bool = true,
        originalGoal: String? = nil
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        if graphState == .active {
            try requireNoTasklessDelegations(sessionID: sessionID)
        }
        let graphID = try normalizedGraphID(rawGraphID)
        var sessionState = sessionStates[sessionID] ?? .empty
        guard sessionState.graphs[graphID] == nil else {
            throw SessionTaskOrchestratorError.graphAlreadyExists(graphID)
        }
        if makeCurrent, let blocking = sessionState.blockingWorkflowGraphID(otherThan: graphID) {
            throw SessionTaskOrchestratorError.graphNotMutable(blocking)
        }

        let now = Date()
        let records = try makeTaskRecords(definitions, existingTasks: [], now: now)
        var graph = TaskGraphSnapshot(
            id: graphID,
            source: source,
            state: graphState,
            tasks: records,
            workflow: originalGoal.map { TaskGraphWorkflow(originalGoal: $0) },
            createdAt: now,
            updatedAt: now
        )
        try validate(graph)

        if makeCurrent {
            if archivePreviousCurrent {
                try sessionState.archiveCurrentGraph(except: graphID, at: now)
            }
            sessionState.currentGraphID = graphID
        }
        updateGraphCompletion(&graph, at: now)
        sessionState.graphs[graphID] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .created, graphID: graphID)
        return graph
    }

    /// Atomically materializes an unapproved plan as a non-current draft graph.
    /// Existing copies with the same plan ID are replaced in one checkpoint
    /// commit, so a failure cannot erase the last saved version.
    @discardableResult
    public func savePlanDraft(
        _ savedPlan: TaskGraphSavedPlan,
        sessionID rawSessionID: String,
        tasks definitions: [TaskDefinition]
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        let graphID = try normalizedGraphID(savedPlan.plan.id)
        guard !savedPlan.plan.isApproved else {
            throw SessionTaskOrchestratorError.invalidSnapshot("an approved plan cannot be saved as a draft")
        }

        var sessionState = sessionStates[sessionID] ?? .empty
        let isNewGraph = sessionState.graphs[graphID] == nil
        let now = Date()
        let records = try makeTaskRecords(definitions, existingTasks: [], now: now)
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
        try commit(
            sessionID: sessionID,
            state: sessionState,
            eventKind: isNewGraph ? .created : .updated,
            graphID: graphID
        )
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
        var sessionState = sessionStates[sessionID] ?? .empty
        let now = Date()

        let requestedGraphID = rawGraphID?.nilIfBlank
        if let requestedGraphID,
           let blocking = sessionState.blockingWorkflowGraphID(otherThan: requestedGraphID) {
            throw SessionTaskOrchestratorError.graphNotMutable(blocking)
        }
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
            try sessionState.archiveCurrentGraph(except: graphID, at: now)
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
        if let blocking = sessionState.blockingWorkflowGraphID(otherThan: graphID) {
            throw SessionTaskOrchestratorError.graphNotMutable(blocking)
        }

        let now = Date()
        for otherID in sessionState.graphs.keys where otherID != graphID {
            guard let other = sessionState.graphs[otherID],
                  other.state == .active else { continue }
            guard !other.source.isWorkflow
                || other.state.isTerminal else {
                throw SessionTaskOrchestratorError.graphNotMutable(otherID)
            }
            guard !other.hasActiveAttempt else {
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
        guard !graph.hasActiveAttempt else {
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

    /// Removes a task graph entirely from the session so it can be recreated with
    /// the same id (unlike ``archiveGraph`` which preserves it in an archived state).
    /// Used when a draft plan changes and its task graph must be rebuilt at approval.
    @discardableResult
    public func removeGraph(
        id graphID: String,
        sessionID rawSessionID: String
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        guard var sessionState = sessionStates[sessionID],
              let graph = sessionState.graphs[graphID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID)
        }
        guard !graph.hasActiveAttempt else {
            throw SessionTaskOrchestratorError.graphNotMutable(graphID)
        }
        sessionState.graphs[graphID] = nil
        if sessionState.currentGraphID == graphID {
            sessionState.currentGraphID = nil
        }
        try commit(sessionID: sessionID, state: sessionState, eventKind: .archived, graphID: graphID)
        return graph
    }

    public func clearTaskGraphs(sessionID rawSessionID: String) throws {
        let sessionID = try requireRootAccess(rawSessionID)
        guard !(sessionStates[sessionID]?.graphs.values.contains(where: \.hasActiveAttempt) ?? false) else {
            throw SessionTaskOrchestratorError.permissionDenied("Cannot clear task graphs while execution attempts are active.")
        }
        try commit(sessionID: sessionID, state: .empty, eventKind: .cleared, graphID: nil)
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
        // The CAS precondition must not outlive the session: a stale entry would
        // make the next persist() fail with staleCheckpoint.
        persistedCheckpoints.removeValue(forKey: sessionID)
        restoredSessionIDs.remove(sessionID)
        executionScopes = executionScopes.filter { $0.value.rootSessionID != sessionID }
        tasklessDelegationReservations.removeValue(forKey: sessionID)
        emit(sessionID: sessionID, graphID: nil, revision: nil, kind: .cleared)
        finishEventStreams(sessionID: sessionID)
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

    public func events(sessionID rawSessionID: String) -> AsyncStream<TaskGraphEvent> {
        // A read boundary like graphSnapshot: delegated sessions observe their
        // root graph, and the canonical key lets root discard finish every observer.
        let sessionID = (try? resolvedRootSessionID(rawSessionID))
            ?? rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let observerID = UUID()
        // `makeStream` registers the continuation synchronously within the actor.
        // Observers re-read the snapshot on a debounced render, so keeping only the
        // newest pending event is correct and bounds memory under bursts.
        let (stream, continuation) = AsyncStream<TaskGraphEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        eventContinuations[sessionID, default: [:]][observerID] = continuation
        // `[weak self]`: the actor owns the continuation, so a strong capture
        // would keep it alive until the consumer terminates.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task(name: "SessionTaskOrchestrator.removeEventContinuation") {
                await self.removeEventContinuation(sessionID: sessionID, id: observerID)
            }
        }
        return stream
    }

    /// Terminates every active event subscription so observers stop promptly
    /// (runner shutdown path).
    public func finishEventStreams() {
        let continuations = eventContinuations
        eventContinuations.removeAll()
        for continuationsBySession in continuations.values {
            for continuation in continuationsBySession.values {
                continuation.finish()
            }
        }
    }

    /// Finishes observers of one discarded session only.
    func finishEventStreams(sessionID: String) {
        let continuations = eventContinuations.removeValue(forKey: sessionID) ?? [:]
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    func removeEventContinuation(sessionID: String, id: UUID) {
        eventContinuations[sessionID]?.removeValue(forKey: id)
        if eventContinuations[sessionID]?.isEmpty == true {
            eventContinuations.removeValue(forKey: sessionID)
        }
    }
}

extension TaskGraphSnapshot {
    var hasActiveAttempt: Bool { tasks.contains { $0.activeAttemptID != nil } }
}
