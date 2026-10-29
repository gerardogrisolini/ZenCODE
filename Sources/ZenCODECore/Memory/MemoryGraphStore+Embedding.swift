//
//  MemoryGraphStore+Embedding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

// MARK: - Embeddings

enum MemoryEmbedding {
    static let environmentEndpointKey = "ZENCODE_MEMORY_EMBEDDING_ENDPOINT"

    /// Task-local override for provider resolution. Tests must never reach a real
    /// embedding endpoint just because the shell exports
    /// `ZENCODE_MEMORY_EMBEDDING_ENDPOINT`; a `setenv` override would be
    /// process-global and racy, so the seam is a task-local (inherited by the
    /// `Task` `MemoryGraphStoreRegistry` uses to open the engine).
    ///
    /// The double optional has three states: `nil` (unbound) resolves from
    /// persisted settings then the legacy environment variable (production);
    /// `.some(nil)` forces "no provider"; `.some(provider)` forces that provider.
    @TaskLocal static var override: (any EmbeddingProvider)?? = nil

    /// Runs `operation` with a forced provider resolution (`nil` forces "no
    /// provider": no environment lookup, no network).
    static func withProvider<T: Sendable>(
        _ provider: (any EmbeddingProvider)?,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $override.withValue(Optional(provider)) {
            try await operation()
        }
    }

    /// Embeddings are opt-in: with no provider, recall uses pure BM25 and entries
    /// store no vector. An OpenAI-compatible provider can be enabled through the
    /// persisted endpoint or the legacy environment endpoint without changing the
    /// graph format: entries record an identity derived from the endpoint and the
    /// engine only compares vectors from a matching identity, so an endpoint
    /// change degrades to BM25 instead of returning wrong matches.
    ///
    /// A bound task-local override (``withProvider(_:operation:)``) takes
    /// precedence. Under a test harness the real process environment is never
    /// consulted; use the override or the `provider(manifest:environment:)` seam.
    static func provider() -> (any EmbeddingProvider)? {
        switch override {
        case .none:
            guard !AppStorageDirectory.isRunningUnderTestHarness else {
                return nil
            }
            return provider(
                manifest: AgentSettingsManifestStore.load(),
                environment: ProcessInfo.processInfo.environment
            )
        case .some(let forced):
            return forced
        }
    }

    /// Resolves an embedding provider without I/O. This explicit seam keeps the
    /// precedence testable while `provider()` remains safe under a test harness.
    ///
    /// Resolution order: task-local override > manifest (endpoint or disabled) >
    /// legacy environment fallback (only when the manifest field is absent) > BM25.
    static func provider(
        manifest: AgentSettingsManifest?,
        environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        switch override {
        case .some(let forced):
            return forced
        case .none:
            return providerFromSettings(manifest, environment)
        }
    }

    private static func providerFromSettings(
        _ manifest: AgentSettingsManifest?,
        _ environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        // A present memoryEmbedding field takes precedence over the environment.
        if let settings = manifest?.memoryEmbedding {
            if settings.isExplicitlyDisabled {
                // Explicit BM25: no provider and no environment fallback.
                return nil
            }
            if let endpoint = settings.endpointURL {
                return OpenAICompatibleEmbeddingProvider(
                    endpoint: endpoint,
                    model: settings.model,
                    apiKey: providerAPIKey(
                        manifest: manifest,
                        providerID: settings.providerID,
                        endpoint: endpoint
                    )
                )
            }
            // endpoint present but invalid: degrade to absent and try the env.
        }
        // Field absent (or invalid endpoint): legacy environment fallback.
        return providerFromEnvironment(environment)
    }

    /// Derives the embedding Authorization key from the provider referenced by
    /// `providerID` (set only by the OpenRouter preset) without duplicating the
    /// secret in the embeddings manifest. The key is reused only when the
    /// reference resolves to a provider in the manifest, that provider is
    /// OpenRouter, and the embedding endpoint is itself an OpenRouter endpoint;
    /// any other combination yields no key, so an edited `settings.json` can never
    /// forward an OpenRouter key to an arbitrary host.
    private static func providerAPIKey(
        manifest: AgentSettingsManifest?,
        providerID: String?,
        endpoint: URL
    ) -> String? {
        guard let providerID,
              let manifest,
              let provider = manifest.providers.first(where: { $0.id == providerID }),
              AgentRemoteProvider.isOpenRouterBaseURL(provider.baseURL),
              AgentRemoteProvider.isOpenRouterBaseURL(endpoint.absoluteString) else {
            return nil
        }
        return provider.authPolicy.effectiveAPIKey(
            manifest.apiKey(providerID: providerID)
        )
    }

    private static func providerFromEnvironment(
        _ environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        guard let rawEndpoint = environment[environmentEndpointKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEndpoint.isEmpty,
              let endpoint = AgentMemoryEmbeddingSettingsManifest.url(for: rawEndpoint) else {
            return nil
        }
        return OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    }
}

// MARK: - Retrieval selection

/// Deterministic, offline score-threshold selector.
///
/// Replaces the engine's default `TopScoreMemorySelector(minimumScore: 0)`, which
/// returns every candidate: every retrieved entry would be boosted and never
/// decayed, and every recall would link all its results pairwise, saturating the
/// graph until cascade retrieval degenerates into noise. This selector keeps
/// only candidates at or above a fraction of the top score (relative, because
/// BM25/cascade scores have no absolute scale), restoring decay for weak
/// candidates. It makes no LLM or network call.
struct ScoreThresholdMemorySelector: MemorySelector {
    /// A candidate is selected when its score is at least this fraction of the
    /// strongest candidate's score (`0.5`: within a factor of two of the best).
    let relativeThreshold: Float

    init(relativeThreshold: Float = 0.5) {
        self.relativeThreshold = relativeThreshold
    }

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard limit > 0 else { return [] }
        // Sort defensively: a selector must not rely on the caller's ordering.
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }
        guard let topScore = ordered.first?.score, topScore > 0 else {
            // No positive top score: the relative threshold cannot
            // discriminate, so fall back to rank order, still honouring `limit`.
            return Array(ordered.prefix(limit))
        }
        let floor = topScore * relativeThreshold
        return ordered.filter { $0.score >= floor }.prefix(limit).map { $0 }
    }
}
