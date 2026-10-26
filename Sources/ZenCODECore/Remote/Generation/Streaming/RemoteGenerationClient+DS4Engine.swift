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

    var operations: [DS4TranscriptOperation] {
        transcript.operations
    }
}

/// A rendered prompt and its tokenization.
private struct DS4TokenizedRound {
    let rendered: DS4RenderedTranscript
    let prepared: DS4PreparedTranscript
    /// Messages of the session that were rendered.
    let messageCount: Int
}

/// Bridges the synchronous `onText` callback (engine thread) to the async
/// event stream: the parser lives behind a `Mutex`, every delta is yielded in
/// order and the parser state decides the emit flags of each token.
final class DS4GenerationBridge: Sendable {
    private struct State {
        var parser: DS4GeneratedOutputParser
        var firstTextAt: Date?
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
            return output
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
            toolCalls: parsed.toolCalls,
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

    // MARK: - Preparation

    /// Renders the prompt of the round, compacting and recording the system
    /// prompt reminder when needed. Runs outside the generation lease. The
    /// returned prompt is tokenized once (`DS4Engine.prepare`); the caller
    /// releases it.
    private func prepareDS4Round(
        _ ds4: DS4LocalGeneration,
        configuration: DS4EngineConfiguration,
        lease: SessionLease,
        staging: DS4ImageStaging,
        statusHandler: @escaping DS4EngineRegistry.StatusHandler,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DS4PreparedRound {
        let engine = try await ds4.registry.engine(for: configuration, onStatus: statusHandler)
        let info = engine.info
        let syntax = DS4ToolSyntax(rawValue: info.toolSyntaxID) ?? .dsml
        let contextSize = info.contextSize > 0 ? info.contextSize : configuration.contextSize
        let visionConfigured = info.hasVision && ds4.manifest.visionRelativePath != nil

        try await prepareDS4Images(lease: lease, visionConfigured: visionConfigured, onEvent: onEvent)
        try freezeDS4CurrentTurnUserContent(lease: lease)
        // `/ds4 hints`: the note of this conversation boundary, if the setting changed.
        try applyDS4HintsBoundary(lease: lease)

        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
        let toolsPrompt = DS4ToolsPrompt.toolsPrompt(
            descriptors: descriptors,
            syntax: syntax,
            hasVision: info.hasVision
        )
        let thinkMode = await DS4ThinkModeMapping.effectiveMode(
            for: session.thinkingSelection,
            syntax: syntax,
            engine: engine,
            contextSize: contextSize
        )
        let reserve = try await ds4ReserveTokens(
            engine: engine,
            identity: configuration.identity,
            contextSize: contextSize
        )
        func render(_ session: AgentSession) -> DS4RenderedTranscript {
            DS4TranscriptRenderer.render(
                messages: session.messages,
                context: DS4TranscriptRenderer.Context(
                    syntax: syntax,
                    thinkMode: thinkMode,
                    toolsPrompt: toolsPrompt,
                    preserveThinking: session.preserveThinking,
                    imageFiles: visionConfigured ? staging : nil,
                    tokenIdentity: info.tokenIdentity
                )
            )
        }

        /// Renders `session` and tokenizes it (`prepare`: images are encoded
        /// here, once). An image that cannot be read or encoded is removed
        /// from the session with a diagnostic, and the prompt is rendered
        /// again without images, instead of failing every later round.
        func tokenize(_ session: AgentSession) async throws -> DS4TokenizedRound {
            var current = session
            var removedImages = false
            while true {
                let rendered = render(current)
                if visionConfigured, !removedImages, staging.takeNewFailureCount() > 0 {
                    removedImages = true
                    current = try await removeDS4Images(
                        lease: lease, reason: "cannot read an attached image", onEvent: onEvent
                    )
                    continue
                }
                var encodeFailure: String?
                do {
                    let prepared = try await engine.prepare(transcript: rendered.operations)
                    return DS4TokenizedRound(rendered: rendered, prepared: prepared, messageCount: current.messages.count)
                } catch DS4EngineError.vision(let detail) where visionConfigured && !removedImages {
                    encodeFailure = detail
                }
                removedImages = true
                current = try await removeDS4Images(
                    lease: lease, reason: encodeFailure ?? "cannot encode an attached image", onEvent: onEvent
                )
            }
        }

        var tokenized = try await tokenize(session)
        do {
            // agent_worker_compact_if_needed before the assistant continuation.
            var compactions = 0
            while DS4CompactionPolicy.shouldCompact(
                usedTokens: tokenized.prepared.tokenCount, contextSize: contextSize, reserveTokens: reserve
            ),
                  compactions < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
                compactions += 1
                guard await compactSession(
                    id: lease.id, force: true, exactTokenCount: tokenized.prepared.tokenCount
                ) != nil else {
                    break
                }
                // The compacted context forgot the hints instructions (`compactSession`
                // marked the state); the note is decided again for the kept user message.
                try applyDS4HintsBoundary(lease: lease, replacingRecordedNote: true)
                guard let compacted = currentSession(for: lease) else {
                    throw RemoteGenerationClientError.missingSession
                }
                let previous = tokenized.prepared.tokenCount
                tokenized.prepared.release()
                tokenized = try await tokenize(compacted)
                await onEvent(.diagnostic(
                    "DS4 context compacted: \(previous) -> \(tokenized.prepared.tokenCount) tokens "
                        + "(context \(contextSize))."
                ))
            }

            // agent_worker_maybe_append_system_prompt_reminder: the position is
            // decided once and recorded in the message, so later renders agree.
            if tokenized.prepared.tokenCount >= DS4TranscriptRenderer.systemPromptReminderTokens,
               let lastIndex = tokenized.rendered.lastMessageIndex {
                // Recorded by `prepare`, so images before the anchor are not encoded again.
                let anchorOperationCount = tokenized.rendered.reminderAnchorOperationCount
                let anchorTokens: Int
                if let counted = tokenized.prepared.tokenCount(afterOperations: anchorOperationCount) {
                    anchorTokens = counted
                } else {
                    anchorTokens = try await engine.tokenCount(
                        of: Array(tokenized.rendered.operations.prefix(anchorOperationCount))
                    )
                }
                if tokenized.prepared.tokenCount - anchorTokens >= DS4TranscriptRenderer.systemPromptReminderTokens {
                    var recorded = false
                    let renderedMessageCount = tokenized.messageCount
                    guard mutateSession(for: lease, { session in
                        // Skip when the history changed while counting tokens.
                        guard session.messages.count == renderedMessageCount, lastIndex < session.messages.count else {
                            return
                        }
                        session.messages[lastIndex][DS4MessageKeys.systemReminder] = true
                        recorded = true
                    }), let updated = currentSession(for: lease) else {
                        throw RemoteGenerationClientError.missingSession
                    }
                    if recorded {
                        await onEvent(.status("Re-injecting system prompt reminder..."))
                        tokenized.prepared.release()
                        tokenized = try await tokenize(updated)
                    }
                }
            }

            let used = tokenized.prepared.tokenCount
            let maxTokens = DS4CompactionPolicy.generationTokenLimit(
                maxOutputTokens: self.configuration.maxOutputTokens,
                contextSize: contextSize,
                usedTokens: used,
                reserveTokens: reserve
            )
            guard maxTokens > 0 else {
                throw DS4EngineError.contextExhausted(used: used, limit: contextSize)
            }
            return DS4PreparedRound(
                sessionID: lease.id,
                transcript: tokenized.prepared,
                promptTokens: used,
                maxTokens: maxTokens,
                syntax: syntax,
                thinkMode: thinkMode,
                sampling: Self.ds4Sampling(
                    overrides: self.configuration.generationParameterOverrides,
                    syntax: syntax
                ),
                parameterTypes: DS4ToolParameterKind.map(from: descriptors),
                contextSize: contextSize,
                tokenIdentity: info.tokenIdentity
            )
        } catch {
            tokenized.prepared.release()
            throw error
        }
    }

    /// Images: without a configured vision encoder they are removed from the
    /// session (once per round that has any); with one they stay in history
    /// and `DS4TranscriptRenderer` sends them as multimodal messages.
    private func prepareDS4Images(
        lease: SessionLease,
        visionConfigured: Bool,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        guard !visionConfigured, Self.messagesContainImageContent(session.messages) else {
            return
        }
        guard mutateSession(for: lease, { session in
            session.messages = Self.messagesStrippingImageContent(from: session.messages)
        }) else {
            throw RemoteGenerationClientError.missingSession
        }
        await onEvent(.diagnostic("DS4 model has no vision encoder configured; images were ignored"))
    }

    /// An attached image could not be read or encoded: removes every image
    /// from the session (the same message would fail every round) and says so.
    private func removeDS4Images(
        lease: SessionLease,
        reason: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> AgentSession {
        guard mutateSession(for: lease, { session in
            session.messages = Self.messagesStrippingImageContent(from: session.messages)
        }), let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        await onEvent(.diagnostic("DS4 could not use the attached images (\(reason)); images were ignored"))
        return session
    }

    /// Stores in the last user message the content it is sent with this turn
    /// (memory block and instruction appended by `applyingCurrentTurnMemory`),
    /// so later rounds and turns render it unchanged.
    private func freezeDS4CurrentTurnUserContent(lease: SessionLease) throws {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        guard let index = session.messages.lastIndex(where: { message in
            Self.stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        }), session.messages[index][DS4MessageKeys.userContent] == nil else {
            return
        }
        let outgoing = Self.applyingCurrentTurnMemory(to: session.messages)
        guard outgoing.count == session.messages.count else {
            return
        }
        let rendered = Self.contentString(from: outgoing[index]["content"]) ?? ""
        guard rendered != DS4TranscriptRenderer.userContent(of: session.messages[index]) else {
            return
        }
        mutateSession(for: lease) { session in
            guard index < session.messages.count else {
                return
            }
            session.messages[index][DS4MessageKeys.userContent] = rendered
        }
    }

    /// `agent_compact_reserve_tokens`, counted once per engine identity.
    private func ds4ReserveTokens(engine: any DS4Engine, identity: String, contextSize: Int) async throws -> Int {
        if let cached = ds4State.reserveTokensByIdentity[identity] {
            return cached
        }
        let promptTokens = try await engine.tokenCount(of: DS4CompactionPolicy.reserveTranscript)
        let reserve = DS4CompactionPolicy.reserveTokens(
            compactionPromptTokens: promptTokens,
            contextSize: contextSize
        )
        ds4State.reserveTokensByIdentity[identity] = reserve
        return reserve
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

/// Turns the DS4 prefill progress and per-token generation callbacks (engine
/// thread) into live `.metrics` events that carry only the throughput.
///
/// Events are throttled to one every `minimumInterval`; the first one of each
/// phase is immediate, so the label switches from prefill to generation before
/// the first token and then follows the generation. The callbacks only take a
/// short lock and yield: they never block the engine thread.
///
/// Prefill progress is relative to the sync. The shim announces the sync with a
/// `prefill_start` event whose `current` is the reused prefix and whose `total`
/// is the prompt length: that is the baseline of both the progress and the
/// rate. DS4 then reports absolute positions (`total` still the prompt length);
/// the GLM tensor-parallel path reports positions relative to the start
/// instead. Without a `prefill_start`, the first prefill event is the baseline.
/// The final values of the round are not computed here: the engine reports
/// them exactly (`DS4SessionStats`).
final class DS4ThroughputReporter: Sendable {
    typealias Phase = DirectAgentGenerationThroughput.Phase

    static let minimumInterval = Duration.milliseconds(250)
    /// Event the shim emits once, before DS4 starts evaluating the prompt.
    static let prefillStartEvent = "prefill_start"

    private struct PrefillBaseline {
        /// Absolute position the evaluation starts from (the reused prefix).
        var cached: Int
        /// Prompt length announced by `prefill_start`; `nil` when the baseline
        /// was inferred from the first prefill event.
        var announcedPromptTotal: Int?
        var instant: ContinuousClock.Instant
    }

    private struct State {
        var prefillBaseline: PrefillBaseline?
        var prefillTokensPerSecond: Double?
        var generationStartedAt: ContinuousClock.Instant?
        var generatedTokens = 0
        var lastEmission: (phase: Phase, instant: ContinuousClock.Instant)?
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<DirectAgentEvent>.Continuation
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        continuation: AsyncStream<DirectAgentEvent>.Continuation,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.continuation = continuation
        self.now = now
    }

    /// Progress callback of `sync`. Only `prefill*` events with a known total
    /// describe the evaluation of the prompt; the others (for example
    /// `distributed_route_wait`) are ignored.
    func reportPrefill(event: String, current: Int, total: Int) {
        guard event.hasPrefix("prefill"), total > 0 else {
            return
        }
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            let baseline: PrefillBaseline
            if event == Self.prefillStartEvent {
                baseline = PrefillBaseline(cached: current, announcedPromptTotal: total, instant: instant)
            } else if let known = state.prefillBaseline {
                baseline = known
            } else {
                baseline = PrefillBaseline(cached: current, announcedPromptTotal: nil, instant: instant)
            }
            state.prefillBaseline = baseline

            let promptTotal = baseline.announcedPromptTotal ?? total
            let target = promptTotal - baseline.cached
            guard target > 0 else {
                return nil
            }
            // A `total` other than the prompt length marks positions that are
            // already relative to the start of the evaluation.
            let position = total == promptTotal ? current - baseline.cached : current
            let processed = min(max(position, 0), target)
            let elapsed = Self.seconds(from: baseline.instant, to: instant)
            guard Self.shouldEmit(.prefill, at: instant, state: &state) else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .prefill,
                prefillTokensPerSecond: processed > 0 && elapsed > 0 ? Double(processed) / elapsed : nil,
                processedTokens: processed,
                targetTokens: target
            )
        }
        emit(throughput)
    }

    /// Records the start of the generation, right after the sync has ended.
    ///
    /// `prefillTokensPerSecond` is the exact prefill speed of the engine for
    /// this round (`nil` when no prompt was evaluated). When it is known the
    /// phase switches to generation at once, so the label shows it before the
    /// first token. That update does not delay the one of the first token.
    func beginGeneration(prefillTokensPerSecond: Double?) {
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            state.generationStartedAt = instant
            state.generatedTokens = 0
            state.prefillTokensPerSecond = prefillTokensPerSecond
            // The first generated token is always emitted immediately.
            state.lastEmission = nil
            guard let prefillTokensPerSecond else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: prefillTokensPerSecond,
                generationTokensPerSecond: nil
            )
        }
        emit(throughput)
    }

    /// `onText` callback of `generate`: one call per committed token.
    func recordGeneratedToken() {
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            state.generatedTokens += 1
            let startedAt = state.generationStartedAt ?? instant
            let elapsed = Self.seconds(from: startedAt, to: instant)
            guard Self.shouldEmit(.generation, at: instant, state: &state) else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: state.prefillTokensPerSecond,
                generationTokensPerSecond: elapsed > 0 ? Double(state.generatedTokens) / elapsed : nil
            )
        }
        emit(throughput)
    }

    private func emit(_ throughput: DirectAgentGenerationThroughput?) {
        guard let throughput else {
            return
        }
        continuation.yield(.metrics(DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            completionTokenCount: nil,
            throughput: throughput,
            isLiveProgress: true
        )))
    }

    private static func shouldEmit(_ phase: Phase, at instant: ContinuousClock.Instant, state: inout State) -> Bool {
        if let last = state.lastEmission,
           last.phase == phase,
           last.instant.duration(to: instant) < minimumInterval {
            return false
        }
        state.lastEmission = (phase: phase, instant: instant)
        return true
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
