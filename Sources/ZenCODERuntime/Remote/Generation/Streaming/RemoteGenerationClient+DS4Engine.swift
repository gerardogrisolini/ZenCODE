//
//  RemoteGenerationClient+DS4Engine.swift
//  ZenCODE
//
//  Generation through the in-process DS4 engine. When the client has a
//  `DS4LocalGeneration`, `sendPrompt` calls `streamDS4Engine` for each round
//  instead of an HTTP stream; tool rounds, tool execution, history updates,
//  metrics and errors stay in the shared loop.
//
//  One round:
//  1. preparation, outside the generation lease: the engine for the manifest
//     (opened by `preloadModel`), images handled, the current-turn user
//     content frozen, the prompt rendered by `DS4TranscriptRenderer` and
//     tokenized once with the engine tokenizer (`DS4Engine.prepare`: the token
//     count feeds the compaction policy and the same tokenization is synced),
//     the session compacted near the context limit (`DS4CompactionPolicy`,
//     ds4-agent rule) and the system prompt reminder recorded every 50000
//     tokens;
//  2. `DS4EngineRegistry.withGenerationLease` around `sync` + `generate` only:
//     the lease is never held while tools run, so a DS4 sub-agent started by
//     a tool of this turn can take it;
//  3. the generated text is parsed by `DS4GeneratedOutputParser` on the engine
//     thread (inside `onText`, which returns the stop/greedy flags); deltas go
//     through an `AsyncStream` consumed in order by a task calling `onEvent`;
//  4. the result carries a `DS4AssistantTurn` (raw text, the exact token ids
//     the engine committed, the model that produced them, think mode, replays,
//     malformed-call observation) that `appendAssistantMessage` stores in
//     private `ds4_` keys, so the next round re-renders the turn verbatim -
//     with the same token ids, not a new tokenization of its text - and only
//     prefills the new suffix.
//
//  Images. With a vision encoder (`engine_has_vision` and a configured
//  `visionRelativePath`) the images of user messages and tool results stay in
//  the session and are rendered as multimodal messages: `DS4ImageStaging`
//  decodes each one into a temporary file under `<support>/ds4/tmp` for the
//  engine to encode, and the files are deleted as soon as the sync ends (or
//  fails, or is cancelled). An image that cannot be read or encoded is
//  reported and removed from the session. Without a vision encoder the images
//  are removed from the session and reported.
//

import Foundation
import Synchronization
import ToolCore

/// Per-client bookkeeping of the DS4 path.
struct DS4ClientState: Sendable {
    /// Sessions this client synced into the engine (released by
    /// `closeSession` and `shutdown`).
    var engineSessionIDs: Set<String> = []
    /// Compaction reserve (`agent_compact_reserve_tokens`) per engine identity.
    var reserveTokensByIdentity: [String: Int] = [:]
    /// `/ds4 power` and `/ds4 steer` values per session. Runtime only: never
    /// persisted, dropped with the session (`RemoteGenerationClient+DS4Control.swift`).
    var controlsBySessionID: [String: DS4SessionControls] = [:]
    /// `/ds4 hints` preference and note state per session. Runtime only.
    var hintsBySessionID: [String: DS4HintsState] = [:]
}

/// Everything a round needs once its prompt is final.
struct DS4PreparedRound: Sendable {
    let sessionID: String
    /// The tokenized prompt: counted for the policy and synced as is. Release
    /// it when the sync ends.
    let transcript: DS4PreparedTranscript
    let promptTokens: Int
    let maxTokens: Int
    let syntax: DS4ToolSyntax
    let thinkMode: Int32
    let sampling: DS4SamplingParameters
    let parameterTypes: [String: [String: DS4ToolParameterKind]]
    let contextSize: Int
    /// `DS4EngineInfo.tokenIdentity` of the engine that prepared the round:
    /// stored with the token ids the round generates.
    let tokenIdentity: String
    /// Resolves parsed tool calls to their descriptor title and presentation,
    /// like every other provider.
    let toolCatalog: RemoteToolWireCatalog
}

/// Bridges the synchronous `onText` callback (engine thread) to the async
/// event stream: the parser lives behind a `Mutex`, every delta is yielded in
/// order and the parser state decides the emit flags of each token. The live
/// tool-call preview of each call follows the deltas of that call.
final class DS4GenerationBridge: Sendable {
    private struct State {
        var parser: DS4GeneratedOutputParser
        var firstTextAt: Date?
        /// A `toolStarted` preview was yielded and its block's `ended` was not.
        var previewOpen = false
    }

    private let state: Mutex<State>
    private let continuation: AsyncStream<DirectAgentEvent>.Continuation

    init(parser: DS4GeneratedOutputParser, continuation: AsyncStream<DirectAgentEvent>.Continuation) {
        self.state = Mutex(State(parser: parser))
        self.continuation = continuation
    }

    /// `onText`: one call per committed token.
    func consume(_ text: String) -> DS4EmitDecision {
        state.withLock { state in
            if state.firstTextAt == nil {
                state.firstTextAt = Date()
            }
            for delta in state.parser.consume(text) {
                continuation.yield(Self.event(for: delta))
            }
            yieldToolCallPreviews(&state)
            if state.parser.shouldStopGeneration {
                return .stop
            }
            return state.parser.wantsGreedySampling ? .greedy : []
        }
    }

    /// Finishes the parser and yields the deltas it held back.
    func finish() -> DS4ParsedOutput {
        state.withLock { state in
            let output = state.parser.finish()
            for delta in output.finalDeltas {
                continuation.yield(Self.event(for: delta))
            }
            yieldToolCallPreviews(&state)
            return output
        }
    }

    /// Closes a tool-call preview the generation left open: it failed or was
    /// cancelled after a `toolStarted` and before the block's `ended`.
    func endOpenToolCallPreview() {
        state.withLock { state in
            guard state.previewOpen else {
                return
            }
            state.previewOpen = false
            continuation.yield(.toolCallPreview(.ended))
        }
    }

    private func yieldToolCallPreviews(_ state: inout State) {
        for preview in state.parser.drainToolCallPreviews() {
            switch preview {
            case .toolStarted:
                state.previewOpen = true
            case .ended:
                state.previewOpen = false
            case .parameterStarted, .parameterText, .parameterEnded:
                break
            }
            continuation.yield(.toolCallPreview(preview))
        }
    }

    var firstTextAt: Date? {
        state.withLock { $0.firstTextAt }
    }

    private static func event(for delta: DS4ParsedOutputDelta) -> DirectAgentEvent {
        switch delta {
        case let .visible(text):
            .content(text)
        case let .thought(text):
            .thought(text)
        }
    }
}

/// Values produced inside the generation lease.
private struct DS4LeaseResult: Sendable {
    let sync: DS4SyncResult
    let generated: DS4GenerateResult
    let syncStartedAt: Date
    /// Stored `/ds4` controls applied before the sync, if any were pending.
    let controls: DS4ControlApplication?
}

extension RemoteGenerationClient {
    // MARK: - Lifecycle

    /// Opens the engine of the manifest (no-op when already open).
    func preloadDS4Engine(
        _ ds4: DS4LocalGeneration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let configuration = try ds4.engineConfiguration()
        if await ds4.registry.currentIdentity != configuration.identity {
            await onEvent(.status("Loading DS4 model …"))
        }
        let engine = try await ds4.registry.engine(for: configuration) { message in
            await onEvent(.status(message))
        }
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(provider.modelID))
            await onEvent(.contextWindow(DirectAgentContextWindowStatus(
                usedTokens: 0,
                maxTokens: engine.info.contextSize,
                modelID: provider.modelID,
                isApproximate: false
            )))
        }
        return provider.modelID
    }

    /// Frees the engine session of `id` when this client created it.
    func releaseDS4EngineSession(id: String) async {
        // Runtime-only `/ds4` values belong to the session even when it never
        // reached the engine.
        ds4State.controlsBySessionID[id] = nil
        ds4State.hintsBySessionID[id] = nil
        guard let ds4Generation, ds4State.engineSessionIDs.remove(id) != nil else {
            return
        }
        await ds4Generation.registry.releaseSession(id)
    }

    /// Frees every engine session of this client; the engine itself stays open
    /// for the other clients sharing it.
    func releaseDS4EngineSessions() async {
        ds4State.controlsBySessionID.removeAll()
        ds4State.hintsBySessionID.removeAll()
        guard let ds4Generation else {
            return
        }
        let sessionIDs = ds4State.engineSessionIDs.sorted()
        ds4State.engineSessionIDs.removeAll()
        for sessionID in sessionIDs {
            await ds4Generation.registry.releaseSession(sessionID)
        }
    }

    // MARK: - Round

    /// One generation round through the in-process engine.
    func streamDS4Engine(
        _ ds4: DS4LocalGeneration,
        lease: SessionLease,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let configuration = try ds4.engineConfiguration()
        let statusHandler: DS4EngineRegistry.StatusHandler = { message in
            await onEvent(.status(message))
        }
        // Temporary image files of this round: deleted right after the sync
        // that encodes them, and here on every other way out.
        let staging = DS4ImageStaging()
        defer { staging.removeAll() }
        let prepared: DS4PreparedRound
        do {
            prepared = try await prepareDS4Round(
                ds4, configuration: configuration, lease: lease, staging: staging,
                statusHandler: statusHandler, onEvent: onEvent
            )
        } catch DS4EngineError.engineClosed where currentSession(for: lease) != nil {
            // Another model configuration replaced the engine while this round
            // was being prepared: prepare again against the reopened engine.
            prepared = try await prepareDS4Round(
                ds4, configuration: configuration, lease: lease, staging: staging,
                statusHandler: statusHandler, onEvent: onEvent
            )
        }

        let (events, continuation) = AsyncStream<DirectAgentEvent>.makeStream()
        let consumer = Task {
            for await event in events {
                await onEvent(event)
            }
        }
        let bridge = DS4GenerationBridge(
            parser: DS4GeneratedOutputParser(
                syntax: prepared.syntax,
                startsInsideThinking: prepared.syntax.outputStartsInsideThinking(
                    thinkModeEnabled: DS4ThinkModeMapping.isEnabled(prepared.thinkMode)
                ),
                parameterTypes: prepared.parameterTypes
            ),
            continuation: continuation
        )
        let progress = DS4ProgressReporter(continuation: continuation)
        let throughput = DS4ThroughputReporter(continuation: continuation)
        ds4State.engineSessionIDs.insert(prepared.sessionID)
        let requestStartedAt = Date()
        // `/ds4 power|steer` values not yet applied to this engine instance.
        let storedControls = ds4State.controlsBySessionID[prepared.sessionID]

        let leaseResult: DS4LeaseResult
        do {
            leaseResult = try await ds4.registry.withGenerationLease(
                configuration: configuration,
                sessionID: prepared.sessionID,
                onStatus: statusHandler
            ) { engine in
                let controls = await Self.applyDS4Controls(
                    storedControls, to: engine, sessionID: prepared.sessionID
                )
                for warning in controls?.warnings ?? [] {
                    continuation.yield(.diagnostic(warning))
                }
                let syncStartedAt = Date()
                let sync: DS4SyncResult
                do {
                    // The images are encoded once the sync ends (whatever its
                    // outcome): free the token buffer and delete the files
                    // before the generation starts.
                    defer {
                        prepared.transcript.release()
                        staging.removeAll()
                    }
                    sync = try await engine.sync(
                        sessionID: prepared.sessionID,
                        prepared: prepared.transcript
                    ) { event, current, total in
                        progress.report(event: event, current: current, total: total)
                        throughput.reportPrefill(event: event, current: current, total: total)
                    }
                }
                continuation.yield(.diagnostic(
                    "DS4 prefill: \(sync.cached) cached, \(sync.suffix) tokens to evaluate"
                ))
                // The exact prefill speed of the engine, known as soon as the
                // sync has ended: the label keeps it through the generation.
                let syncStats = await engine.stats(sessionID: prepared.sessionID)
                throughput.beginGeneration(
                    prefillTokensPerSecond: Self.ds4PrefillTokensPerSecond(sync: sync, stats: syncStats)
                )
                let generated = try await engine.generate(
                    sessionID: prepared.sessionID,
                    maxTokens: prepared.maxTokens,
                    thinkMode: prepared.thinkMode,
                    sampling: prepared.sampling
                ) { text in
                    throughput.recordGeneratedToken()
                    return bridge.consume(text)
                }
                return DS4LeaseResult(
                    sync: sync, generated: generated, syncStartedAt: syncStartedAt, controls: controls
                )
            }
        } catch {
            // The lease may have failed before the sync ran.
            prepared.transcript.release()
            bridge.endOpenToolCallPreview()
            continuation.finish()
            await consumer.value
            throw error
        }
        if let controls = leaseResult.controls {
            recordDS4ControlApplication(controls, sessionID: prepared.sessionID)
        }
        let parsed = bridge.finish()
        continuation.finish()
        await consumer.value

        let generated = leaseResult.generated
        let sync = leaseResult.sync
        let finishedAt = Date()
        let engineSeconds = generated.stats.prefillSeconds + generated.stats.generationSeconds
        let generatedTokens = generated.stats.generatedTokens
        let position = generated.stats.position > 0 ? generated.stats.position : sync.tokenCount + generatedTokens
        let stats = RemoteGenerationStats(
            usage: RemoteGenerationUsage(
                promptTokens: sync.tokenCount,
                completionTokens: generatedTokens,
                totalTokens: sync.tokenCount + generatedTokens,
                contextTokens: position,
                processedPromptTokens: sync.suffix,
                cachedPromptTokens: sync.cached,
                responseDurationSeconds: engineSeconds > 0
                    ? engineSeconds
                    : finishedAt.timeIntervalSince(leaseResult.syncStartedAt)
            ),
            requestStartedAt: requestStartedAt,
            firstDeltaAt: bridge.firstTextAt,
            finishedAt: finishedAt,
            generatedCharacterCount: parsed.rawText.count,
            throughput: Self.ds4FinalThroughput(sync: sync, stats: generated.stats)
        )

        if generated.outcome == .cancelled {
            // Keep the partial turn: its tokens are in the KV and the user saw them.
            var partial = RemoteStreamResult(
                text: parsed.visibleText,
                reasoningText: parsed.reasoningText,
                stopReason: "cancelled",
                toolCalls: [],
                stats: stats
            )
            partial.ds4Turn = DS4AssistantTurn(
                rawText: parsed.rawText,
                thinkMode: prepared.thinkMode,
                toolCallReplays: [],
                toolObservation: nil,
                contextSize: prepared.contextSize,
                tokens: generated.tokens,
                tokensModel: prepared.tokenIdentity
            )
            mutateSession(for: lease) { session in
                appendAssistantMessage(streamResult: partial, to: &session.messages)
            }
            throw CancellationError()
        }

        await onEvent(.diagnostic(Self.ds4GenerationSummary(generated.stats, generatedTokens: generatedTokens)))
        var observation: String?
        if let parseError = parsed.parseError {
            observation = DS4AssistantTurn.malformedToolCallObservation(
                detail: parseError.detail,
                syntax: prepared.syntax
            )
            await onEvent(.diagnostic(
                "DS4 tool call could not be parsed (\(parseError.detail)); the model is asked to retry."
            ))
        }
        let stopReason = if !parsed.toolCalls.isEmpty {
            "tool_calls"
        } else if generated.outcome == .maxTokens {
            "length"
        } else {
            "end_turn"
        }
        var result = RemoteStreamResult(
            text: parsed.visibleText,
            reasoningText: parsed.reasoningText,
            stopReason: stopReason,
            toolCalls: parsed.toolCalls.map { prepared.toolCatalog.localToolCall(from: $0) },
            stats: stats
        )
        result.ds4Turn = DS4AssistantTurn(
            rawText: parsed.rawText,
            thinkMode: prepared.thinkMode,
            toolCallReplays: parsed.toolCallReplays,
            toolObservation: observation,
            contextSize: prepared.contextSize,
            tokens: generated.tokens,
            tokensModel: prepared.tokenIdentity
        )
        return result
    }

    // MARK: - Helpers

    /// Default temperature for the DeepSeek and Qwen families.
    static let ds4DefaultTemperature = 0.6
    /// ds4-agent GLM default temperature (`agent_apply_model_sampling_defaults`).
    static let ds4GLMDefaultTemperature = 1.0
    static let ds4DefaultTopP = 0.95
    static let ds4DefaultMinP = 0.0

    /// Sampling of a round: the model's generation overrides when set,
    /// otherwise temperature 0.6, top-p 0.95, min-p 0, top-k off (GLM:
    /// temperature 1.0, top-p 0.95, min-p 0, as ds4-agent).
    static func ds4Sampling(
        overrides: AgentGenerationParameterOverrides,
        syntax: DS4ToolSyntax
    ) -> DS4SamplingParameters {
        let defaultTemperature = syntax == .glm ? ds4GLMDefaultTemperature : ds4DefaultTemperature
        return DS4SamplingParameters(
            temperature: overrides.temperature ?? defaultTemperature,
            topK: Int32(clamping: overrides.topK ?? 0),
            topP: overrides.topP ?? ds4DefaultTopP,
            minP: overrides.minP ?? ds4DefaultMinP
        )
    }

    static func ds4GenerationSummary(_ stats: DS4SessionStats, generatedTokens: Int) -> String {
        String(
            format: "DS4 generation: %d tokens at %.1f tok/s (prefill %.1f tok/s)",
            generatedTokens,
            stats.generationTokensPerSecond,
            stats.prefillTokensPerSecond
        )
    }

    /// Throughput of a finished round from the exact engine values: the
    /// prefill and generation speeds when tokens were generated, otherwise only
    /// the speed of the prefill that ran, and `nil` when the whole prompt was
    /// cached and nothing was generated. A fully cached prompt has no prefill
    /// speed even when tokens were generated.
    static func ds4FinalThroughput(
        sync: DS4SyncResult,
        stats: DS4SessionStats
    ) -> DirectAgentGenerationThroughput? {
        let prefillRate = ds4PrefillTokensPerSecond(sync: sync, stats: stats)
        if stats.generatedTokens > 0 {
            return DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: prefillRate,
                generationTokensPerSecond: stats.generationTokensPerSecond
            )
        }
        if sync.suffix > 0 {
            return DirectAgentGenerationThroughput(
                phase: .prefill,
                prefillTokensPerSecond: prefillRate
            )
        }
        return nil
    }

    /// Exact prefill speed of the engine for this round: only when the sync
    /// evaluated a suffix and the engine reports a finite, positive speed.
    static func ds4PrefillTokensPerSecond(
        sync: DS4SyncResult,
        stats: DS4SessionStats
    ) -> Double? {
        guard sync.suffix > 0,
              stats.prefillTokensPerSecond.isFinite,
              stats.prefillTokensPerSecond > 0 else {
            return nil
        }
        return stats.prefillTokensPerSecond
    }
}

/// Forwards DS4 progress callbacks (engine thread) as `.status` events,
/// dropping repeats (DS4 reports both `prefill_chunk` and `prefill_display`).
final class DS4ProgressReporter: Sendable {
    private let last = Mutex<String?>(nil)
    private let continuation: AsyncStream<DirectAgentEvent>.Continuation

    init(continuation: AsyncStream<DirectAgentEvent>.Continuation) {
        self.continuation = continuation
    }

    func report(event: String, current: Int, total: Int) {
        let status = Self.status(event: event, current: current, total: total)
        let isNew = last.withLock { last in
            guard last != status else {
                return false
            }
            last = status
            return true
        }
        if isNew {
            continuation.yield(.status(status))
        }
    }

    static func status(event: String, current: Int, total: Int) -> String {
        if event == "distributed_route_wait" {
            return "Waiting for the distributed DS4 route…"
        }
        if event.hasPrefix("prefill"), total > 0 {
            return "DS4 prefill \(current)/\(total) tokens"
        }
        return total > 0 ? "DS4 \(event) \(current)/\(total)" : "DS4 \(event) \(current)"
    }
}
