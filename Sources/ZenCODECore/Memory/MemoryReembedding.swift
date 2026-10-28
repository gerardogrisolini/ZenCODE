//
//  MemoryReembedding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//
//  Pure parts of a memory re-embedding: which entries need a vector from the
//  configured model, how an embedding failure is classified, and the state one
//  run shares across every graph it visits. The store applies them in
//  `MemoryGraphStore+Reembedding.swift`; nothing here performs I/O.
//

import Foundation
import Synchronization

/// What re-embedding one graph would do, computed without any request.
struct MemoryReembeddingPlan: Sendable, Equatable {
    /// Active entries in the graph.
    var activeEntries = 0
    /// Active entries without a vector, or with a vector from another model.
    var entriesToEmbed = 0
    /// Archived entries that still carry a vector; the run clears them.
    var archivedVectors = 0

    /// `true` when the run would neither send a request nor clear a vector.
    var isEmpty: Bool {
        entriesToEmbed == 0 && archivedVectors == 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            activeEntries: lhs.activeEntries + rhs.activeEntries,
            entriesToEmbed: lhs.entriesToEmbed + rhs.entriesToEmbed,
            archivedVectors: lhs.archivedVectors + rhs.archivedVectors
        )
    }
}

/// Why an active entry needs a new vector.
enum MemoryReembeddingReason: Sendable, Equatable {
    case missing
    case otherModel
    /// Same model identity, but a length different from the vectors the
    /// endpoint returns now: recall skips such a vector.
    case otherDimensions
}

/// What re-embedding one graph did.
struct MemoryReembeddingGraphSummary: Sendable, Equatable {
    /// Active entries that needed a vector, including those found with a
    /// different vector length once the run knew the dimension.
    var needed = 0
    /// Vectors saved.
    var embedded = 0
    /// Of ``embedded``, entries whose previous vector had a different length.
    var resized = 0
    /// Entries whose requests failed; they keep their previous state.
    var failed = 0
    /// Entries changed, archived, deleted or given a compatible vector by
    /// someone else before their vector was saved; they were left alone.
    var skipped = 0
    /// Vectors removed from archived entries.
    var clearedArchivedVectors = 0

    /// Entries the run never finished because it stopped first.
    var remaining: Int {
        max(needed - embedded - failed - skipped, 0)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            needed: lhs.needed + rhs.needed,
            embedded: lhs.embedded + rhs.embedded,
            resized: lhs.resized + rhs.resized,
            failed: lhs.failed + rhs.failed,
            skipped: lhs.skipped + rhs.skipped,
            clearedArchivedVectors: lhs.clearedArchivedVectors + rhs.clearedArchivedVectors
        )
    }
}

/// Live counters for the progress line of one graph.
struct MemoryReembeddingProgress: Sendable, Equatable {
    /// Entries with a final answer: a vector received or a failure.
    var processed = 0
    var failed = 0
    var total = 0
}

/// Why a run stopped before finishing, other than Esc.
enum MemoryReembeddingAbort: Sendable, Equatable {
    /// HTTP 401, 403 or 404: every further request would fail the same way.
    case endpointRejected(status: Int)
    /// The first `count` entries of the run all failed and none succeeded.
    case initialRequestsFailed(count: Int, lastFailure: String)
}

enum MemoryReembedding {
    /// Tuning of one run. The defaults send at most 4 requests at a time, save
    /// every 16 entries, and retry a busy or failing endpoint 4 times after 1,
    /// 2, 4 and 8 seconds.
    struct Options: Sendable {
        /// Entries whose vectors are saved together in one transaction.
        var batchSize = 16
        var maximumConcurrentRequests = 4
        /// Requests per entry, the first included.
        var maximumAttempts = 5
        /// Wait before the first retry; it doubles before each further one.
        var initialRetryDelay: Duration = .seconds(1)
        /// When this many entries have failed before any succeeded, the run
        /// stops instead of failing every remaining entry the same way.
        var probeEntryCount = 8
        /// Replaces the wait between attempts (tests). `nil` waits in short
        /// slices, so a stop request does not sit through a long backoff.
        var sleep: (@Sendable (Duration) async throws -> Void)?

        static let `default` = Options()
    }

    /// How an embedding error affects the entry and the run.
    enum FailureKind: Sendable, Equatable {
        /// HTTP 429, 408, 5xx or a transport failure: worth another attempt.
        case retryable
        /// Any other failure: this entry is given up, the run goes on.
        case permanent
        /// HTTP 401, 403 or 404: the whole run stops.
        case endpointRejected(status: Int)

        var rejectsEndpoint: Bool {
            if case .endpointRejected = self { return true }
            return false
        }
    }

    // MARK: - Planning

    /// Counts, for the preliminary plan, the active entries with no vector or
    /// a vector from another model, and the archived entries with a vector.
    /// Vector lengths are not compared: the dimension is only known from the
    /// endpoint's first answer, so the run checks it.
    static func plan(_ graph: MemoryGraph, modelID: String) -> MemoryReembeddingPlan {
        var plan = MemoryReembeddingPlan()
        for entry in graph.memories.values {
            if entry.active {
                plan.activeEntries += 1
                if reason(for: entry, modelID: modelID, dimensions: nil) != nil {
                    plan.entriesToEmbed += 1
                }
            } else if entry.embedding != nil {
                plan.archivedVectors += 1
            }
        }
        return plan
    }

    /// Why `entry` needs a new vector from `modelID`, or `nil` when its vector
    /// is compatible. With `dimensions` unknown (`nil`) a vector of the right
    /// model counts as compatible whatever its length.
    static func reason(
        for entry: EngineMemoryEntry,
        modelID: String,
        dimensions: Int?
    ) -> MemoryReembeddingReason? {
        guard let embedding = entry.embedding else {
            return .missing
        }
        guard entry.embeddingMatches(model: modelID) else {
            return .otherModel
        }
        if let dimensions, embedding.count != dimensions {
            return .otherDimensions
        }
        return nil
    }

    /// Removes the vector of every archived entry, leaving `updatedAt` alone,
    /// and returns how many were removed.
    static func clearArchivedVectors(in graph: inout MemoryGraph) -> Int {
        var cleared = 0
        for (id, entry) in graph.memories where !entry.active && entry.embedding != nil {
            var updated = entry
            updated.setEmbedding(nil, model: nil)
            graph.memories[id] = updated
            cleared += 1
        }
        return cleared
    }

    // MARK: - Failures

    static func classify(_ error: any Error) -> FailureKind {
        if let embeddingError = error as? OpenAICompatibleEmbeddingError {
            switch embeddingError {
            case let .httpStatus(status, _):
                switch status {
                case 401, 403, 404:
                    return .endpointRejected(status: status)
                case 408, 429, 500..<600:
                    return .retryable
                default:
                    return .permanent
                }
            case .emptyEmbedding, .responseBodyTooLarge:
                return .permanent
            }
        }
        if let transportError = error as? RemoteTransportError {
            switch transportError {
            case .timeout, .closed, .connectionFailure, .tlsFailure:
                return .retryable
            default:
                return .permanent
            }
        }
        if error is URLError {
            return .retryable
        }
        return .permanent
    }

    /// Short, secret-free description of a failure: a status or an error kind,
    /// never a response body, an endpoint, a key or the embedded text.
    static func failureSummary(_ error: any Error) -> String {
        if let transportError = error as? RemoteTransportError {
            // Only the case name: associated messages can quote hosts or bodies.
            return "transportError \(transportCaseName(transportError))"
        }
        return MemorySemanticFallbackDiagnostics.embeddingFailureSummary(error)
    }

    private static func transportCaseName(_ error: RemoteTransportError) -> String {
        switch error {
        case .invalidURL: "invalidURL"
        case .unsupportedScheme: "unsupportedScheme"
        case .invalidHTTPMethod: "invalidHTTPMethod"
        case .invalidHeader: "invalidHeader"
        case .invalidWebSocketFrameSize: "invalidWebSocketFrameSize"
        case .timeout: "timeout"
        case .shutdown: "shutdown"
        case .upgradeRejected: "upgradeRejected"
        case .closed: "closed"
        case .bodyAlreadyConsumed: "bodyAlreadyConsumed"
        case .concurrentBodyRead: "concurrentBodyRead"
        case .concurrentWebSocketReceive: "concurrentWebSocketReceive"
        case .protocolViolation: "protocolViolation"
        case .tlsFailure: "tlsFailure"
        case .connectionFailure: "connectionFailure"
        }
    }

    /// Wait before attempt `attempt + 1`: the initial delay doubled for each
    /// earlier retry (1, 2, 4, 8 seconds with the defaults).
    static func retryDelay(afterAttempt attempt: Int, options: Options) -> Duration {
        let exponent = min(max(attempt - 1, 0), 16)
        return options.initialRetryDelay * (1 << exponent)
    }
}

/// The state one re-embedding run shares across every graph it visits: the
/// stop request (Esc), the abort reason, the vector dimension observed in the
/// first successful answer, and the failures counted before any success.
final class MemoryReembeddingRun: Sendable {
    let options: MemoryReembedding.Options

    private struct State {
        var stopRequested = false
        var abort: MemoryReembeddingAbort?
        var dimensions: Int?
        var hasSucceeded = false
        var failuresBeforeFirstSuccess = 0
    }

    private let state = Mutex(State())

    init(options: MemoryReembedding.Options = .default) {
        self.options = options
    }

    /// Esc: no new request starts; requests in flight finish and are saved.
    func requestStop() {
        state.withLock { $0.stopRequested = true }
    }

    var isStopRequested: Bool {
        state.withLock { $0.stopRequested }
    }

    var abort: MemoryReembeddingAbort? {
        state.withLock { $0.abort }
    }

    /// Vector length of the first successful answer of the run.
    var dimensions: Int? {
        state.withLock { $0.dimensions }
    }

    /// `false` once a stop was requested or the run was aborted.
    var acceptsNewRequests: Bool {
        state.withLock { !$0.stopRequested && $0.abort == nil }
    }

    /// Records a received vector. The first one fixes the run's dimension;
    /// returns `false` for a vector whose length differs from it.
    func recordVector(length: Int) -> Bool {
        state.withLock { state in
            guard length > 0 else { return false }
            guard let dimensions = state.dimensions else {
                state.dimensions = length
                state.hasSucceeded = true
                return true
            }
            guard dimensions == length else { return false }
            state.hasSucceeded = true
            return true
        }
    }

    /// Records an entry that failed for good, aborting the run on a rejected
    /// endpoint or when the first ``MemoryReembedding/Options/probeEntryCount``
    /// entries all failed.
    func recordFailure(_ kind: MemoryReembedding.FailureKind, summary: String) {
        let probeEntryCount = options.probeEntryCount
        state.withLock { state in
            guard state.abort == nil else { return }
            if case let .endpointRejected(status) = kind {
                state.abort = .endpointRejected(status: status)
                return
            }
            guard !state.hasSucceeded else { return }
            state.failuresBeforeFirstSuccess += 1
            if probeEntryCount > 0, state.failuresBeforeFirstSuccess >= probeEntryCount {
                state.abort = .initialRequestsFailed(
                    count: state.failuresBeforeFirstSuccess,
                    lastFailure: summary
                )
            }
        }
    }

    /// Waits before a retry. Without an injected sleep it waits in slices of
    /// at most 100 ms and returns early once no new request may start.
    func waitBeforeRetry(_ delay: Duration) async throws {
        if let sleep = options.sleep {
            try await sleep(delay)
            return
        }
        let slice: Duration = .milliseconds(100)
        var remaining = delay
        while remaining > .zero, acceptsNewRequests {
            let step = min(slice, remaining)
            try await Task.sleep(for: step)
            remaining -= step
        }
    }
}
