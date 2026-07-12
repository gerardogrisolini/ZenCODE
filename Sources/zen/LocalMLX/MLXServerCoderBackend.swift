#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

actor MLXServerCoderBackend: AgentRuntimeBackend {
    struct SessionState {
        var cwd: URL
        var messages: [MLXServerChatMessage]
        var cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    struct GenerationTurn {
        var visibleText: String
        var historyVisibleText: String
        var reasoningText: String
        var toolCalls: [ToolCall]
        var completionInfo: GenerateCompletionInfo?
    }

    let configuration: AgentRuntimeConfiguration
    let runtime: MLXServerRuntime
    let model: MLXServerModelDescriptor
    let kvCacheSettings: MLXServerKVCacheSettings
    let toolExecutor: DirectToolExecutor

    var sessions: [String: SessionState] = [:]
    var didEmitLoadedModel = false

    init(
        configuration: AgentRuntimeConfiguration,
        runtime: MLXServerRuntime,
        model: MLXServerModelDescriptor,
        kvCacheSettings: MLXServerKVCacheSettings,
        mcpRuntime: DirectMCPToolRuntime,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.model = model
        self.kvCacheSettings = kvCacheSettings
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory ?? { _ in
                MLXServerCoderBackend(
                    configuration: configuration,
                    runtime: runtime,
                    model: model,
                    kvCacheSettings: kvCacheSettings,
                    mcpRuntime: mcpRuntime
                )
            }
        )
    }
    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        await toolExecutor.installTaskOrchestrator(orchestrator)
    }

    func closeSubAgent(id: String) async -> Bool {
        await toolExecutor.closeSubAgent(id: id)
    }

    func interruptSubAgents(rootSessionID: String) async -> Int {
        await toolExecutor.interruptSubAgents(rootSessionID: rootSessionID)
    }
}
#endif
