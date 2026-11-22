//
//  MemoryGraphStore+Automatic.swift
//  ZenCODE
//
//  Automatic memory: the per-turn recall pipeline and the conservative
//  automatic writer.
//

import Foundation

extension MemoryGraphStore {
    // MARK: - Automatic turn pipeline

    /// Runs the engine's full analyze → retrieve → select → format pipeline and
    /// returns the ready-to-inject memory block (empty when nothing was selected).
    ///
    /// Retrieval is never prefetched into a shared slot:
    /// `MemoryGraphStoreRegistry` shares one engine per workspace across every
    /// session, sub-agent and tool call, so overlapping turns would hand one
    /// session another's memories. This per-call path keeps each retrieval
    /// bound to the prompt that asked. `visibility` restricts the recall to the
    /// entries one profile owns (see `MemoryAuthorScope`).
    func context(
        for prompt: String,
        scope: GraphScope = .all,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> String {
        try await engine.context(for: prompt, scope: scope, visibility: visibility)
    }

    /// Same memory block using only local ranking: the deadline fallback for
    /// automatic recall. Requires an embedding provider (without one `context(for:)`
    /// is already local BM25). Read-only, so running it beside the full semantic
    /// recall cannot double-apply retrieval maintenance.
    func lexicalFallbackContext(
        for prompt: String,
        scope: GraphScope = .all,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> String? {
        guard embedder != nil else { return nil }
        return try await engine.lexicalContextReadOnly(
            for: prompt,
            scope: scope,
            graph: try await engine.freshSnapshotForReadOnly().restricted(to: visibility)
        )
    }

    /// Flushes only automatic-recall maintenance.
    func flushRecallMaintenance() async throws {
        try await engine.flushRecallMaintenance()
    }
}

// MARK: - Conservative automatic writer (manual mutation semantics are unchanged)
extension MemoryGraphStore {
    struct LearningSnapshot: Sendable {
        let entries: [GraphEntry]
        let comparison: [String: String]
        /// The scope the snapshot was taken in: the commit compares, deduplicates
        /// and writes in the same one.
        var visibility: MemoryAuthorScope? = nil
    }

    /// Term-coverage score used by the automatic writer to pick the lexically
    /// relevant notes it shows for deduplication; an empty query matches every
    /// entry. `memory.search` ranks with BM25 instead (see `search`).
    static func lexicalScore(_ entry: GraphEntry, query: String) -> Int {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return 1
        }
        let haystack = entry.searchableText
        var score = 0
        if haystack.contains(normalizedQuery) {
            score += 50
        }
        var seenTerms = Set<String>()
        let terms = normalizedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && seenTerms.insert($0).inserted }
        guard !terms.isEmpty else {
            return score
        }
        var matchedTerms = 0
        for term in terms where haystack.contains(term) {
            matchedTerms += 1
            score += 10
        }
        if matchedTerms == terms.count {
            score += 25
        }
        return score
    }

    /// The entries the automatic writer shows the model for deduplication and
    /// the comparison set its commit rechecks, both limited to the entries
    /// `visibility` allows: another profile's notes are neither shown nor
    /// treated as duplicates.
    func learningSnapshot(
        query: String = "",
        visibility: MemoryAuthorScope? = nil
    ) async throws -> LearningSnapshot? {
        let graph = try await engine.freshSnapshotForReadOnly().restricted(to: visibility)
        let active = graph.memories.values.filter(\.active)
        let comparison = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.content) })
        let scored: [(entry: GraphEntry, score: Int)] = active.map { entry in
            (entry: entry, score: Self.lexicalScore(entry, query: query))
        }
        let relevant = scored.filter { $0.score > 0 }
        let ranked = relevant.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.entry.id < rhs.entry.id
            }
            return lhs.score > rhs.score
        }
        var entries: [GraphEntry] = []
        var characters = 0
        for (entry, _) in ranked {
            guard entries.count < 24, characters + entry.content.count <= 8000,
                  MemoryLearningPrivacy.accepts(entry.content, limit: 1500) else { continue }
            entries.append(entry)
            characters += entry.content.count
        }
        return LearningSnapshot(entries: entries, comparison: comparison, visibility: visibility)
    }

    /// Atomic current-state/dedup recheck, including manual writes performed
    /// during proposal generation. Any changed comparison set causes a no-op.
    func commitLearning(
        content: String,
        existingID: String?,
        snapshot: LearningSnapshot,
        permit: MemoryLearningPermit,
        event: UUID
    ) async throws -> Bool {
        guard MemoryLearningPrivacy.accepts(content, limit: 1000), permit.canPropose else { return false }
        let expected = snapshot.comparison
        let visibility = snapshot.visibility
        if let existingID, !snapshot.entries.contains(where: { $0.id == existingID }) { return false }
        try Task.checkCancellation()
        return try await engine.transaction { graph in
            try Task.checkCancellation()
            let current = Dictionary(uniqueKeysWithValues: graph.memories.values
                .filter { $0.active && (visibility?.allows($0) ?? true) }
                .map { ($0.id, $0.content) })
            guard current == expected else { return false }
            let key = Self.learningComparisonKey(content)
            if current.values.contains(where: { Self.learningComparisonKey($0) == key }) { return false }
            // Approximate lexical near-duplicates are rejected unless the model
            // identified that very lookup ID as the entry to update.
            let words = Set(key.split(separator: " "))
            for (id, value) in current where id != existingID {
                let other = Set(Self.learningComparisonKey(value).split(separator: " "))
                let union = words.union(other).count
                if union > 0, Double(words.intersection(other).count) / Double(union) >= 0.8 { return false }
            }
            var updatedContent = content
            if let existingID, let entry = graph.memories[existingID] {
                guard entry.active, entry.scope == .project, visibility?.allows(entry) ?? true else { return false }
                // Automatic updates only enrich: never erase manually authored
                // information to fit the budget. An overlong merge is a no-op.
                guard !Self.learningComparisonKey(entry.content).contains(key) else { return false }
                updatedContent = MemoryService.contentWithUpdateMetadata(
                    entry.content + "\nVerified update:\n" + content, existingEntry: entry,
                    updatedAt: Date(), timeZone: .current)
                guard MemoryLearningPrivacy.accepts(updatedContent, limit: 1000) else { return false }
            }
            guard permit.reserve(event: event) else { return false }
            if let existingID {
                guard var entry = graph.memories[existingID], entry.active, entry.scope == .project,
                      visibility?.allows(entry) ?? true else { return false }
                entry.content = updatedContent
                entry.updatedAt = Date()
                entry.autoGeneratedTimestamp = false
                entry.setEmbedding(nil, model: nil)
                entry.refreshSearchText()
                graph.addMemory(entry)
            } else {
                var entry = GraphEntry(id: MemoryIdentifier.makeNew(), category: .fact,
                                       content: content, tags: ["automatic", "verified-project"],
                                       source: MemorySource.learn, trust: .medium, scope: .project,
                                       author: visibility?.author)
                entry.refreshSearchText()
                graph.addMemory(entry)
            }
            return true
        }
    }

    private static func learningComparisonKey(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("Timestamp:") && !$0.hasPrefix("Updated:") && !$0.hasPrefix("Sources:") }
            .joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
