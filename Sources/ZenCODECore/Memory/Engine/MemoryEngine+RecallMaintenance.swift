//
//  MemoryEngine+RecallMaintenance.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension MemoryEngine {
    /// Re-validated candidate lists, so the caller builds its result from the
    /// same filtered set maintenance operated on.
    struct RevalidatedRecall: Sendable {
        let candidates: [MemoryCandidate]
        let selected: [MemoryCandidate]
    }

    /// Filters candidates against the *current* graph, synchronously inside the
    /// maintenance transaction: a `forget`/archive that landed during the selector
    /// `await` makes a candidate stale, so IDs that are gone, inactive or out of
    /// scope are dropped and surviving payloads refreshed.
    static func revalidate(
        candidates: [MemoryCandidate],
        selected: [MemoryCandidate],
        against graph: MemoryGraph,
        scope: EngineMemoryScope
    ) -> RevalidatedRecall {
        func refreshed(_ candidate: MemoryCandidate) -> MemoryCandidate? {
            guard let memory = graph.memories[candidate.memory.id],
                  memory.active,
                  MemorySearch.scopeAllows(memory.scope, requested: scope) else {
                return nil
            }
            // Keep the score from the original query but return the current
            // persisted entry so cross-process updates are visible.
            return MemoryCandidate(memory: memory, score: candidate.score)
        }
        return RevalidatedRecall(
            candidates: candidates.compactMap(refreshed),
            selected: selected.compactMap(refreshed)
        )
    }

    static func maintainAfterRetrieval(
        _ graph: inout MemoryGraph,
        all: [MemoryCandidate],
        selected: [MemoryCandidate],
        configuration: MemoryEngineConfiguration
    ) {
        // Kept here rather than in `cascadeRetrieve`, which now runs on a copy:
        // this is the single place where a retrieval reaches the live graph.
        graph.metadata.retrievalCount &+= 1
        let selectedIDs = Set(selected.map(\.memory.id))
        for candidate in all {
            guard var memory = graph.memories[candidate.memory.id] else { continue }
            if selectedIDs.contains(memory.id) {
                memory.boostConfidence(by: configuration.boostSelectedBy)
            } else if configuration.decayRejectedBy > 0 {
                memory.decayConfidence(by: configuration.decayRejectedBy)
            } else {
                // Rejected candidates are left untouched by default.
                continue
            }
            graph.memories[memory.id] = memory
        }

        // Every co-selected pair is born, reinforced or capped by the policy
        // (see `MemoryGraph.reinforceRelation`). The batch replay calls this
        // same method with the policy of the recorded configuration.
        guard configuration.strengthenCoRelevantLinks, selected.count >= 2 else { return }
        for i in 0..<(selected.count - 1) {
            for j in (i + 1)..<selected.count {
                graph.reinforceRelation(
                    between: selected[i].memory.id,
                    and: selected[j].memory.id,
                    policy: configuration.relationPolicy
                )
            }
        }
    }

    struct PendingRecallMaintenance: Sendable {
        let candidateIDs: [String]
        /// In the selector's order: with a capped relation policy the order in
        /// which pairs are linked decides which link is evicted, so the replay
        /// must visit them exactly as the direct path did.
        let selectedIDs: [String]
        let scope: EngineMemoryScope
        let configuration: MemoryEngineConfiguration
    }

    /// The maintenance a recall *would* record, computed without mutating the
    /// engine, so the batch, its cold-start seed and the fallback graph are all
    /// decided before the first cancellable await and adopted in one step only
    /// after the durable transaction returned.
    struct MaintenanceProposal: Sendable {
        /// Already recorded intents plus the new one.
        let pending: [PendingRecallMaintenance]
        /// Graph as it was before the *first* pending intent, or `nil` when no
        /// batch is open yet.
        let baseGraph: MemoryGraph?
        /// Seed for a transactional store whose file does not exist yet.
        let initialGraph: MemoryGraph
    }

    func proposedMaintenance(
        adding intent: PendingRecallMaintenance
    ) -> MaintenanceProposal {
        // `graph` is untouched by this recall, so it is the pre-maintenance seed
        // a cold transactional checkpoint needs to replay the batch exactly once.
        let baseGraph = pendingRecallMaintenance.isEmpty ? graph : pendingRecallBaseGraph
        return MaintenanceProposal(
            pending: pendingRecallMaintenance + [intent],
            baseGraph: baseGraph,
            initialGraph: baseGraph ?? graph
        )
    }

    func recallProposal(
        _ valid: RevalidatedRecall,
        scope: EngineMemoryScope,
        settings: MemoryEngineConfiguration
    ) -> (draft: MemoryGraph, proposal: MaintenanceProposal) {
        var draft = graph
        Self.maintainAfterRetrieval(
            &draft,
            all: valid.candidates,
            selected: valid.selected,
            configuration: settings
        )
        let proposal = proposedMaintenance(
            adding: PendingRecallMaintenance(
                candidateIDs: valid.candidates.map(\.memory.id),
                selectedIDs: valid.selected.map(\.memory.id),
                scope: scope,
                configuration: settings
            )
        )
        return (draft, proposal)
    }

    /// Decides what a failed maintenance checkpoint leaves behind; the two modes
    /// must not be collapsed:
    ///
    /// - **Cancelled.** The caller receives no result, so the recall must leave
    ///   no trace: nothing is adopted.
    /// - **Store unavailable.** The retrieval happened and only persistence
    ///   failed, so the batch is adopted to stay visible and retryable at the next
    ///   durability boundary, like a failed explicit ``flushRecallMaintenance()``.
    func adoptMaintenance(
        after error: any Error,
        draftGraph: MemoryGraph,
        proposal: MaintenanceProposal
    ) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        graph = draftGraph
        pendingRecallMaintenance = proposal.pending
        pendingRecallBaseGraph = proposal.baseGraph
    }

    static func apply(_ pending: [PendingRecallMaintenance], to graph: inout MemoryGraph) {
        for record in pending {
            let candidates = record.candidateIDs.compactMap { id -> MemoryCandidate? in
                guard let memory = graph.memories[id],
                      memory.active,
                      MemorySearch.scopeAllows(memory.scope, requested: record.scope) else { return nil }
                return MemoryCandidate(memory: memory, score: 0)
            }
            let byID = Dictionary(candidates.map { ($0.memory.id, $0) }, uniquingKeysWith: { first, _ in first })
            let selected = record.selectedIDs.compactMap { byID[$0] }
            maintainAfterRetrieval(&graph, all: candidates, selected: selected, configuration: record.configuration)
        }
    }

    /// Caller owns `withWriteLock`. A transactional store reloads the current graph
    /// under its process-wide lock, replays pending intents and saves once; with
    /// no file yet `pendingRecallBaseGraph` avoids a cold-start double replay. A
    /// failed checkpoint leaves the intents retryable.
    func flushPendingRecallMaintenanceLocked() async throws {
        // A deferred insert is a local durability boundary: reloading and
        // replaying maintenance here would discard that snapshot before an
        // explicit save or transaction commits it.
        guard !needsSave else { return }
        guard !pendingRecallMaintenance.isEmpty else { return }
        try await commitRecallMaintenance(
            draftGraph: graph,
            pending: pendingRecallMaintenance,
            baseGraph: pendingRecallBaseGraph
        )
    }

    /// Makes a maintenance batch durable and adopts it as engine state. Caller
    /// owns `withWriteLock`. State is written only after persistence accepted the
    /// batch, so a cancelled or failed checkpoint leaves the engine as found: a
    /// recorded batch stays retryable and a mere proposal is forgotten.
    func commitRecallMaintenance(
        draftGraph: MemoryGraph,
        pending: [PendingRecallMaintenance],
        baseGraph: MemoryGraph?
    ) async throws {
        if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence {
            let committed = try await transactionalPersistence.transaction(
                initialGraph: baseGraph ?? draftGraph
            ) { graph in
                try Task.checkCancellation()
                Self.apply(pending, to: &graph)
            }
            adoptDurable(committed.graph)
        } else {
            // Last point the engine controls for a foreign store.
            try Task.checkCancellation()
            try await persist(draftGraph)
            adoptDurable(draftGraph)
        }
    }
}
