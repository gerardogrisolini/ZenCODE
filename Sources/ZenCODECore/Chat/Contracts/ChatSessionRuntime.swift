//
//  ChatSessionRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The session runtime a ``ChatSessionController`` drives.
///
/// `AgentCoreSessionRunner` is the production runtime; tests can supply a
/// scripted actor. The protocol is deliberately narrow: session creation,
/// shutdown, and every channel-specific operation stay with the channel.
protocol ChatSessionRuntime: Actor {
    /// The orchestrator that owns the task graphs of every session.
    nonisolated var taskOrchestrator: SessionTaskOrchestrator { get }

    func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler?,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders: [AgentToolProvider],
        turnInstruction: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot]

    @discardableResult
    func closeSubAgent(id: String) async -> Bool

    func taskGraphSnapshot(
        sessionID: String,
        graphID: String?
    ) async throws -> TaskGraphSnapshot?

    @discardableResult
    func removeTaskGraph(id: String, sessionID: String) async throws -> TaskGraphSnapshot

    func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot?

    func currentSessionGeneration(
        for sessionID: String
    ) -> AgentCoreSessionRunner.SessionGeneration?

    @discardableResult
    func replaceSessionHistory(
        id sessionID: String,
        history: [AgentRuntimeMessage],
        expectedSessionGeneration: AgentCoreSessionRunner.SessionGeneration
    ) async -> Bool
}

extension AgentCoreSessionConfiguration {
    /// This configuration with `toolNames` added to an explicit grant. A `nil`
    /// grant already allows every tool and is returned unchanged, as is a grant
    /// that already contains every name.
    func addingAllowedToolNames(_ toolNames: Set<String>) -> AgentCoreSessionConfiguration {
        guard let allowedToolNames, !toolNames.isSubset(of: allowedToolNames) else {
            return self
        }
        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            agentID: agentID,
            agentName: agentName,
            agentRole: agentRole,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision,
            history: history,
            allowedToolNames: allowedToolNames.union(toolNames),
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}

extension AgentCoreSessionRunner: ChatSessionRuntime {
    func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler?,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders: [AgentToolProvider],
        turnInstruction: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        try await sendPrompt(
            configuration: configuration,
            prompt: prompt,
            attachments: attachments,
            authorizeTool: authorizeTool,
            onToolWillExecute: onToolWillExecute,
            borrowedSubAgentToolExecutor: nil,
            toolProviders: toolProviders,
            turnInstruction: turnInstruction,
            onEvent: onEvent
        )
    }
}
