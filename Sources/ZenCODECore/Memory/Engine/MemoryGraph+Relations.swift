//
//  MemoryGraph+Relations.swift
//  ZenCODE
//
//  Creation, reinforcement, eviction and pruning of the co-relevance
//  (`relatesTo`) edges. Only `relatesTo` edges are ever touched here: `hasTag`,
//  `inCluster`, `supersedes`, `contradicts` and `derivedFrom` edges between the
//  same memories survive, reverse index included.
//

import Foundation

extension EdgeKind {
    /// Weight of a `relatesTo` edge; `nil` for every other kind.
    var relationWeight: Float? {
        if case .relatesTo(let weight) = self { return weight }
        return nil
    }
}

extension MemoryGraph {
    /// Records that two memories were selected together.
    ///
    /// The pair is treated as one symmetric relation stored as two edges:
    ///
    /// - **New pair**: both directions are created at `policy.initialWeight`.
    /// - **Known pair** (in at least one direction): the new weight is the
    ///   heaviest existing weight plus `policy.reinforcementStep`, capped at
    ///   `policy.maximumWeight` and never below that heaviest weight. It is
    ///   applied to both directions, updating existing edges in place (their
    ///   position, hence their age, is kept) and inserting the missing one.
    /// - **Cap**: inserting an edge into a memory that already has
    ///   `policy.maximumLinksPerMemory` or more `relatesTo` edges first evicts
    ///   that memory's weakest relations — the oldest among equals, always, even
    ///   if the weakest weighs as much as the new edge — until it is below the
    ///   cap. Every eviction removes both directions of the evicted relation.
    ///   Merely reinforcing an existing edge never evicts anything.
    ///
    /// A no-op returning `false` when either endpoint is missing or inactive
    /// (see ``linkMemories(from:to:weight:)`` for why), or when both ends are
    /// the same memory. Otherwise `linkDiscoveryCount` grows by one per
    /// direction, created or reinforced.
    @discardableResult
    mutating func reinforceRelation(
        between first: String,
        and second: String,
        policy: MemoryRelationPolicy = .default
    ) -> Bool {
        guard first != second,
              let firstMemory = memories[first], firstMemory.active,
              let secondMemory = memories[second], secondMemory.active else { return false }

        let heaviest = (relationWeights(from: first, to: second) + relationWeights(from: second, to: first)).max()
        let weight = heaviest.map(policy.reinforcedWeight(from:)) ?? policy.initialWeight
        setRelation(from: first, to: second, weight: weight, policy: policy)
        setRelation(from: second, to: first, weight: weight, policy: policy)
        metadata.linkDiscoveryCount &+= 2
        return true
    }

    /// Reduces every memory to at most `limit` outgoing `relatesTo` edges and
    /// returns how many edges were removed, mirrored directions included.
    ///
    /// Same criterion as the cap in ``reinforceRelation(between:and:policy:)``:
    /// the weakest relations go first, the oldest among equals (so on a graph
    /// whose weights are all equal the newest `limit` survive). Each removal is
    /// symmetric. Memories are processed in id order, which makes the outcome
    /// deterministic; removals only ever lower degrees, so a second call on the
    /// result changes nothing. Edges of any other kind are never touched.
    @discardableResult
    mutating func pruneRelations(maximumPerMemory limit: Int) -> Int {
        let limit = max(limit, 0)
        var removed = 0
        for id in edges.keys.sorted() {
            // Re-read at processing time: earlier memories' symmetric removals
            // may already have shortened this list.
            guard let outgoing = edges[id] else { continue }
            var relations: [(position: Int, target: String, weight: Float)] = []
            for (position, edge) in outgoing.enumerated() {
                if let weight = edge.kind.relationWeight {
                    relations.append((position, edge.target, weight))
                }
            }
            guard relations.count > limit else { continue }
            relations.sort { lhs, rhs in
                lhs.weight != rhs.weight ? lhs.weight < rhs.weight : lhs.position < rhs.position
            }
            for victim in relations.prefix(relations.count - limit) {
                removed += removeRelation(between: id, and: victim.target)
            }
        }
        return removed
    }

    // MARK: - Helpers

    /// Weights of the `relatesTo` edges `from → to` (more than one only in
    /// graphs written before edges were de-duplicated by pair).
    private func relationWeights(from: String, to: String) -> [Float] {
        (edges[from] ?? []).compactMap { $0.target == to ? $0.kind.relationWeight : nil }
    }

    private func relationCount(of id: String) -> Int {
        (edges[id] ?? []).reduce(0) { $0 + ($1.kind.relationWeight == nil ? 0 : 1) }
    }

    /// Target of the weakest `relatesTo` edge of `id`; the first one (the
    /// oldest) wins ties.
    private func weakestRelationTarget(of id: String) -> String? {
        var weakest: (target: String, weight: Float)?
        for edge in edges[id] ?? [] {
            guard let weight = edge.kind.relationWeight else { continue }
            if weakest == nil || weight < weakest!.weight {
                weakest = (edge.target, weight)
            }
        }
        return weakest?.target
    }

    /// Gives the `relatesTo` edge `from → to` exactly `weight`: in place when
    /// it exists (a legacy duplicate of the same pair is dropped), otherwise
    /// appended after evicting down to the cap.
    private mutating func setRelation(
        from: String,
        to: String,
        weight: Float,
        policy: MemoryRelationPolicy
    ) {
        if let index = edges[from]?.firstIndex(where: { $0.target == to && $0.kind.relationWeight != nil }) {
            edges[from]?[index].kind = .relatesTo(weight: weight)
            var position = 0
            edges[from]?.removeAll { edge in
                defer { position += 1 }
                return position > index && edge.target == to && edge.kind.relationWeight != nil
            }
            return
        }
        while relationCount(of: from) >= policy.maximumLinksPerMemory,
              let victim = weakestRelationTarget(of: from) {
            removeRelation(between: from, and: victim)
        }
        addEdge(from: from, to: to, kind: .relatesTo(weight: weight))
    }

    /// Removes every `relatesTo` edge between two memories, both directions,
    /// and returns how many edges that was.
    @discardableResult
    private mutating func removeRelation(between first: String, and second: String) -> Int {
        removeRelatesToEdges(from: first, to: second) + removeRelatesToEdges(from: second, to: first)
    }

    /// Removes the `relatesTo` edges `from → to`. The reverse index entry goes
    /// only when no edge of another kind still joins the two, unlike
    /// ``removeEdge(from:to:kind:)``, which drops it unconditionally.
    private mutating func removeRelatesToEdges(from: String, to: String) -> Int {
        guard let before = edges[from]?.count else { return 0 }
        edges[from]?.removeAll { $0.target == to && $0.kind.relationWeight != nil }
        let remaining = edges[from] ?? []
        let removed = before - remaining.count
        guard removed > 0 else { return 0 }
        if remaining.isEmpty { edges[from] = nil }
        if !remaining.contains(where: { $0.target == to }) {
            reverseEdges[to]?.removeAll { $0 == from }
            if reverseEdges[to]?.isEmpty == true { reverseEdges[to] = nil }
        }
        return removed
    }
}
