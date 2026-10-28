//
//  MemoryEngine+Diagnostics.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization

enum MemoryIntelligenceFailurePolicy: String, Codable, Sendable, Equatable {
    /// Fall back to direct lexical retrieval / score-based selection if an analyzer or selector fails.
    case fallback
    /// Surface intelligence-layer errors to the caller.
    case propagate
}

/// How the lexical and semantic rankings are merged into retrieval seeds.
enum MemoryRankFusion: String, Codable, Sendable, Equatable {
    /// Reciprocal-rank fusion: every ranking contributes `1 / (k + rank)`.
    /// With the conventional `k = 60` the contributions are nearly flat, so an
    /// entry present in two rankings outranks the top hit of either one — on a
    /// real graph this displaced exact lexical hits whenever the semantic
    /// ranking was long and noisy. Kept as a measured reference.
    case reciprocalRank
    /// Max-normalised score fusion (CombSUM): every ranking's scores are
    /// divided by that ranking's top score and the normalised scores are
    /// summed, so a dominant hit of a single ranking keeps its rank. The
    /// default.
    case normalizedScore
}

struct MemoryEngineConfiguration: Sendable, Equatable {
    /// Absolute floor on the raw cosine of a semantic hit.
    public var similarityThreshold: Float
    /// A semantic hit must also stand out from the prompt's similarity
    /// distribution by at least this many standard deviations; `0` keeps every
    /// hit above `similarityThreshold` (see ``MemorySearch/semantic``).
    public var semanticMinimumZScore: Float
    /// How lexical and semantic rankings are merged into retrieval seeds.
    public var fusion: MemoryRankFusion
    public var maxSemanticHits: Int
    public var maxLexicalHits: Int
    public var maxAnalyzedQueries: Int
    public var maxSemanticQueries: Int
    public var maxCandidateResults: Int
    public var maxDepth: Int
    public var maxResults: Int
    public var edgeDecay: Float
    public var rrfRankConstant: Float
    public var boostSelectedBy: Float
    /// Permanent confidence loss for a candidate that was retrieved but not
    /// selected. Off by default: with the age discount and relevance deciding
    /// the ranking, a per-recall penalty would only erode entries that often
    /// appear near a prompt without being chosen.
    public var decayRejectedBy: Float
    public var strengthenCoRelevantLinks: Bool
    /// Birth weight, reinforcement and per-memory cap of the co-relevance links
    /// that ``strengthenCoRelevantLinks`` maintains. Part of the configuration
    /// so a replayed maintenance batch applies the policy it was recorded with.
    public var relationPolicy: MemoryRelationPolicy
    public var includeOriginalQuery: Bool
    public var intelligenceFailurePolicy: MemoryIntelligenceFailurePolicy
    /// Age discount applied to retrieval scores (see ``MemoryAgePolicy``).
    public var agePolicy: MemoryAgePolicy
    /// Number of automatic recalls whose derived maintenance may stay in
    /// memory before a durable checkpoint. Explicit mutations checkpoint them
    /// as part of their own immediate transaction.
    public var recallMaintenanceCheckpointSize: Int

    public init(
        similarityThreshold: Float = 0.4,
        semanticMinimumZScore: Float = 2.5,
        fusion: MemoryRankFusion = .normalizedScore,
        maxSemanticHits: Int = 10,
        maxLexicalHits: Int = 10,
        maxAnalyzedQueries: Int = 4,
        maxSemanticQueries: Int = 1,
        maxCandidateResults: Int = 20,
        maxDepth: Int = 2,
        maxResults: Int = 8,
        edgeDecay: Float = 0.7,
        rrfRankConstant: Float = 60,
        boostSelectedBy: Float = 0.02,
        decayRejectedBy: Float = 0,
        strengthenCoRelevantLinks: Bool = true,
        relationPolicy: MemoryRelationPolicy = .default,
        includeOriginalQuery: Bool = true,
        intelligenceFailurePolicy: MemoryIntelligenceFailurePolicy = .fallback,
        agePolicy: MemoryAgePolicy = .default,
        recallMaintenanceCheckpointSize: Int = 4
    ) {
        self.similarityThreshold = similarityThreshold
        self.semanticMinimumZScore = max(0, semanticMinimumZScore)
        self.fusion = fusion
        self.maxSemanticHits = maxSemanticHits
        self.maxLexicalHits = maxLexicalHits
        self.maxAnalyzedQueries = max(1, maxAnalyzedQueries)
        self.maxSemanticQueries = max(0, maxSemanticQueries)
        self.maxCandidateResults = max(1, maxCandidateResults)
        self.maxDepth = max(0, maxDepth)
        self.maxResults = max(0, maxResults)
        self.edgeDecay = edgeDecay
        self.rrfRankConstant = rrfRankConstant
        self.boostSelectedBy = boostSelectedBy
        self.decayRejectedBy = decayRejectedBy
        self.strengthenCoRelevantLinks = strengthenCoRelevantLinks
        self.relationPolicy = relationPolicy
        self.includeOriginalQuery = includeOriginalQuery
        self.intelligenceFailurePolicy = intelligenceFailurePolicy
        self.agePolicy = agePolicy
        self.recallMaintenanceCheckpointSize = max(1, recallMaintenanceCheckpointSize)
    }
}

/// Visible, redacted diagnostic emission for semantic embedding failures.
///
/// ``ZenLogger`` is opt-in (`ZENCODE_LOG`), so this always delivers one redacted
/// ERROR line to an installed presentation sink or the preserved stderr
/// descriptor (never stdout), plus an opt-in system-log copy; the channels are
/// distinct by design. `stderrWriter` is a test seam for the fallback emission.
enum MemorySemanticFallbackDiagnostics {
    typealias VisibleErrorSink = @Sendable (String) -> Void

    private struct SinkRegistration: Sendable {
        let token: UUID
        let sink: VisibleErrorSink
    }

    /// Process-wide presentation override used only while a TUI session is
    /// running. Registrations form a stack so overlapping owners cannot remove
    /// a newer sink when an older session tears down.
    private static let visibleErrorSinks = Mutex<[SinkRegistration]>([])

    /// The visible line, with a trailing newline for the raw descriptor.
    static func visibleLine(message: String, level: ZenLogLevel = .error) -> String {
        ZenLogger.formattedMessage(level: level, category: .memory, message: message) + "\n"
    }

    static func emitVisibleError(
        message: String,
        stderrWriter: ((Data) throws -> Void)? = nil
    ) {
        emitVisible(level: .error, message: message, stderrWriter: stderrWriter)
    }

    /// Same channels as ``emitVisibleError(message:stderrWriter:)`` at warning
    /// level: for degradations that keep working — recall paused, a semantic
    /// bound missed — which the operator should still see once.
    static func emitVisibleWarning(
        message: String,
        stderrWriter: ((Data) throws -> Void)? = nil
    ) {
        emitVisible(level: .warning, message: message, stderrWriter: stderrWriter)
    }

    private static func emitVisible(
        level: ZenLogLevel,
        message: String,
        stderrWriter: ((Data) throws -> Void)?
    ) {
        let line = visibleLine(message: message, level: level)
        let data = Data(line.utf8)
        if let stderrWriter {
            try? stderrWriter(data)
        } else if let sink = visibleErrorSinks.withLock({ $0.last?.sink }) {
            sink(line)
        } else if !AppStorageDirectory.isRunningUnderTestHarness {
            // The raw descriptor is the production fallback; under the test
            // harness a line nobody captures would only clutter the runner's
            // output (the writer seam above stays available to tests).
            try? AgentOutput.standardError.write(contentsOf: data)
        }
        // Opt-in system-log copy, separate from the always-written visible line.
        if level == .warning {
            ZenLogger.warning(.memory, message)
        } else {
            ZenLogger.error(.memory, message)
        }
    }

    /// Redirects terminal-visible diagnostics; the token scopes teardown so one
    /// TUI session cannot remove another session's sink.
    @discardableResult
    static func installVisibleErrorSink(
        _ sink: @escaping VisibleErrorSink
    ) -> UUID {
        let token = UUID()
        visibleErrorSinks.withLock { registrations in
            registrations.append(SinkRegistration(token: token, sink: sink))
        }
        return token
    }

    static func removeVisibleErrorSink(token: UUID) {
        visibleErrorSinks.withLock { registrations in
            registrations.removeAll { $0.token == token }
        }
    }

    /// Short, secret-free summary of an embedding failure: only stable
    /// status/type information, never query/memory text, vectors, endpoint URLs,
    /// response bodies or API keys.
    static func embeddingFailureSummary(_ error: (any Error)?) -> String {
        guard let error else { return "unknown" }
        if let embeddingError = error as? OpenAICompatibleEmbeddingError {
            switch embeddingError {
            case .httpStatus(let status, _):
                return "httpStatus \(status)"
            case .emptyEmbedding:
                return "emptyEmbedding"
            case .responseBodyTooLarge:
                return "responseBodyTooLarge"
            }
        }
        if let urlError = error as? URLError {
            return "transportError \(urlError.code.rawValue)"
        }
        return "\(type(of: error))"
    }

    /// Redacted diagnostic for a mutation that keeps the text but drops its
    /// unavailable vector. `operation` is a fixed call-site label, never user content.
    static func mutationFallbackMessage(
        operation: String,
        error: (any Error)?
    ) -> String {
        "semantic embedding \(operation) failed (\(embeddingFailureSummary(error))); continuing without vector with BM25-only retrieval."
    }
}

/// Best-effort embedding seam for memory mutations: embeddings never gate
/// durable memory, so a provider outage degrades an entry to its text/search
/// index while preserving cancellation semantics. The caller supplies the
/// diagnostic sink so tests can capture messages.
enum MemoryEmbeddingFallback {
    struct Result: Sendable {
        let values: [Float]?
        let model: String?
    }

    static let defaultReporter: @Sendable (String) -> Void = { message in
        MemorySemanticFallbackDiagnostics.emitVisibleError(message: message)
    }

    static func embed(
        _ text: String,
        with embedder: (any EmbeddingProvider)?,
        operation: String,
        reporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) async throws -> Result {
        guard let embedder else {
            return Result(values: nil, model: nil)
        }

        do {
            return Result(
                values: try await embedder.embed(text),
                model: embedder.modelID
            )
        } catch let cancellation as CancellationError {
            // A caller cancellation must not be mistaken for an endpoint
            // outage and silently commit a mutation.
            throw cancellation
        } catch {
            // Cancellation may surface as another error type (e.g.
            // URLError.cancelled); preserve it, degrade only real endpoint failures.
            try Task.checkCancellation()
            reporter(
                MemorySemanticFallbackDiagnostics.mutationFallbackMessage(
                    operation: operation,
                    error: error
                )
            )
            return Result(values: nil, model: nil)
        }
    }
}
