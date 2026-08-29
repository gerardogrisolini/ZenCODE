//
//  SessionTaskOrchestrator+Resume.swift
//  ZenCODE
//

import Foundation
import ToolCore

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

/// A reusable plan found in a project-scoped task-graph checkpoint. Unlike a
/// resumable execution graph, loading this value starts from an unapproved plan
/// in the new session rather than taking over the source session's work state.
public struct SavedTaskPlan: Equatable, Sendable, Identifiable {
    public let librarySessionID: String
    public let graph: TaskGraphSnapshot
    public let snapshot: TaskGraphSavedPlan

    public var id: String { "\(librarySessionID)/\(graph.id)" }

    public init(
        librarySessionID: String,
        graph: TaskGraphSnapshot,
        snapshot: TaskGraphSavedPlan
    ) {
        self.librarySessionID = librarySessionID
        self.graph = graph
        self.snapshot = snapshot
    }
}

extension SessionTaskOrchestrator {
    /// Stable logical session used only as the project plan library. Keeping
    /// saved plans outside the live chat session lets `/sessions new` discard
    /// that chat's execution checkpoint without deleting explicit plan saves.
    public nonisolated static func savedPlanLibrarySessionID(
        for workingDirectory: URL
    ) -> String {
        "saved-plans-\(TerminalSessionStore.projectKey(for: workingDirectory))"
    }

    /// Returns the incomplete task graphs persisted for a working directory,
    /// most recently updated first. A graph is resumable when it is not in a
    /// terminal state and still has at least one non-terminal task. During the
    /// scan, legacy ordinary checkpoints are compacted best-effort so terminal
    /// graph history does not remain on disk. This does not require a
    /// registered session.
    public func resumableTaskGraphCheckpoints(
        workingDirectory: URL
    ) -> [ResumableTaskGraph] {
        guard let store else { return [] }
        let checkpoints = store.loadCheckpoints(workingDirectory: workingDirectory)
        var resumable: [ResumableTaskGraph] = []
        for checkpoint in checkpoints {
            // The saved-plan library is durable user data, rather than a
            // recovery checkpoint. Deliberately use the complete namespace:
            // a project-key implementation change must not make older library
            // files eligible for recovery pruning.
            guard !checkpoint.sessionID.hasPrefix("saved-plans-") else {
                continue
            }
            let graphs = resumableGraphs(in: checkpoint)
            pruneLegacyCheckpoint(
                checkpoint,
                keeping: graphs,
                workingDirectory: workingDirectory,
                store: store
            )
            for graph in graphs {
                let pendingCount = graph.tasks.lazy.filter { !$0.status.isTerminal }.count
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

    /// Applies startup recovery retention to an already-loaded ordinary
    /// checkpoint. The loaded value is the CAS precondition, so a concurrent
    /// writer wins over this nonessential cleanup. Startup discovery must not
    /// be interrupted by stale, unreadable, or otherwise failed cleanup.
    func pruneLegacyCheckpoint(
        _ checkpoint: SessionTaskGraphCheckpoint,
        keeping graphs: [TaskGraphSnapshot],
        workingDirectory: URL,
        store: SessionTaskGraphStore
    ) {
        guard graphs != checkpoint.graphs else { return }
        do {
            guard !graphs.isEmpty else {
                _ = try store.compareAndDelete(
                    sessionID: checkpoint.sessionID,
                    replacing: checkpoint,
                    workingDirectory: workingDirectory
                )
                return
            }
            let graphIDs = Set(graphs.map(\.id))
            try store.compareAndSwap(
                SessionTaskGraphCheckpoint(
                    sessionID: checkpoint.sessionID,
                    currentGraphID: checkpoint.currentGraphID.flatMap {
                        graphIDs.contains($0) ? $0 : nil
                    },
                    graphs: graphs,
                    savedAt: Date()
                ),
                replacing: checkpoint,
                workingDirectory: workingDirectory
            )
        } catch {
            ZenLogger.warning(
                .taskLifecycle,
                "Skipping stale task graph checkpoint cleanup for \(checkpoint.sessionID): \(error.localizedDescription)"
            )
        }
    }

    func resumableGraphs(
        in checkpoint: SessionTaskGraphCheckpoint
    ) -> [TaskGraphSnapshot] {
        checkpoint.graphs.filter { graph in
            !graph.state.isTerminal
                && graph.tasks.contains(where: { !$0.status.isTerminal })
        }
    }

    /// Enumerates complete saved-plan payloads for a project, newest explicit
    /// save first. Corrupt or mismatched graph metadata is ignored by the store
    /// decoder/validation path so one bad checkpoint cannot hide other plans.
    public func savedTaskPlans(
        workingDirectory: URL
    ) -> [SavedTaskPlan] {
        guard let store else { return [] }
        let librarySessionID = Self.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        return store.loadCheckpoints(workingDirectory: workingDirectory)
            .filter { $0.sessionID == librarySessionID }
            .flatMap { checkpoint in
                checkpoint.graphs.compactMap { graph -> SavedTaskPlan? in
                    guard (try? validate(graph)) != nil,
                          let snapshot = graph.savedPlan,
                          graph.source.planID == graph.id,
                          snapshot.plan.id == graph.id,
                          snapshot.plan.originalGoal.nilIfBlank != nil,
                          snapshot.plan.consolidatedText.nilIfBlank != nil else {
                        return nil
                    }
                    return SavedTaskPlan(
                        librarySessionID: checkpoint.sessionID,
                        graph: graph,
                        snapshot: snapshot
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.snapshot.savedAt == rhs.snapshot.savedAt {
                    return lhs.id < rhs.id
                }
                return lhs.snapshot.savedAt > rhs.snapshot.savedAt
            }
    }

    /// Removes the requested plans from the project's saved-plan library.
    /// Returns the plan IDs that were found and removed; unknown or duplicate
    /// IDs are ignored so one stale reference cannot fail the cleanup. When no
    /// usable saved plan remains, the library checkpoint itself is discarded so
    /// no empty `saved-plans-*` residue is left behind.
    @discardableResult
    public func deleteSavedTaskPlans(
        planIDs: [String],
        workingDirectory: URL
    ) throws -> [String] {
        let requestedIDs = planIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requestedIDs.isEmpty, let store else {
            return []
        }
        let existingIDs = Set(
            savedTaskPlans(workingDirectory: workingDirectory).map(\.graph.id)
        )
        var deletableIDs: [String] = []
        var seenIDs = Set<String>()
        for id in requestedIDs
        where existingIDs.contains(id) && seenIDs.insert(id).inserted {
            deletableIDs.append(id)
        }
        guard !deletableIDs.isEmpty else {
            return []
        }

        let librarySessionID = Self.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        // Re-read and re-install the freshest on-disk library state before
        // mutating: a long-lived in-memory registration could otherwise
        // overwrite plans saved in the meantime by another orchestrator
        // sharing this support directory (logical lost update).
        guard let checkpoint = try store.load(
            sessionID: librarySessionID,
            workingDirectory: workingDirectory
        ) else {
            return []
        }
        try registerSession(
            id: librarySessionID,
            workingDirectory: workingDirectory,
            restoreIfAvailable: false
        )
        try restoreCheckpoint(
            checkpoint,
            interruptActiveAttempts: true,
            persist: false
        )
        persistedCheckpoints[librarySessionID] = checkpoint
        for planID in deletableIDs {
            _ = try removeGraph(id: planID, sessionID: librarySessionID)
        }
        if savedTaskPlans(workingDirectory: workingDirectory).isEmpty {
            try discardSession(id: librarySessionID, deleteCheckpoint: true)
        }
        return deletableIDs
    }

    /// Best-effort mirror of a completed plan graph onto its saved-plan
    /// library copy: an implemented plan must stop being offered as a
    /// reusable draft. Cancelling or archiving a live graph intentionally
    /// leaves the saved draft reusable, and a missing library checkpoint is
    /// never created here. Failures are swallowed on purpose because a live
    /// task-graph commit must never fail because of the library mirror.
    func mirrorCompletedPlanToSavedPlanLibrary(
        sessionID: String,
        state: SessionState,
        graphID: String?
    ) {
        guard let store,
              let workingDirectory = workingDirectories[sessionID],
              let graphID,
              let graph = state.graphs[graphID],
              graph.source.planID == graphID,
              graph.state == .completed else {
            return
        }
        let librarySessionID = Self.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        guard librarySessionID != sessionID,
              let checkpoint = try? store.load(
                sessionID: librarySessionID,
                workingDirectory: workingDirectory
              ),
              let savedGraph = checkpoint.graphs.first(where: { $0.id == graphID }),
              !savedGraph.state.isTerminal else {
            return
        }
        do {
            try registerSession(
                id: librarySessionID,
                workingDirectory: workingDirectory,
                restoreIfAvailable: false
            )
            // Re-install the freshest on-disk library state before mutating so
            // a long-lived in-memory registration cannot overwrite plans saved
            // in the meantime by another orchestrator sharing this support
            // directory (logical lost update). Only the narrow load→commit
            // window remains, which the store's file locking cannot close.
            try restoreCheckpoint(
                checkpoint,
                interruptActiveAttempts: true,
                persist: false
            )
            persistedCheckpoints[librarySessionID] = checkpoint
            guard var libraryState = sessionStates[librarySessionID],
                  var libraryGraph = libraryState.graphs[graphID],
                  !libraryGraph.state.isTerminal else {
                return
            }
            let now = Date()
            let completedTaskIDs = Set(
                graph.tasks
                    .filter { $0.status == .completed }
                    .map(\.id)
            )
            for index in libraryGraph.tasks.indices
            where completedTaskIDs.contains(libraryGraph.tasks[index].id) {
                guard libraryGraph.tasks[index].status != .completed else {
                    continue
                }
                libraryGraph.tasks[index].status = .completed
                touchTask(&libraryGraph.tasks[index], at: now)
            }
            libraryGraph.state = .completed
            touchGraph(&libraryGraph, at: now)
            if libraryState.currentGraphID == graphID {
                libraryState.currentGraphID = nil
            }
            libraryState.graphs[graphID] = libraryGraph
            try validate(libraryGraph)
            try commit(
                sessionID: librarySessionID,
                state: libraryState,
                eventKind: .updated,
                graphID: graphID
            )
        } catch {
            // Best effort by design: see the doc comment above.
        }
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
