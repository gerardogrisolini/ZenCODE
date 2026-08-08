//
//  MemoryAutomationSettings.swift
//  ZenCODE
//
//  Environment gates for automatic memory recall and extraction.
//

import Foundation
import ToolCore
import ZenMemory

/// Environment-driven configuration for the automatic memory pipeline.
///
/// These gates deliberately live in the environment, beside the existing
/// ``MemoryEmbedding`` keys, and follow the same endpoint/model/API-key naming
/// convention. They are NOT settings-manifest fields: the memory subsystem has
/// no manifest presence at all today, so adding fields would force a manifest
/// version bump (and its migration) for what is a per-machine operational
/// switch rather than per-workspace configuration.
///
/// Defaults are asymmetric on purpose:
///
/// - Recall is **on**. It is pure local retrieval — offline BM25 over a graph
///   that is already loaded — so it makes no LLM call of its own and it is
///   bounded by ``recallTimeout`` so it can never stall a turn. It is not
///   free, though: the block it injects is part of the request the turn sends,
///   so it is paid in prompt tokens of the main model, which is what
///   ``recallBudgetCharacters`` bounds.
/// - Extraction is **off**, and stays off unless it is *double-gated* by an
///   explicit opt-in **and** a configured side model. It spends real tokens on
///   a second model call after every completed turn, so it must never switch
///   itself on merely because a provider happens to be configured.
enum MemoryAutomationSettings {
    /// Enables automatic recall. Absent ⇒ true.
    static let environmentAutoRecallKey = "ZENCODE_MEMORY_AUTO_RECALL"
    /// Enables automatic extraction. Absent ⇒ false. Also requires a side
    /// model, so this alone is not sufficient.
    static let environmentAutoExtractKey = "ZENCODE_MEMORY_AUTO_EXTRACT"
    /// Either an OpenAI-compatible model name (paired with
    /// ``environmentSideModelEndpointKey``) or, on its own, a ZenCODE model id
    /// routed through ZenCODE's own generation stack.
    static let environmentSideModelKey = "ZENCODE_MEMORY_SIDE_MODEL"
    /// OpenAI-compatible `/v1/chat/completions` route for the side model.
    static let environmentSideModelEndpointKey = "ZENCODE_MEMORY_SIDE_MODEL_ENDPOINT"
    /// Optional bearer key for ``environmentSideModelEndpointKey``.
    static let environmentSideModelAPIKeyKey = "ZENCODE_MEMORY_SIDE_MODEL_API_KEY"
    /// Upper bound, in milliseconds, on how long a turn may wait for recall.
    static let environmentRecallTimeoutKey = "ZENCODE_MEMORY_RECALL_TIMEOUT_MS"
    /// Upper bound, in characters, on the recalled payload of the injected
    /// block.
    static let environmentRecallBudgetKey = "ZENCODE_MEMORY_RECALL_MAX_CHARACTERS"
    /// Upper bound, in characters, on the transcript handed to the extractor.
    static let environmentExtractionBudgetKey = "ZENCODE_MEMORY_EXTRACT_MAX_CHARACTERS"

    /// Retrieval is offline BM25 over an in-memory graph, which is
    /// sub-millisecond, so the budget only has to absorb scheduling jitter.
    /// It is deliberately far too small to cover a *cold* graph open: opening
    /// (and, once per workspace, migrating `MEMORY.md`) can exceed it, in which
    /// case the first turn silently gets no block and later turns are served
    /// from the registry's cached store. Never delaying a turn outranks
    /// injecting memory on the very first prompt.
    static let defaultRecallTimeoutMilliseconds = 150
    /// Hard bounds so a mistyped value cannot defeat the latency guarantee.
    static let minimumRecallTimeoutMilliseconds = 10
    static let maximumRecallTimeoutMilliseconds = 5_000

    /// Budgets are expressed in **characters**, not tokens, because characters
    /// are the only unit available here that is exact, provider-independent and
    /// identical on every run: a token count would need a tokenizer ZenCODE does
    /// not carry for every provider, and an estimated one would make the size of
    /// an injected block depend on which estimator happened to run. Four
    /// characters per token is the conventional rough ratio, so the defaults
    /// below are ~1k tokens of recalled memory and ~1.5k tokens of extraction
    /// input; ``approximateTokens(forCharacters:)`` exposes that conversion for
    /// logs and documentation without ever driving the truncation itself.
    static let charactersPerApproximateToken = 4

    /// Bounds the recalled payload merged into the outgoing user message.
    /// Retrieval is already selection-limited, but the selector's output is a
    /// function of the graph, so without a budget a large workspace could push
    /// an arbitrarily long block into every request.
    static let defaultRecallBudgetCharacters = 4_000
    static let minimumRecallBudgetCharacters = 200
    static let maximumRecallBudgetCharacters = 32_000

    /// Bounds the transcript handed to the side model. Extraction spends real
    /// tokens, and the exchange it summarizes can legitimately contain a pasted
    /// file or a long answer.
    static let defaultExtractionBudgetCharacters = 6_000
    static let minimumExtractionBudgetCharacters = 200
    static let maximumExtractionBudgetCharacters = 64_000

    /// Automatic recall is enabled unless explicitly switched off.
    static var isAutoRecallEnabled: Bool {
        boolean(forKey: environmentAutoRecallKey, default: true)
    }

    /// The explicit half of the extraction gate. Exposed separately so a
    /// diagnostic can distinguish "not opted in" from "opted in but no side
    /// model configured".
    static var isAutoExtractionOptedIn: Bool {
        boolean(forKey: environmentAutoExtractKey, default: false)
    }

    /// Automatic extraction requires BOTH an explicit opt-in AND a configured
    /// side model. Either alone leaves extraction off, in which case the engine
    /// keeps its `NoopMemoryExtractor` and `learn(from:)` is a genuine no-op.
    static var isAutoExtractionEnabled: Bool {
        isAutoExtractionOptedIn && isSideModelConfigured
    }

    /// Lexically scoped side model, used instead of environment resolution for
    /// the duration of an operation.
    ///
    /// This is the injection seam for tests and embedders: extraction is
    /// double-gated on a *configured side model*, so exercising the enabled
    /// path any other way would require a reachable HTTP endpoint. A task-local
    /// is used rather than a mutable global for the same reason
    /// ``AppStorageDirectory/withSupportDirectoryURL(_:operation:)`` is: it is
    /// inherited by the tasks the pipeline spawns, and it cannot leak into a
    /// concurrently running caller.
    @TaskLocal static var scopedSideModel: (any MemoryLanguageModel)?

    /// Whether a side model is configured at all, without building one.
    static var isSideModelConfigured: Bool {
        scopedSideModel != nil || environment[environmentSideModelKey]?.nilIfBlank != nil
    }

    /// Builds the configured side model, or `nil` when none is configured.
    ///
    /// Two shapes are supported, and the endpoint decides which:
    ///
    /// - endpoint **+** model ⇒ ZenMemory's own `OpenAICompatibleChatModel`,
    ///   which talks straight to a `/v1/chat/completions` route. Cheapest path,
    ///   and it keeps a dedicated small model out of ZenCODE's provider config.
    /// - model **only** ⇒ ``MemoryGenerationLanguageModel``, which routes
    ///   through ZenCODE's own generation stack so any configured provider
    ///   works, including the ChatGPT and Anthropic subscription ones that have
    ///   no bearer-key chat-completions route at all.
    ///
    /// `workspaceRootURL` is required for the second shape: the generation
    /// stack needs a working directory for its ephemeral session. Callers
    /// always have one, because a memory graph is per workspace.
    ///
    /// ``scopedSideModel`` wins over both shapes when it is bound.
    ///
    /// Whatever is resolved is returned wrapped in
    /// ``CancellationGuardedMemoryModel``, so no shape — including an injected
    /// one — can answer a cancelled extraction.
    static func sideModel(workspaceRootURL: URL) -> (any MemoryLanguageModel)? {
        guard let resolved = resolvedSideModel(workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        return CancellationGuardedMemoryModel(base: resolved)
    }

    private static func resolvedSideModel(
        workspaceRootURL: URL
    ) -> (any MemoryLanguageModel)? {
        if let scopedSideModel {
            return scopedSideModel
        }
        guard let model = environment[environmentSideModelKey]?.nilIfBlank else {
            return nil
        }
        guard let rawEndpoint = environment[environmentSideModelEndpointKey]?.nilIfBlank,
              let endpoint = URL(string: rawEndpoint) else {
            return MemoryGenerationLanguageModel(
                modelID: model,
                workspaceRootURL: workspaceRootURL
            )
        }
        return OpenAICompatibleChatModel(
            endpoint: endpoint,
            model: model,
            apiKey: environment[environmentSideModelAPIKeyKey]?.nilIfBlank
        )
    }

    static var recallTimeout: Duration {
        .milliseconds(recallTimeoutMilliseconds)
    }

    static var recallTimeoutMilliseconds: Int {
        guard let raw = environment[environmentRecallTimeoutKey]?.nilIfBlank,
              let parsed = Int(raw) else {
            return defaultRecallTimeoutMilliseconds
        }
        return min(
            max(parsed, minimumRecallTimeoutMilliseconds),
            maximumRecallTimeoutMilliseconds
        )
    }

    static var recallBudgetCharacters: Int {
        clampedInteger(
            forKey: environmentRecallBudgetKey,
            default: defaultRecallBudgetCharacters,
            minimum: minimumRecallBudgetCharacters,
            maximum: maximumRecallBudgetCharacters
        )
    }

    static var extractionBudgetCharacters: Int {
        clampedInteger(
            forKey: environmentExtractionBudgetKey,
            default: defaultExtractionBudgetCharacters,
            minimum: minimumExtractionBudgetCharacters,
            maximum: maximumExtractionBudgetCharacters
        )
    }

    /// Conventional 4-characters-per-token estimate. Reporting only: no
    /// truncation decision is ever taken from this value.
    static func approximateTokens(forCharacters characters: Int) -> Int {
        max(characters, 0) / charactersPerApproximateToken
    }

    /// Reads a bounded integer, falling back to the default on anything that is
    /// absent or unparseable, so a mistyped value cannot defeat a budget.
    private static func clampedInteger(
        forKey key: String,
        default defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard let raw = environment[key]?.nilIfBlank,
              let parsed = Int(raw) else {
            return defaultValue
        }
        return min(max(parsed, minimum), maximum)
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Accepts the usual shell spellings on both sides. An unrecognized value
    /// falls back to the default rather than guessing, so a typo can never
    /// silently enable extraction.
    private static func boolean(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let raw = environment[key]?.nilIfBlank?.lowercased() else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "y", "on", "enabled":
            return true
        case "0", "false", "no", "n", "off", "disabled":
            return false
        default:
            return defaultValue
        }
    }
}

/// A side model that refuses to serve a cancelled extraction.
///
/// This exists because of where the seam *isn't*. ``MemoryGraphStore/learn(from:)``
/// calls the extractor and commits what it returns inside a single engine
/// transaction, so ``MemoryTurnCoordinator`` has no point between "the side
/// model answered" and "the entries are on disk" at which it could re-check
/// cancellation. Wrapping the model puts that check on the only boundary that
/// sits between the two.
///
/// It matters because cancellation is cooperative and a side model is the one
/// participant that may not cooperate: a blocking SDK, a request already on the
/// wire, an implementation that never looks at `Task.isCancelled`. Without this
/// guard such a model would answer after its session was closed or reset and
/// the store would happily commit memories for a conversation that no longer
/// exists.
///
/// Both ends are checked. Before the call, so a cancelled extraction never
/// spends a token; after it, so a late answer is dropped. Throwing rather than
/// returning an empty string is deliberate: `LLMMemoryExtractor` propagates the
/// error, and `learn(from:)` therefore fails before it prepares a single entry,
/// instead of "successfully extracting nothing" and hiding the abort.
struct CancellationGuardedMemoryModel: MemoryLanguageModel {
    let base: any MemoryLanguageModel

    func complete(system: String, user: String) async throws -> String {
        try Task.checkCancellation()
        let response = try await base.complete(system: system, user: user)
        try Task.checkCancellation()
        return response
    }
}
