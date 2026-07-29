//
//  SessionTaskOrchestrator+Resume.swift
//  ZenCODE
//

import Foundation

/// A lightweight summary of an incomplete task graph persisted by a previous
/// session, suitable for offering the user a choice at startup.
public struct ResumableTaskGraph: Equatable, Sendable, Identifiable {
    /// The session whose checkpoint owns the incomplete graph. Resuming
    /// reuses this identifier so the existing `restoreIfAvailable` path loads
    /// the graph naturally.
    public let sessionID: String
    /// The incomplete graph that can be resumed.
    public let graphID: String
    public let state: TaskGraphState
    public let source: TaskGraphSource
    public let totalTaskCount: Int
    public let pendingTaskCount: Int
    public let updatedAt: Date

    public var id: String { "\(sessionID)/\(graphID)" }

    public init(
        sessionID: String,
        graphID: String,
        state: TaskGraphState,
        source: TaskGraphSource,
        totalTaskCount: Int,
        pendingTaskCount: Int,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.graphID = graphID
        self.state = state
        self.source = source
        self.totalTaskCount = totalTaskCount
        self.pendingTaskCount = pendingTaskCount
        self.updatedAt = updatedAt
    }
}

extension SessionTaskOrchestrator {
    /// Returns the incomplete task graphs persisted for a working directory,
    /// most recently updated first. A graph is resumable when it is not in a
    /// terminal state and still has at least one non-terminal task. This is a
    /// read-only disk scan and does not require a registered session.
    public func resumableTaskGraphCheckpoints(
        workingDirectory: URL
    ) -> [ResumableTaskGraph] {
        guard let store else { return [] }
        let checkpoints = store.loadCheckpoints(workingDirectory: workingDirectory)
        var resumable: [ResumableTaskGraph] = []
        for checkpoint in checkpoints {
            for graph in checkpoint.graphs where !graph.state.isTerminal {
                let pendingCount = graph.tasks.lazy.filter { !$0.status.isTerminal }.count
                guard pendingCount > 0 else { continue }
                resumable.append(
                    ResumableTaskGraph(
                        sessionID: checkpoint.sessionID,
                        graphID: graph.id,
                        state: graph.state,
                        source: graph.source,
                        totalTaskCount: graph.tasks.count,
                        pendingTaskCount: pendingCount,
                        updatedAt: graph.updatedAt
                    )
                )
            }
        }
        return resumable.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Restores the selected checkpoint session and makes the exact graph the
    /// user chose current. This explicit startup recovery may supersede another
    /// incomplete graph from the same old session; any other active graph is
    /// archived only after restore has interrupted its in-flight attempts.
    @discardableResult
    public func resumeTaskGraph(
        _ selectedGraph: ResumableTaskGraph,
        workingDirectory: URL
    ) throws -> TaskGraphSnapshot {
        try registerSession(
            id: selectedGraph.sessionID,
            workingDirectory: workingDirectory,
            restoreIfAvailable: true
        )
        guard var sessionState = sessionStates[selectedGraph.sessionID],
              var graph = sessionState.graphs[selectedGraph.graphID] else {
            throw SessionTaskOrchestratorError.graphNotFound(selectedGraph.graphID)
        }
        guard graph.state == .draft || graph.state == .active else {
            throw SessionTaskOrchestratorError.graphNotMutable(selectedGraph.graphID)
        }
        if sessionState.currentGraphID == graph.id, graph.state == .active {
            return graph
        }
        try requireNoTasklessDelegations(sessionID: selectedGraph.sessionID)

        let now = Date()
        for otherID in sessionState.graphs.keys where otherID != graph.id {
            guard var other = sessionState.graphs[otherID],
                  other.state == .active else { continue }
            guard !other.tasks.contains(where: { $0.activeAttemptID != nil }) else {
                throw SessionTaskOrchestratorError.graphNotMutable(otherID)
            }
            other.state = .archived
            touchGraph(&other, at: now)
            sessionState.graphs[otherID] = other
        }
        graph.state = .active
        touchGraph(&graph, at: now)
        sessionState.currentGraphID = graph.id
        sessionState.graphs[graph.id] = graph
        try commit(
            sessionID: selectedGraph.sessionID,
            state: sessionState,
            eventKind: .restored,
            graphID: graph.id
        )
        return graph
    }

    /// Removes selected incomplete graphs from their persisted sessions while
    /// preserving every graph that was not selected. Sessions are restored
    /// through the orchestrator before mutation so task-graph ownership and
    /// checkpoint persistence remain centralized here.
    public func removeResumableTaskGraphs(
        _ graphs: [ResumableTaskGraph],
        workingDirectory: URL
    ) throws {
        let graphsBySession = Dictionary(grouping: graphs, by: \.sessionID)
        for (sessionID, selectedGraphs) in graphsBySession {
            try registerSession(
                id: sessionID,
                workingDirectory: workingDirectory,
                restoreIfAvailable: true
            )
            for graph in selectedGraphs {
                _ = try removeGraph(id: graph.graphID, sessionID: sessionID)
            }
        }
    }
}
