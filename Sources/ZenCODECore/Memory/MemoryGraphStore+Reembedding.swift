//
//  MemoryGraphStore+Reembedding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//
//  Re-embedding of a whole graph with the store's own provider: every active
//  entry without a compatible vector gets one, archived entries lose theirs.
//  The planning rules live in `MemoryReembedding.swift`.
//

import Foundation

extension MemoryGraphStore {
    /// Model identity of the store's embedder; `nil` without a provider (BM25).
    nonisolated var embeddingModelID: String? {
        embedder?.modelID
    }

    /// What ``reembed(run:progress:)`` would do, from one coherent snapshot and
    /// without any request; `nil` when the store has no embedder.
    func reembeddingPlan() async throws -> MemoryReembeddingPlan? {
        guard let embedder else { return nil }
        let graph = try await engine.freshSnapshotForReadOnly()
        return MemoryReembedding.plan(graph, modelID: embedder.modelID)
    }

    /// Gives every active entry a vector from the store's embedder and clears
    /// the vectors of archived entries. Without an embedder it does nothing.
    ///
    /// An entry is embedded when it has no vector, a vector from another model,
    /// or a vector whose length differs from the run's dimension (the length of
    /// the first vector the endpoint returned in this run). Entries of the
    /// last kind are found only once the dimension is known, so a graph whose
    /// only vectors are of the right model but the wrong length is left alone
    /// unless a request is sent anyway.
    ///
    /// The text embedded is the stored `content`, exactly what a new write
    /// embeds. Vectors are requested outside any transaction, at most
    /// ``MemoryReembedding/Options/maximumConcurrentRequests`` at a time, and
    /// saved every ``MemoryReembedding/Options/batchSize`` entries in one
    /// engine transaction, which sets a vector only if the entry still exists,
    /// is still active, has the same content and has not meanwhile received a
    /// compatible vector. An interruption therefore leaves every entry either
    /// with its new vector or as it was. `updatedAt` is never touched.
    ///
    /// Once ``MemoryReembeddingRun/acceptsNewRequests`` turns false (Esc or an
    /// abort) no request starts; those in flight finish and their vectors are
    /// saved before the call returns.
    func reembed(
        run: MemoryReembeddingRun,
        progress: @escaping @Sendable (MemoryReembeddingProgress) -> Void = { _ in }
    ) async throws -> MemoryReembeddingGraphSummary {
        var summary = MemoryReembeddingGraphSummary()
        guard let embedder else { return summary }
        let modelID = embedder.modelID

        // Local and cheap: archived entries are never recalled, so their
        // vectors only weigh on the file.
        summary.clearedArchivedVectors = try await engine.transaction { graph in
            MemoryReembedding.clearArchivedVectors(in: &graph)
        }

        let graph = try await engine.freshSnapshotForReadOnly()
        let knownDimensions = run.dimensions
        var queue: [ReembeddingCandidate] = []
        // Vectors of the right model whose length can only be judged once the
        // endpoint has answered once.
        var awaitingDimension: [(candidate: ReembeddingCandidate, length: Int)] = []
        for entry in graph.memories.values.filter(\.active).sorted(by: Self.reembeddingOrder) {
            if let reason = MemoryReembedding.reason(
                for: entry,
                modelID: modelID,
                dimensions: knownDimensions
            ) {
                queue.append(ReembeddingCandidate(id: entry.id, content: entry.content, reason: reason))
            } else if knownDimensions == nil, let embedding = entry.embedding {
                awaitingDimension.append((
                    ReembeddingCandidate(id: entry.id, content: entry.content, reason: .otherDimensions),
                    embedding.count
                ))
            }
        }

        summary.needed = queue.count
        var counters = MemoryReembeddingProgress(total: queue.count)
        progress(counters)

        let batchSize = max(run.options.batchSize, 1)
        var next = 0
        while next < queue.count, run.acceptsNewRequests {
            let end = min(next + batchSize, queue.count)
            let block = Array(queue[next..<end])
            next = end
            let received = try await embedBlock(
                block,
                embedder: embedder,
                run: run,
                counters: &counters,
                progress: progress
            )
            summary.failed += received.failed
            if !received.vectors.isEmpty {
                let saved = try await saveVectors(
                    received.vectors,
                    modelID: modelID,
                    dimensions: run.dimensions
                )
                summary.embedded += saved.embedded
                summary.resized += saved.resized
                summary.skipped += saved.skipped
            }
            if !awaitingDimension.isEmpty, let dimensions = run.dimensions {
                let resized = awaitingDimension
                    .filter { $0.length != dimensions }
                    .map(\.candidate)
                awaitingDimension = []
                queue += resized
                summary.needed += resized.count
                counters.total += resized.count
                progress(counters)
            }
        }
        return summary
    }

    // MARK: - Helpers

    private struct ReembeddingCandidate: Sendable {
        let id: String
        /// The stored content at snapshot time: what is embedded, and what the
        /// entry must still contain when the vector is saved.
        let content: String
        let reason: MemoryReembeddingReason
    }

    private struct ReceivedVector: Sendable {
        let candidate: ReembeddingCandidate
        let values: [Float]
    }

    private enum AttemptOutcome: Sendable {
        case vector([Float])
        case failed(MemoryReembedding.FailureKind, String)
        /// The run stopped before a retry could be sent.
        case notAttempted
    }

    /// Newest first: the entries most likely to be recalled get their vectors
    /// first if the run stops early.
    private static func reembeddingOrder(_ lhs: GraphEntry, _ rhs: GraphEntry) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    /// Requests the vectors of one block with bounded concurrency and returns
    /// those received, plus how many entries failed. Stops launching as soon
    /// as the run no longer accepts requests, but always waits for the ones in
    /// flight.
    private func embedBlock(
        _ block: [ReembeddingCandidate],
        embedder: any EmbeddingProvider,
        run: MemoryReembeddingRun,
        counters: inout MemoryReembeddingProgress,
        progress: @Sendable (MemoryReembeddingProgress) -> Void
    ) async throws -> (vectors: [ReceivedVector], failed: Int) {
        let limit = max(run.options.maximumConcurrentRequests, 1)
        var vectors: [ReceivedVector] = []
        var failed = 0
        try await withThrowingTaskGroup(of: (ReembeddingCandidate, AttemptOutcome).self) { group in
            var nextIndex = 0
            var inFlight = 0
            while inFlight < limit, nextIndex < block.count, run.acceptsNewRequests {
                let candidate = block[nextIndex]
                nextIndex += 1
                inFlight += 1
                group.addTask {
                    (candidate, try await Self.attemptEmbedding(candidate.content, embedder: embedder, run: run))
                }
            }
            while let (candidate, outcome) = try await group.next() {
                inFlight -= 1
                switch outcome {
                case let .vector(values):
                    counters.processed += 1
                    if run.recordVector(length: values.count) {
                        vectors.append(ReceivedVector(candidate: candidate, values: values))
                    } else {
                        // The endpoint changed its vector length mid-run:
                        // mixing lengths would leave vectors recall skips.
                        failed += 1
                        counters.failed += 1
                        run.recordFailure(.permanent, summary: "vector length changed")
                    }
                case let .failed(kind, summary):
                    run.recordFailure(kind, summary: summary)
                    // A rejected endpoint is not this entry's fault: it stays
                    // among the remaining entries instead of the failed ones.
                    if !kind.rejectsEndpoint {
                        failed += 1
                        counters.processed += 1
                        counters.failed += 1
                    }
                case .notAttempted:
                    break
                }
                progress(counters)
                while inFlight < limit, nextIndex < block.count, run.acceptsNewRequests {
                    let candidate = block[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        (candidate, try await Self.attemptEmbedding(candidate.content, embedder: embedder, run: run))
                    }
                }
            }
        }
        return (vectors, failed)
    }

    /// One entry's requests: up to ``MemoryReembedding/Options/maximumAttempts``,
    /// retrying only retryable failures after a growing wait, and never
    /// starting a retry once the run stopped accepting requests.
    private static func attemptEmbedding(
        _ text: String,
        embedder: any EmbeddingProvider,
        run: MemoryReembeddingRun
    ) async throws -> AttemptOutcome {
        let attempts = max(run.options.maximumAttempts, 1)
        var lastFailure = "unknown"
        for attempt in 1...attempts {
            if attempt > 1 {
                guard run.acceptsNewRequests else { return .notAttempted }
                try await run.waitBeforeRetry(
                    MemoryReembedding.retryDelay(afterAttempt: attempt - 1, options: run.options)
                )
                guard run.acceptsNewRequests else { return .notAttempted }
            }
            do {
                let values = try await embedder.embed(text)
                guard !values.isEmpty else {
                    return .failed(.permanent, "emptyEmbedding")
                }
                return .vector(values)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                // Cancellation can surface as another error type.
                try Task.checkCancellation()
                lastFailure = MemoryReembedding.failureSummary(error)
                let kind = MemoryReembedding.classify(error)
                guard kind == .retryable else {
                    return .failed(kind, lastFailure)
                }
            }
        }
        return .failed(.retryable, lastFailure)
    }

    /// Saves one block of vectors in one transaction, each only on an entry
    /// that still exists, is active, has the content that was embedded and
    /// still needs a vector: a concurrent write, update, archive or delete
    /// always wins.
    private func saveVectors(
        _ vectors: [ReceivedVector],
        modelID: String,
        dimensions: Int?
    ) async throws -> (embedded: Int, resized: Int, skipped: Int) {
        try await engine.transaction { graph in
            var embedded = 0
            var resized = 0
            var skipped = 0
            for vector in vectors {
                let id = vector.candidate.id
                guard var entry = graph.memories[id],
                      entry.active,
                      entry.content == vector.candidate.content,
                      let reason = MemoryReembedding.reason(
                          for: entry,
                          modelID: modelID,
                          dimensions: dimensions
                      ) else {
                    skipped += 1
                    continue
                }
                entry.setEmbedding(vector.values, model: modelID)
                graph.memories[id] = entry
                embedded += 1
                if reason == .otherDimensions {
                    resized += 1
                }
            }
            return (embedded, resized, skipped)
        }
    }
}
