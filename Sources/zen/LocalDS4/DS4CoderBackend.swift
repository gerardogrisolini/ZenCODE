//
//  DS4CoderBackend.swift
//  ZenCODE
//

import DS4RuntimeShim
import Foundation
import ZenCODECore

actor DS4CoderBackend: AgentRuntimeBackend {
    struct SessionState {
        var cwd: URL
        var systemPrompt: String?
        var history: [AgentRuntimeMessage]
        var cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
        var ds4Session: DS4Session?
    }

    let configuration: AgentRuntimeConfiguration
    let options: DS4RuntimeOptions
    let toolExecutor: DirectToolExecutor

    private let sharedEngine: DS4SharedEngine
    private var sessions: [String: SessionState] = [:]
    private var activeSessionID: String?
    private var didEmitLoadedModel = false

    init(
        configuration: AgentRuntimeConfiguration,
        options: DS4RuntimeOptions,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        sharedEngine: DS4SharedEngine? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        let resolvedSharedEngine = sharedEngine ?? DS4SharedEngine(options: options)
        self.configuration = configuration
        self.options = options
        self.sharedEngine = resolvedSharedEngine
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory ?? { _ in
                DS4CoderBackend(
                    configuration: configuration,
                    options: options,
                    mcpRuntime: mcpRuntime,
                    sharedEngine: resolvedSharedEngine
                )
            }
        )
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = SessionState(
            cwd: URL(fileURLWithPath: cwd),
            systemPrompt: systemPrompt?.nilIfBlank,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            ds4Session: nil
        )
        activeSessionID = id
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else {
            activeSessionID = id
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        if session.systemPrompt != systemPrompt?.nilIfBlank
            || session.allowedToolNames != allowedToolNames {
            session.ds4Session = nil
        }
        session.systemPrompt = systemPrompt?.nilIfBlank
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        sessions[id] = session
        activeSessionID = id
    }

    func closeSession(id: String) async {
        sessions.removeValue(forKey: id)
        if activeSessionID == id {
            activeSessionID = nil
        }
    }

    func shutdown() async {
        sessions.removeAll(keepingCapacity: false)
        activeSessionID = nil
        await toolExecutor.shutdown()
    }

    func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
    }

    func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        try await sharedEngine.loadIfNeeded()
        guard !didEmitLoadedModel else {
            return options.modelID
        }
        didEmitLoadedModel = true
        await onEvent(.modelLoadedDetails(loadedModelDetails()))
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: 0,
                    maxTokens: options.contextWindow,
                    modelID: options.modelID,
                    isApproximate: true
                )
            )
        )
        return options.modelID
    }

    private func activeSessionForToolDescriptors() -> SessionState? {
        if let activeSessionID, let session = sessions[activeSessionID] {
            return session
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return nil
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard let session = activeSessionForToolDescriptors() else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil,
                history: [],
                cacheKey: nil,
                allowedToolNames: [],
                thinkingSelection: nil,
                preserveThinking: false
            )
        }
        activeSessionID = sessionID
        _ = try await preloadModel(onEvent: onEvent)
        guard var session = sessions[sessionID] else {
            throw DS4CoderBackendError.missingSession
        }
        // Persist the session state on every exit path (including thrown
        // errors) so the user prompt and tool results are never lost; skip it
        // only if the session was closed while this prompt was in flight.
        defer {
            if sessions[sessionID] != nil {
                sessions[sessionID] = session
            }
        }
        if !attachments.isEmpty {
            await onEvent(.diagnostic("DS4 local mode currently ignores attachments."))
        }

        let ds4Session = try await ensureDS4Session(for: &session)
        await onEvent(.modelRuntime("ds4/\(options.backend.rawValue)"))

        let maxTokens = configuration.maxOutputTokens
            ?? options.maxOutputTokens
            ?? 50000
        let thinkMode = Self.cThinkMode(from: session.thinkingSelection)
        let maxToolRounds = max(1, configuration.maxToolRounds)
        var accumulatedVisibleText = ""
        var nextPrompt: String? = prompt
        var lastStopReason = "end_turn"

        session.history.append(
            AgentRuntimeMessage(role: .user, content: prompt, attachments: attachments)
        )

        for round in 0..<maxToolRounds {
            let generationStartsInThinking = try await sharedEngine.effectiveThinkMode(
                thinkMode,
                contextWindow: options.contextWindow
            ).rawValue != ZENCODE_DS4_THINK_NONE.rawValue
            let result: DS4GenerationResult
            do {
                result = try await streamGeneration(
                    ds4Session,
                    prompt: nextPrompt,
                    maxTokens: maxTokens,
                    temperature: options.temperature,
                    topK: options.topK,
                    topP: options.topP,
                    minP: options.minP,
                    seed: Self.generationSeed(base: options.seed, round: round),
                    thinkMode: thinkMode,
                    startsInThinking: generationStartsInThinking,
                    onEvent: onEvent
                )
            } catch {
                // The C transcript may have rolled back or diverged from the
                // Swift history; drop it so the next prompt rebuilds the
                // transcript from the persisted history.
                session.ds4Session = nil
                throw error
            }
            nextPrompt = nil
            lastStopReason = Self.finishReason(from: result.stats.finish_reason)

            let startsInThinking = result.stats.effective_think_mode != Int32(ZENCODE_DS4_THINK_NONE.rawValue)
            let parsed = DS4ToolBridge.parseGeneratedMessage(
                result.rawText,
                requireThinkingClosed: startsInThinking
            )
            var splitter = DS4TranscriptSplitter(startsInThinking: startsInThinking)
            var visibleText = ""
            var reasoningText = ""
            for part in splitter.consume(parsed.replayText) + splitter.finish() {
                switch part {
                case .content(let text):
                    visibleText += text
                    accumulatedVisibleText += text
                case .thought(let text):
                    reasoningText += text
                }
            }

            let toolCalls = parsed.toolCalls.enumerated().map { offset, parsedToolCall in
                DS4ToolBridge.directToolCall(from: parsedToolCall, index: offset)
            }
            session.history.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: visibleText,
                    reasoningContent: session.preserveThinking ? reasoningText.nilIfBlank : nil,
                    toolCalls: toolCalls.map { toolCall in
                        AgentRuntimeToolCall(
                            id: toolCall.id,
                            name: toolCall.name,
                            argumentsJSON: toolCall.argumentsJSON
                        )
                    }
                )
            )

            await emitCacheDiagnostics(result.stats, onEvent: onEvent)
            await emitMetrics(
                result.stats,
                onEvent: onEvent
            )

            if let parseError = parsed.parseError {
                let toolError = """
                Tool error: invalid DSML tool call: \(parseError)
                \(DS4ToolBridge.syntaxReminder)
                """
                await onEvent(.diagnostic("DS4 invalid DSML tool call: \(parseError)"))
                await sharedEngine.appendMessage(ds4Session, role: "tool", content: toolError)
                session.history.append(AgentRuntimeMessage(role: .tool, content: toolError))
                if round == maxToolRounds - 1 {
                    throw DS4CoderBackendError.tooManyToolRounds(maxToolRounds)
                }
                continue
            }

            guard !toolCalls.isEmpty else {
                return DirectAgentResponse(
                    text: accumulatedVisibleText,
                    stopReason: lastStopReason,
                    modelID: options.modelID
                )
            }

            for toolCall in toolCalls {
                await onEvent(.toolCallStarted(toolCall))
                let toolResult = await toolExecutor.execute(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: session.cwd,
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(toolCall, toolResult))
                await sharedEngine.appendMessage(ds4Session, role: "tool", content: toolResult.output)
                session.history.append(
                    AgentRuntimeMessage(
                        role: .tool,
                        content: toolResult.output,
                        toolCallID: toolCall.id,
                        toolName: toolCall.name
                    )
                )
            }

            if round == maxToolRounds - 1 {
                throw DS4CoderBackendError.tooManyToolRounds(maxToolRounds)
            }
        }

        return DirectAgentResponse(
            text: accumulatedVisibleText,
            stopReason: lastStopReason,
            modelID: options.modelID
        )
    }

    private func streamGeneration(
        _ ds4Session: DS4Session,
        prompt: String?,
        maxTokens: Int,
        temperature: Float,
        topK: Int,
        topP: Float,
        minP: Float,
        seed: UInt64,
        thinkMode: zencode_ds4_think_mode,
        startsInThinking: Bool,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DS4GenerationResult {
        let (chunks, continuation) = AsyncStream<String>.makeStream()
        let streamingTask = Task {
            var filter = DS4StreamingOutputFilter(startsInThinking: startsInThinking)
            for await chunk in chunks {
                for part in filter.consume(chunk) {
                    await Self.emitStreamingPart(part, onEvent: onEvent)
                }
            }
            for part in filter.finish() {
                await Self.emitStreamingPart(part, onEvent: onEvent)
            }
        }

        do {
            let result = try await sharedEngine.generate(
                ds4Session,
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature,
                topK: topK,
                topP: topP,
                minP: minP,
                seed: seed,
                thinkMode: thinkMode,
                onChunk: { chunk in
                    continuation.yield(chunk)
                }
            )
            continuation.finish()
            await streamingTask.value
            return result
        } catch {
            continuation.finish()
            streamingTask.cancel()
            await streamingTask.value
            throw error
        }
    }

    private static func emitStreamingPart(
        _ part: DS4TranscriptSplitter.Part,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        switch part {
        case .content(let text):
            await onEvent(.content(text))
        case .thought(let text):
            await onEvent(.thought(text))
        }
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: options.modelID,
            workingDirectoryPath: session.cwd.path,
            systemPrompt: session.systemPrompt,
            cacheKey: session.cacheKey,
            history: session.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    private func ensureDS4Session(for session: inout SessionState) async throws -> DS4Session {
        if let ds4Session = session.ds4Session {
            return ds4Session
        }
        let ds4Session = try await sharedEngine.makeSession(contextWindow: options.contextWindow)
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
        if let systemPrompt = DS4ToolBridge.systemPrompt(
            basePrompt: session.systemPrompt,
            descriptors: toolDescriptors
        ) {
            await sharedEngine.appendMessage(ds4Session, role: "system", content: systemPrompt)
        }
        for message in session.history {
            await append(message, to: ds4Session)
        }
        session.ds4Session = ds4Session
        return ds4Session
    }

    private func append(_ message: AgentRuntimeMessage, to ds4Session: DS4Session) async {
        switch message.role {
        case .system:
            await sharedEngine.appendMessage(ds4Session, role: "system", content: message.content)
        case .user:
            await sharedEngine.appendMessage(ds4Session, role: "user", content: message.content)
        case .assistant:
            await sharedEngine.appendMessage(
                ds4Session,
                role: "assistant",
                content: Self.assistantReplayContent(from: message)
            )
            await sharedEngine.appendEOS(ds4Session)
        case .tool:
            await sharedEngine.appendMessage(ds4Session, role: "tool", content: message.content)
        }
    }

    private func loadedModelDetails() -> DirectAgentLoadedModelDetails {
        let generation = [
            "context_window=\(options.contextWindow)",
            "max_output_tokens=\(configuration.maxOutputTokens ?? options.maxOutputTokens ?? 50000)",
            "temperature=\(Self.format(options.temperature))",
            "top_p=\(Self.format(options.topP))",
            "min_p=\(Self.format(options.minP))"
        ].joined(separator: ", ")
        let kvCache = [
            options.ssdStreaming ? "ssd_streaming=on" : "ssd_streaming=off",
            options.ssdStreamingCacheBytes > 0
                ? "cache_bytes=\(options.ssdStreamingCacheBytes)"
                : "cache_experts=\(options.ssdStreamingCacheExperts)",
            "prefill_chunk=\(options.prefillChunk)"
        ].joined(separator: ", ")
        return DirectAgentLoadedModelDetails(
            modelID: options.modelID,
            runtime: "ds4/\(options.backend.rawValue)",
            generation: generation,
            penalties: nil,
            kvCache: kvCache
        )
    }

    private func emitCacheDiagnostics(
        _ stats: zencode_ds4_generation_stats,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let live = Int(stats.live_tokens_before)
        let common = Int(stats.common_prefix_tokens)
        guard live > 0, common < live else {
            return
        }
        await onEvent(
            .diagnostic(
                "DS4 KV cache miss: live=\(live) prompt=\(Int(stats.transcript_tokens)) common=\(common); prompt suffix re-evaluated=\(Int(stats.evaluated_prompt_tokens))."
            )
        )
    }

    private func emitMetrics(
        _ stats: zencode_ds4_generation_stats,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let contextTokens = Int(stats.session_pos)
        await onEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: Int(stats.evaluated_prompt_tokens),
                    cachedPromptTokenCount: Int(stats.cached_prompt_tokens),
                    promptTokensPerSecond: Double(stats.prompt_tokens_per_second),
                    completionTokenCount: Int(stats.generated_tokens),
                    completionTokensPerSecond: Double(stats.generation_tokens_per_second),
                    responseDurationSeconds: Double(stats.prompt_seconds + stats.generation_seconds),
                    contextTokenCount: contextTokens
                )
            )
        )
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: contextTokens,
                    maxTokens: options.contextWindow,
                    modelID: options.modelID,
                    isApproximate: false
                )
            )
        )
    }
}

/// Owns a single `DS4Engine` shared between a parent backend and its sub-agents.
///
/// The engine loads the model weights once; every backend reuses it. All
/// engine-touching operations (session creation, transcript appends, and
/// generation) are serialized on a dedicated serial queue so concurrently
/// running sub-agents never decode on the shared engine at the same time, and
/// the blocking C calls never occupy a Swift Concurrency cooperative thread.
actor DS4SharedEngine {
    private let options: DS4RuntimeOptions
    private var engine: DS4Engine?
    private var engineLoadTask: Task<DS4Engine, Error>?
    /// Serializes every engine-touching C call off the cooperative pool.
    private let engineQueue = DispatchQueue(label: "zencode.ds4.shared-engine")

    init(options: DS4RuntimeOptions) {
        self.options = options
    }

    func loadIfNeeded() async throws {
        _ = try await ensureEngine()
    }

    func makeSession(contextWindow: Int) async throws -> DS4Session {
        let engine = try await ensureEngine()
        return try await Self.runThrowing(on: engineQueue) {
            try engine.createSession(contextWindow: contextWindow)
        }
    }

    func appendMessage(_ session: DS4Session, role: String, content: String) async {
        await Self.run(on: engineQueue) {
            session.appendMessage(role: role, content: content)
        }
    }

    func appendEOS(_ session: DS4Session) async {
        await Self.run(on: engineQueue) {
            session.appendEOS()
        }
    }

    func reset(_ session: DS4Session) async {
        await Self.run(on: engineQueue) {
            session.reset()
        }
    }

    func generate(
        _ session: DS4Session,
        prompt: String?,
        maxTokens: Int,
        temperature: Float,
        topK: Int,
        topP: Float,
        minP: Float,
        seed: UInt64,
        thinkMode: zencode_ds4_think_mode,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> DS4GenerationResult {
        let cancellationFlag = DS4CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Self.runThrowing(on: engineQueue) {
                try session.generate(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    topK: topK,
                    topP: topP,
                    minP: minP,
                    seed: seed,
                    thinkMode: thinkMode,
                    shouldContinue: { !cancellationFlag.isCancelled },
                    onChunk: onChunk
                )
            }
        } onCancel: {
            cancellationFlag.cancel()
        }
    }

    func effectiveThinkMode(
        _ thinkMode: zencode_ds4_think_mode,
        contextWindow: Int
    ) async throws -> zencode_ds4_think_mode {
        let engine = try await ensureEngine()
        return await Self.run(on: engineQueue) {
            engine.effectiveThinkMode(thinkMode, contextWindow: contextWindow)
        }
    }

    private static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private static func runThrowing<T: Sendable>(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func ensureEngine() async throws -> DS4Engine {
        if let engine {
            return engine
        }
        if let engineLoadTask {
            return try await engineLoadTask.value
        }

        let options = options
        let engineQueue = engineQueue
        let task = Task<DS4Engine, Error> {
            try await Self.runThrowing(on: engineQueue) {
                try DS4Engine(options: options)
            }
        }
        engineLoadTask = task

        do {
            let opened = try await task.value
            engine = opened
            engineLoadTask = nil
            return opened
        } catch {
            engineLoadTask = nil
            throw error
        }
    }
}

private final class DS4CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
