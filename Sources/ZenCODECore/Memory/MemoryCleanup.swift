//
//  MemoryCleanup.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/10/26.
//
//  Pure planning of a memory graph cleanup: which entries go, what the graph
//  looks like afterwards, and the report shown before anything is applied.
//

import Foundation

/// Which cleanup rules run, and with what thresholds. `nil` switches a rule
/// off; nothing here is persisted or read from the environment.
struct MemoryCleanupPolicy: Sendable, Equatable {
    static let defaultArchivedRetentionDays = 30
    static let defaultStaleInactivityDays = 180

    /// Rule A: physically remove archived entries (`active == false`) whose
    /// last change is at least this many days old. `0` removes every one.
    var archivedRetentionDays: Int?
    /// Rule B: archive active entries that were never recalled
    /// (`accessCount == 0`) and have not changed for at least this many days
    /// (at least 1). The threshold is scaled per category, see ``MemoryCleanup``.
    var staleInactivityDays: Int?
    /// Rule C: graph hygiene — superseded entries, dangling edges, co-relevance
    /// links beyond the per-entry cap, tags and clusters nobody belongs to, and
    /// embedding vectors the store cannot use.
    var graphHygiene: Bool

    init(
        archivedRetentionDays: Int? = nil,
        staleInactivityDays: Int? = nil,
        graphHygiene: Bool = false
    ) {
        self.archivedRetentionDays = archivedRetentionDays.map { max($0, 0) }
        self.staleInactivityDays = staleInactivityDays.map { max($0, 1) }
        self.graphHygiene = graphHygiene
    }

    /// Whether at least one rule would run.
    var hasActiveRule: Bool {
        archivedRetentionDays != nil || staleInactivityDays != nil || graphHygiene
    }
}

/// What a cleanup plan changes. Counts and lists describe the plan relative to
/// the graph it was computed from; the `*Entries` totals are taken before any
/// change.
struct MemoryCleanupReport: Sendable, Equatable {
    /// One affected entry, as shown in a preview.
    struct EntrySummary: Sendable, Equatable {
        let id: String
        let title: String
        let category: String
        /// `max(createdAt, updatedAt)` before the cleanup.
        let lastChange: Date
    }

    /// Entries in the graph before the cleanup.
    var totalEntries = 0
    var activeEntries = 0
    var archivedEntries = 0

    /// Rule A: archived entries removed for age.
    var removedArchived: [EntrySummary] = []
    /// Rule B: active entries that were archived.
    var archivedStale: [EntrySummary] = []
    /// Rule C: superseded entries removed.
    var removedSuperseded: [EntrySummary] = []
    var removedDanglingEdges = 0
    /// Rule C: `relatesTo` edges dropped to bring every entry down to
    /// ``MemoryRelationPolicy/maximumLinksPerMemory``, counting both directions
    /// of each dropped link.
    var prunedRelations = 0
    var removedTags = 0
    var removedClusters = 0
    var clearedEmbeddings = 0

    /// `true` when the plan changes nothing.
    var isEmpty: Bool {
        removedArchived.isEmpty
            && archivedStale.isEmpty
            && removedSuperseded.isEmpty
            && removedDanglingEdges == 0
            && prunedRelations == 0
            && removedTags == 0
            && removedClusters == 0
            && clearedEmbeddings == 0
    }
}

enum MemoryCleanup {
    private static let secondsPerDay: TimeInterval = 86_400
    private static let maximumTitleLength = 80

    /// Computes the cleaned graph and its report without mutating anything.
    ///
    /// Rules run in a fixed order, so one run is predictable and idempotent:
    ///
    /// 1. **A** removes archived entries unchanged for the retention period.
    /// 2. **B** archives never-recalled, long-unchanged active entries. The
    ///    threshold is `staleInactivityDays` scaled by the category's half-life
    ///    from ``MemoryAgePolicy/default`` relative to the fact half-life (a
    ///    preference at 0.75×, a correction at about 3.04×), so durable kinds
    ///    live longer. An entry archived here is stamped `updatedAt = now` and is
    ///    never removed by rule A in the same run.
    /// 3. **C** (`graphHygiene`) removes superseded entries, recounts tags and
    ///    cluster members and drops empty ones, drops dangling edges, trims every
    ///    entry to ``MemoryRelationPolicy/maximumLinksPerMemory`` `relatesTo`
    ///    links (weakest then oldest first, mirror links included, entries
    ///    visited in id order) and clears embedding vectors. A vector is kept
    ///    only when it was produced by `embeddingModel`; with no model (`nil`: no
    ///    provider configured) none is kept. Clearing a vector leaves
    ///    `updatedAt` alone.
    ///
    /// A plan that changes nothing returns the original graph untouched, so
    /// normalizations of an already consistent graph never make a no-op look
    /// like a change.
    static func plan(
        _ graph: MemoryGraph,
        policy: MemoryCleanupPolicy,
        now: Date,
        embeddingModel: String?
    ) -> (graph: MemoryGraph, report: MemoryCleanupReport) {
        var cleaned = graph
        var report = MemoryCleanupReport()
        report.totalEntries = graph.memories.count
        report.activeEntries = graph.memories.values.filter(\.active).count
        report.archivedEntries = report.totalEntries - report.activeEntries

        if let retentionDays = policy.archivedRetentionDays {
            removeOldArchived(
                from: &cleaned,
                report: &report,
                retentionDays: max(retentionDays, 0),
                now: now
            )
        }
        if let inactivityDays = policy.staleInactivityDays {
            archiveStale(
                in: &cleaned,
                report: &report,
                inactivityDays: max(inactivityDays, 1),
                now: now
            )
        }
        if policy.graphHygiene {
            tidy(&cleaned, report: &report, embeddingModel: embeddingModel)
        }

        guard !report.isEmpty else {
            return (graph, report)
        }
        return (cleaned, report)
    }

    // MARK: - Rule A

    private static func removeOldArchived(
        from graph: inout MemoryGraph,
        report: inout MemoryCleanupReport,
        retentionDays: Int,
        now: Date
    ) {
        let retention = TimeInterval(retentionDays) * secondsPerDay
        var removed: [MemoryCleanupReport.EntrySummary] = []
        for entry in graph.memories.values where !entry.active {
            let lastChange = lastChange(of: entry)
            guard retentionDays == 0 || now.timeIntervalSince(lastChange) >= retention else { continue }
            removed.append(summary(of: entry))
        }
        for item in removed {
            graph.removeMemory(id: item.id)
        }
        report.removedArchived = sorted(removed)
    }

    // MARK: - Rule B

    private static func archiveStale(
        in graph: inout MemoryGraph,
        report: inout MemoryCleanupReport,
        inactivityDays: Int,
        now: Date
    ) {
        let policy = MemoryAgePolicy.default
        var archived: [MemoryCleanupReport.EntrySummary] = []
        for (id, entry) in graph.memories
        where entry.active && entry.accessCount == 0 && entry.supersededBy == nil {
            let ageDays = Float(now.timeIntervalSince(lastChange(of: entry)) / secondsPerDay)
            let threshold = Float(inactivityDays)
                * policy.halfLifeDays(for: entry.category) / policy.factHalfLifeDays
            guard ageDays >= threshold else { continue }
            archived.append(summary(of: entry))
            var updated = entry
            updated.active = false
            updated.updatedAt = now
            graph.memories[id] = updated
        }
        report.archivedStale = sorted(archived)
    }

    // MARK: - Rule C

    private static func tidy(
        _ graph: inout MemoryGraph,
        report: inout MemoryCleanupReport,
        embeddingModel: String?
    ) {
        // Superseded entries only keep a pointer to their replacement.
        let superseded = graph.memories.values
            .filter { !$0.active && $0.supersededBy != nil }
            .map(summary(of:))
        for item in superseded {
            graph.removeMemory(id: item.id)
        }
        report.removedSuperseded = sorted(superseded)

        // A tag counts every entry that carries it, active or not, the way
        // `MemoryGraph.addMemory` counts it.
        var tagUsage: [String: UInt32] = [:]
        for entry in graph.memories.values {
            for name in entry.tags {
                tagUsage["tag:\(name)", default: 0] += 1
            }
        }
        for (id, var tag) in graph.tags {
            guard let usage = tagUsage[id] else {
                graph.tags[id] = nil
                report.removedTags += 1
                continue
            }
            if tag.count != usage {
                tag.count = usage
                graph.tags[id] = tag
            }
        }

        // A cluster's members are the memories with an edge into it.
        var clusterUsage: [String: UInt32] = [:]
        for (source, outgoing) in graph.edges where graph.memories[source] != nil {
            for edge in outgoing {
                if case .inCluster = edge.kind {
                    clusterUsage[edge.target, default: 0] += 1
                }
            }
        }
        for (id, var cluster) in graph.clusters {
            guard let usage = clusterUsage[id] else {
                graph.clusters[id] = nil
                report.removedClusters += 1
                continue
            }
            if cluster.memberCount != usage {
                cluster.memberCount = usage
                graph.clusters[id] = cluster
            }
        }

        // Edges whose ends no longer exist, including those into the tags and
        // clusters dropped above.
        for (source, outgoing) in graph.edges {
            guard graph.memories[source] != nil else {
                report.removedDanglingEdges += outgoing.count
                graph.edges[source] = nil
                continue
            }
            let kept = outgoing.filter { edge in
                if edge.target.hasPrefix("tag:") { return graph.tags[edge.target] != nil }
                if edge.target.hasPrefix("cluster:") { return graph.clusters[edge.target] != nil }
                return graph.memories[edge.target] != nil
            }
            guard kept.count != outgoing.count else { continue }
            report.removedDanglingEdges += outgoing.count - kept.count
            graph.edges[source] = kept.isEmpty ? nil : kept
        }

        // Co-relevance links beyond the per-entry cap, weakest and oldest first,
        // each dropped together with its mirror. Runs after the dangling edges
        // are gone, so only live links compete, and before the reverse index is
        // rebuilt from whatever remains.
        report.prunedRelations = graph.pruneRelations(
            maximumPerMemory: MemoryRelationPolicy.default.maximumLinksPerMemory
        )
        graph.rebuildReverseEdges()

        // Vectors the store cannot compare against are dead weight: they are
        // regenerated when the entry is next written, updated or restored, or
        // by Data management › Rebuild memory embeddings.
        for (id, entry) in graph.memories where entry.embedding != nil {
            if let embeddingModel, entry.embeddingMatches(model: embeddingModel) { continue }
            var updated = entry
            updated.setEmbedding(nil, model: nil)
            graph.memories[id] = updated
            report.clearedEmbeddings += 1
        }
    }

    // MARK: - Helpers

    private static func lastChange(of entry: EngineMemoryEntry) -> Date {
        max(entry.createdAt, entry.updatedAt)
    }

    private static func summary(of entry: EngineMemoryEntry) -> MemoryCleanupReport.EntrySummary {
        var title = MemoryEntryMetadata.titleLine(of: entry.content) ?? "(untitled)"
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength - 1)) + "…"
        }
        return MemoryCleanupReport.EntrySummary(
            id: entry.id,
            title: title,
            category: entry.category.rawValue,
            lastChange: lastChange(of: entry)
        )
    }

    /// Oldest change first, then by id, so previews are stable.
    private static func sorted(
        _ summaries: [MemoryCleanupReport.EntrySummary]
    ) -> [MemoryCleanupReport.EntrySummary] {
        summaries.sorted { lhs, rhs in
            if lhs.lastChange != rhs.lastChange { return lhs.lastChange < rhs.lastChange }
            return lhs.id < rhs.id
        }
    }
}
