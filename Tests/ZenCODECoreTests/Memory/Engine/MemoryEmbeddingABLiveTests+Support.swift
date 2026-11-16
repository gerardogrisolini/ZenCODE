//
//  MemoryEmbeddingABLiveTests+Support.swift
//  ZenCODE
//
//  Support for the live embedding A/B measurement: the memoizing provider and
//  failure recorder doubles, re-embedding with bounded concurrency, graph
//  copying and binary16 rounding.
//

import Foundation
import Testing
@testable import ZenCODECore

extension MemoryEmbeddingABLiveTests {
    // MARK: - Doubles

    /// Embeds each distinct text once; every engine variant shares the cache.
    actor MemoizingEmbeddingProvider: EmbeddingProvider {
        nonisolated let modelID: String
        private let upstream: any EmbeddingProvider
        private var cache: [String: [Float]] = [:]
        private(set) var requestCount = 0
        private(set) var requestDurations: [Double] = []

        init(upstream: any EmbeddingProvider) {
            self.upstream = upstream
            self.modelID = upstream.modelID
        }

        func embed(_ text: String) async throws -> [Float] {
            if let cached = cache[text] { return cached }
            let clock = ContinuousClock()
            let start = clock.now
            let vector = try await upstream.embed(text)
            requestDurations.append(MemoryEmbeddingABLiveTests.milliseconds(clock.now - start))
            requestCount += 1
            cache[text] = vector
            return vector
        }
    }

    final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func record(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    // MARK: - Re-embedding

    struct ReembedJob: Sendable {
        let id: String
        /// Exactly the text production embeds for an entry.
        let text: String
    }

    struct ReembedResult: Sendable {
        let id: String
        let values: [Float]?
        /// Latency of the request that produced `values` (0 when it failed).
        let milliseconds: Double
        let attempts: Int
        let error: String?
    }

    /// Embeds `jobs` with at most `maxConcurrent` requests in flight. A failing
    /// job is retried once; if it fails again it is returned with its error and
    /// no vector instead of aborting the run.
    static func reembed(
        _ jobs: [ReembedJob],
        with provider: any EmbeddingProvider,
        maxConcurrent: Int
    ) async -> [ReembedResult] {
        await withTaskGroup(of: ReembedResult.self, returning: [ReembedResult].self) { group in
            var results: [ReembedResult] = []
            var next = 0
            while next < min(maxConcurrent, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { await Self.reembedOne(job, with: provider) }
            }
            while let result = await group.next() {
                results.append(result)
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await Self.reembedOne(job, with: provider) }
                }
            }
            return results
        }
    }

    private static func reembedOne(_ job: ReembedJob, with provider: any EmbeddingProvider) async -> ReembedResult {
        let clock = ContinuousClock()
        var lastError = ""
        for attempt in 1...2 {
            let start = clock.now
            do {
                let values = try await provider.embed(job.text)
                return ReembedResult(
                    id: job.id, values: values, milliseconds: milliseconds(clock.now - start),
                    attempts: attempt, error: nil
                )
            } catch {
                lastError = describe(error)
            }
        }
        return ReembedResult(id: job.id, values: nil, milliseconds: 0, attempts: 2, error: lastError)
    }

    /// One-line, bounded error text for the report; credential-looking tokens
    /// are redacted defensively.
    private static func describe(_ error: Error) -> String {
        let text: String
        if case OpenAICompatibleEmbeddingError.httpStatus(let status, let body) = error {
            text = "HTTP \(status): \(body)"
        } else {
            text = String(describing: error)
        }
        let redacted = text
            .replacingOccurrences(of: #"(?i)bearer\s+\S+"#, with: "Bearer <redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{8,}"#, with: "<redacted>", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        return String(redacted.prefix(200))
    }

    // MARK: - Helpers

    /// Copies the graph at `source` into `directory` under its own name, with
    /// its vectors file (`<graph>.vectors`, graph version 4) when there is one,
    /// and returns the copy's URL. Without the vectors file a version 4 copy
    /// would load with no vector at all.
    static func copyGraphFiles(from source: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: copy)
        let sourceVectors = JSONMemoryPersistence.vectorsURL(forGraphAt: source)
        if fileManager.fileExists(atPath: sourceVectors.path) {
            try fileManager.copyItem(at: sourceVectors, to: JSONMemoryPersistence.vectorsURL(forGraphAt: copy))
        }
        return copy
    }

    /// `graph` with every vector component rounded to the nearest binary16
    /// value, everything else unchanged.
    static func roundedToFloat16(_ graph: MemoryGraph) -> MemoryGraph {
        var rounded = graph
        for (id, entry) in graph.memories {
            guard let embedding = entry.embedding else { continue }
            rounded.memories[id]?.setEmbedding(HalfPrecision.rounded(embedding), model: entry.embeddingModel)
        }
        return rounded
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
