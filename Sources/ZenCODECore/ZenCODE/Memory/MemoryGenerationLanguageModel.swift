//
//  MemoryGenerationLanguageModel.swift
//  ZenCODE
//
//  Side-model adapter that runs ZenMemory's intelligence layer on ZenCODE's
//  own generation stack.
//

import Foundation
import ZenMemory

/// A ``MemoryLanguageModel`` backed by ZenCODE's generation stack.
///
/// ZenMemory ships `OpenAICompatibleChatModel`, which only reaches providers
/// that expose a `/v1/chat/completions` route with a bearer key. That excludes
/// the subscription providers, which are exactly the ones most ZenCODE users
/// have configured. This adapter instead resolves the configured side model
/// through ``AgentRemoteBackendFactory``, so any provider ZenCODE can talk to —
/// API-key, ChatGPT subscription, or Anthropic subscription — can serve memory
/// extraction.
///
/// Three anti-pollution rules govern this type, and none of them is optional:
///
/// 1. **Never route through `AgentCoreSessionRunner` or `AgentCoreBackend`.**
///    Those own the operator's session map, backend generation counters and
///    snapshot cache. A side call through them would appear as a real turn:
///    it could reset the operator backend, evict cached snapshots, or race the
///    generation fence of the turn that triggered it.
/// 2. **No tools, one round.** `allowedToolNames: []` makes
///    `DirectToolExecutor.descriptors` return an empty catalogue, so the side
///    model is a pure text completion and cannot execute anything, delegate,
///    or touch the task graph. `maxToolRounds: 1` bounds it.
/// 3. **Never call `installTaskOrchestrator`.** `AgentCoreBackend`'s
///    implementation calls `preconditionFailure` when an orchestrator is
///    replaced, which traps the whole process. This client has no task-graph
///    role at all, so the orchestrator is simply never installed; the default
///    protocol implementation on `AgentRuntimeBackend` is a no-op anyway.
///
/// The ephemeral backend is closed and shut down on every exit path, including
/// throws, so a failed extraction cannot leak a transport or an MCP runtime.
struct MemoryGenerationLanguageModel: MemoryLanguageModel {
    /// ZenCODE model id of the side model.
    let modelID: String
    /// Working directory handed to the ephemeral session. It never runs tools,
    /// so this only anchors provider/session bookkeeping.
    let workspaceRootURL: URL

    func complete(system: String, user: String) async throws -> String {
        let configuration = AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workspaceRootURL,
            maxToolRounds: 1,
            verboseLogging: false,
            // Suppresses the per-request diagnostic chatter of the generation
            // clients: this call has no operator-facing event stream.
            appMode: true,
            toolAuthorizationHandler: nil
        )
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: DirectMCPToolRuntime()
        )
        // Deliberately NO `installTaskOrchestrator(_:)` here. See rule 3 above.

        let sessionID = "zencode-memory-side-\(UUID().uuidString.lowercased())"
        await backend.createSession(
            id: sessionID,
            cwd: workspaceRootURL.path,
            systemPrompt: system,
            history: [],
            cacheKey: nil,
            allowedToolNames: [],
            thinkingSelection: nil,
            preserveThinking: false
        )

        // `defer` cannot contain `await`, so teardown is spelled out on both
        // exit paths instead.
        do {
            let response = try await backend.sendPrompt(
                sessionID: sessionID,
                prompt: user,
                attachments: [],
                onEvent: { _ in }
            )
            await Self.tearDown(backend, sessionID: sessionID)
            return response.text
        } catch {
            await Self.tearDown(backend, sessionID: sessionID)
            throw error
        }
    }

    private static func tearDown(
        _ backend: any AgentRuntimeBackend,
        sessionID: String
    ) async {
        await backend.closeSession(id: sessionID)
        await backend.shutdown()
    }
}
