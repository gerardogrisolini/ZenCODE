//
//  AgentCoreSessionRunner+RealtimeVoice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation

extension AgentCoreSessionRunner {
    /// The live voice link for a session whose runtime backend is a realtime
    /// voice backend, or `nil` for every other backend. Resolving the link
    /// connects the realtime conversation when it is not connected yet.
    public func realtimeVoiceLink(
        configuration: AgentCoreSessionConfiguration
    ) async throws -> OpenAIRealtimeVoiceLink? {
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        // Only hydrate a backend that does not know the session yet; a live
        // session is never reconfigured just to hand out a voice link.
        let backendHasSession = await backend.hasSession(id: configuration.sessionID)
        if !backendHasSession {
            try await ensureSession(
                configuration: configuration,
                backend: backend,
                backendGeneration: generation
            )
            try verifyBackendGeneration(generation)
        }
        let link = try await backend.realtimeVoiceLink(sessionID: configuration.sessionID)
        try verifyBackendGeneration(generation)
        return link
    }

    /// Automatic memory recall runs for every turn except a realtime voice
    /// turn, whose spoken input is already in the provider conversation.
    nonisolated static func shouldRecallMemory(forPrompt prompt: String) -> Bool {
        prompt != OpenAIRealtimeVoiceTurn.promptMarker
    }
}
