#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Lifecycle.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
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
            messages: Self.initialMessages(
                systemPrompt: systemPrompt,
                history: history
            ),
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
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
        session.messages = Self.replacingSystemPrompt(
            in: session.messages,
            with: systemPrompt
        )
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        sessions[id] = session
    }

    func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedOrchestrationToolExecutor(executor)
    }

    func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    func closeSession(id: String) async {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll(keepingCapacity: false)
        await toolExecutor.shutdown()
    }

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        guard !didEmitLoadedModel else {
            return model.id
        }
        try await runtime.preloadModel(
            model: model,
            runtimeKind: model.runtimeKind,
            parameters: generationParameters()
        )
        didEmitLoadedModel = true
        await onEvent(.modelLoadedDetails(loadedModelDetails()))
        if let contextWindow = model.generationDefaults.contextWindow
            ?? configuration.configuredContextWindowLimit {
            await onEvent(
                .contextWindow(
                    DirectAgentContextWindowStatus(
                        usedTokens: 0,
                        maxTokens: contextWindow,
                        modelID: model.id,
                        isApproximate: true
                    )
                )
            )
        }
        return model.id
    }

    func loadedModelDetails() -> DirectAgentLoadedModelDetails {
        let defaults = model.generationDefaults
        let parameters = generationParameters()
        let generationLine = [
            "context_window=\(Self.formatModelDefault(defaults.contextWindow))",
            "max_output_tokens=\(Self.formatModelDefault(parameters.maxTokens))",
            "temperature=\(Self.format(parameters.temperature))",
            "top_p=\(Self.format(parameters.topP))",
            "top_k=\(parameters.topK)",
            "min_p=\(Self.format(parameters.minP))",
        ].joined(separator: ", ")
        let penaltiesLine = [
            "repetition=\(Self.formatModelDefault(parameters.repetitionPenalty))",
            "presence=\(Self.formatModelDefault(parameters.presencePenalty))",
            "frequency=\(Self.formatModelDefault(parameters.frequencyPenalty))",
        ].joined(separator: ", ")
        let kvCache = parameters.kvBits.map {
            "quantized(bits=\($0), group=\(parameters.kvGroupSize), start=\(parameters.quantizedKVStart))"
        } ?? "standard"

        return DirectAgentLoadedModelDetails(
            modelID: model.id,
            runtime: model.runtimeKind.rawValue,
            generation: generationLine,
            penalties: penaltiesLine,
            kvCache: "\(kvCache), prefill_step_size=\(parameters.prefillStepSize)"
        )
    }

    static func formatModelDefault(_ value: Int?) -> String {
        value.map(String.init) ?? "model_default"
    }

    static func formatModelDefault(_ value: Float?) -> String {
        value.map(format) ?? "model_default"
    }

    static func format(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard let session = sessions.values.first else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = Self.snapshotMessages(from: session.messages)
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: model.id,
            workingDirectoryPath: session.cwd.path,
            systemPrompt: splitMessages.systemPrompt,
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    func saveSessionRuntimeCache(id: String) async {
                guard let session = sessions[id] else {
            return
        }
        let tools = await toolSpecs(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
        let request = generationRequest(for: session, sessionID: id, tools: tools)
        _ = await runtime.saveChatSessionCacheToDisk(request: request)
    }

    func restoreSessionRuntimeCache(id: String) async {
                guard let session = sessions[id] else {
            return
        }
        let tools = await toolSpecs(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
        let request = generationRequest(for: session, sessionID: id, tools: tools)
        do {
            _ = try await runtime.restoreChatSessionCacheFromDisk(request: request)
        } catch {
            ZenLogger.warning(
                .viewModelRuntime,
                "failed to restore MLX session cache id=\(id): \(error.localizedDescription)"
            )
        }
    }
}
#endif
