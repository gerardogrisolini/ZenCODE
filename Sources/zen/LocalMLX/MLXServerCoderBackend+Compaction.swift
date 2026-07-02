#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Compaction.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
    func compactSessionIfNeeded(
        _ session: inout SessionState,
        force: Bool = false
    ) -> AgentConversationCompactionResult? {
        let maxTokens = configuration.configuredContextWindowLimit
            ?? model.generationDefaults.contextWindow
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            session.messages.map(Self.agentRuntimeMessage(from:)),
            maxTokens: maxTokens,
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = result.messages.map(Self.serverMessage(from:))
        return result
    }

    func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id],
              let result = compactSessionIfNeeded(&session, force: force) else {
            return nil
        }

        sessions[id] = session
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    static func compactionDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        "Compacted conversation history from \(result.originalEstimatedTokenCount) to \(result.estimatedTokenCount) estimated tokens."
    }

    static func cacheDiagnostic(
        from event: MLXServerChatCacheEvent
    ) -> String {
        let cachedPromptTokens = event.cachedPromptTokenCount.map(String.init) ?? "--"
        let restoredPromptTokens = event.restoredPromptPrefixTokenCount.map(String.init) ?? "--"
        return "KV cache: status=\(event.status.rawValue) cachedPromptTokens=\(cachedPromptTokens) restoredPromptTokens=\(restoredPromptTokens) requestMessages=\(event.priorTranscriptCount) bestCommonPrefixMessages=\(event.bestCommonPrefixCount) cachedTranscriptMessages=\(event.bestCachedTranscriptCount)"
    }
}
#endif
