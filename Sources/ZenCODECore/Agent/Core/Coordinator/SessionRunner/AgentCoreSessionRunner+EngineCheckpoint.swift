//
//  AgentCoreSessionRunner+EngineCheckpoint.swift
//  ZenCODE
//
//  Entry points of the optional engine checkpoint (DS4 KV cache) of a saved
//  session. The runner only forwards to the active backend: the file path is
//  computed by `TerminalSessionStore.engineCheckpointURL`, and the callers
//  (`TerminalChat.saveCurrentSession`, `TerminalChat.loadSavedSession`) are the
//  only code that triggers them, so nothing is ever written or read implicitly.
//

import Foundation

public extension AgentCoreSessionRunner {
    /// Saves the engine KV cache of `sessionID` to `url`. `.notApplicable` when
    /// no backend is active or the backend has no in-process engine.
    func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome {
        guard let backend else {
            return .notApplicable
        }
        return try await backend.saveEngineCheckpoint(sessionID: sessionID, to: url)
    }

    /// Restores the engine KV cache stored at `url` into `sessionID`; call it
    /// after `restoreSession`, so the backend session already holds the
    /// restored messages the checkpoint metadata is matched against.
    func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void = { _ in }
    ) async -> AgentEngineCheckpointRestoreOutcome {
        guard let backend else {
            return .notApplicable
        }
        return await backend.restoreEngineCheckpoint(sessionID: sessionID, from: url, onEvent: onEvent)
    }
}
