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
    /// Edges the graph cascade follows from a retrieval seed; `0` (default)
    /// turns the expansion off, the graph itself stays persisted and maintained.
    /// On a real graph depth 2 added 41 graph-only selections, none relevant:
    /// depth 0 gave precision 0.25 (was 0.16) and MRR 0.57 (was 0.55); see
    /// Docs/memory.md.
    public var maxDepth: Int
    public var maxResults: Int
    public var edgeDecay: Float
    /// Whether the graph cascade may raise the score of an entry that is
    /// already a retrieval seed. `false` keeps every seed at its own score:
    /// only entries reached solely through the graph take a propagated one.
    /// Inert while ``maxDepth`` is `0` (nothing is propagated); kept as a
    /// measurable reference for a cascade that is turned back on.
    public var cascadeRaisesSeeds: Bool
    /// Upper bound on the entries *selected* that are not retrieval seeds
    /// (reached only through the graph, also via a shared tag or cluster);
    /// `nil` is unbounded. The candidates are not affected: the cap acts on
    /// the selection only, and freed slots go to the next candidates.
    /// Inert while ``maxDepth`` is `0` (every candidate is a seed); kept as a
    /// measurable reference for a cascade that is turned back on.
    public var maxGraphOnlySelections: Int?
    /// Minimum lexical evidence a retrieval seed needs to be *selected*, as a
    /// fraction of the strongest evidence a single query term can give in the
    /// corpus the BM25 ranks: the effective threshold is
    /// `ratio × idfMax(n)`, where `idfMax(n)` is the BM25 IDF of a term found
    /// in a single one of the `n` active entries of the retrieval scope (see
    /// ``MemoryLexicalCorpus/maximumInverseDocumentFrequency(documentCount:)``)
    /// and the evidence of an entry is the sum of the IDF of the distinct query
    /// terms it contains (``MemoryCandidateEvidence/lexical``).
    ///
    /// It is relative because an absolute IDF depends on the size of the
    /// corpus: a term in one entry is worth 5.46 among 353 entries but at most
    /// 2.64 among 20, so a fixed threshold of 3 would empty the recall of any
    /// small project. The default `0.55` is about 3 on a 353-entry graph. With
    /// no active entry in the scope (`n = 0`) the lexical rule selects nothing.
    ///
    /// `nil` asks only for some shared term (evidence > 0). Acts on the
    /// selection only; the candidates are not affected. With this and the two
    /// cosine thresholds all `nil` (the cosine ones count as `nil` for a model
    /// outside ``recallSemanticThresholdModels``) the recall gate is off.
    public var recallMinimumLexicalEvidenceRatio: Float?
    /// Minimum raw cosine to the first query embedding a seed needs to be
    /// *selected* through the semantic path. `nil` accepts the hits that passed
    /// the semantic gate (z-score). The default `0.55` was measured on
    /// `qwen/qwen3-embedding-8b` only: it applies when the embedder's model is
    /// in ``recallSemanticThresholdModels`` and counts as `nil` otherwise.
    /// Ignored when no semantic search ran for the prompt (no embedder,
    /// `includeSemantic` off, endpoint failure).
    public var recallMinimumSemanticSimilarity: Float?
    /// Minimum raw cosine a *lexically supported* seed needs to be selected:
    /// an entry with enough lexical evidence (``recallMinimumLexicalEvidenceRatio``)
    /// is kept only if its cosine to the first query embedding is at least
    /// this value, so a lot of shared vocabulary cannot carry an entry that
    /// sits far from the query in the embedding space. An entry whose cosine
    /// reaches ``recallMinimumSemanticSimilarity`` (or, with none, that passed
    /// the semantic gate) is selected regardless of this value. `nil` puts no
    /// floor on the cosine of a lexically supported entry. Like the other
    /// cosine threshold the default `0.45` was measured on
    /// `qwen/qwen3-embedding-8b` only and counts as `nil` for a model outside
    /// ``recallSemanticThresholdModels``. It only applies to an entry that has
    /// a vector of the embedder's model while the semantic search ran for the
    /// prompt: otherwise the lexical evidence alone decides.
    public var recallLexicalSupportMinimumSimilarity: Float?
    /// The embedding models whose raw cosines the two cosine thresholds
    /// (``recallMinimumSemanticSimilarity``, ``recallLexicalSupportMinimumSimilarity``)
    /// were measured on, compared case-insensitively with the embedder's
    /// `modelID`. For any other model the raw cosine scale is different (an
    /// anisotropic baseline of 0.35–0.45 for one model may be 0.7 for
    /// another), so both thresholds count as `nil` and a hit that passed the
    /// semantic z-score gate is what counts as semantic support. An empty set
    /// means *never*; to apply the thresholds to every model use an explicit
    /// `["*"]`. Default `["qwen/qwen3-embedding-8b"]`.
    public var recallSemanticThresholdModels: Set<String>
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

    /// The measured defaults of the recall evidence gate (see
    /// ``recallMinimumLexicalEvidenceRatio``, ``recallMinimumSemanticSimilarity``,
    /// ``recallLexicalSupportMinimumSimilarity`` and ``recallSemanticThresholdModels``).
    public static let defaultRecallMinimumLexicalEvidenceRatio: Float = 0.55
    public static let defaultRecallMinimumSemanticSimilarity: Float = 0.55
    public static let defaultRecallLexicalSupportMinimumSimilarity: Float = 0.45
    public static let defaultRecallSemanticThresholdModels: Set<String> = ["qwen/qwen3-embedding-8b"]
    /// The entry of ``recallSemanticThresholdModels`` that matches every model.
    public static let anyEmbeddingModel = "*"

    /// Whether the cosine thresholds apply to an embedder whose model is
    /// `modelID`: it must be in ``recallSemanticThresholdModels``
    /// (case-insensitive, surrounding whitespace ignored) or the set must
    /// contain ``anyEmbeddingModel``. An empty set never applies them.
    func appliesSemanticThresholds(toModelID modelID: String?) -> Bool {
        guard let modelID else { return false }
        let wanted = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recallSemanticThresholdModels.contains { entry in
            let normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == Self.anyEmbeddingModel || normalized.lowercased() == wanted
        }
    }

    public init(
        similarityThreshold: Float = 0.4,
        semanticMinimumZScore: Float = 2.5,
        fusion: MemoryRankFusion = .normalizedScore,
        maxSemanticHits: Int = 10,
        maxLexicalHits: Int = 10,
        maxAnalyzedQueries: Int = 4,
        maxSemanticQueries: Int = 1,
        maxCandidateResults: Int = 20,
        maxDepth: Int = 0,
        maxResults: Int = 8,
        edgeDecay: Float = 0.7,
        cascadeRaisesSeeds: Bool = true,
        maxGraphOnlySelections: Int? = nil,
        recallMinimumLexicalEvidenceRatio: Float? = Self.defaultRecallMinimumLexicalEvidenceRatio,
        recallMinimumSemanticSimilarity: Float? = Self.defaultRecallMinimumSemanticSimilarity,
        recallLexicalSupportMinimumSimilarity: Float? = Self.defaultRecallLexicalSupportMinimumSimilarity,
        recallSemanticThresholdModels: Set<String> = Self.defaultRecallSemanticThresholdModels,
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
        self.cascadeRaisesSeeds = cascadeRaisesSeeds
        self.maxGraphOnlySelections = maxGraphOnlySelections.map { max(0, $0) }
        self.recallMinimumLexicalEvidenceRatio = recallMinimumLexicalEvidenceRatio.map { max(0, $0) }
        self.recallMinimumSemanticSimilarity = recallMinimumSemanticSimilarity
        self.recallLexicalSupportMinimumSimilarity = recallLexicalSupportMinimumSimilarity
        self.recallSemanticThresholdModels = recallSemanticThresholdModels
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
package enum MemorySemanticFallbackDiagnostics {
    package typealias VisibleErrorSink = @Sendable (String) -> Void

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
    package static func installVisibleErrorSink(
        _ sink: @escaping VisibleErrorSink
    ) -> UUID {
        let token = UUID()
        visibleErrorSinks.withLock { registrations in
            registrations.append(SinkRegistration(token: token, sink: sink))
        }
        return token
    }

    package static func removeVisibleErrorSink(token: UUID) {
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
