//
//  AgentCoreSessionRunner+DS4Control.swift
//  ZenCODE
//
//  Entry point of `/ds4`. Like the engine checkpoint, the runner only forwards
//  to the active backend: it never resolves a new backend (so a control never
//  opens a model) and nothing is persisted.
//

import Foundation

public extension AgentCoreSessionRunner {
    /// Runs a DS4 runtime control on `sessionID`. Throws
    /// `AgentDS4ControlError.noActiveBackend` when no backend is active, and
    /// `AgentDS4ControlError.unavailable` when the active backend has no DS4
    /// engine.
    func ds4Control(
        _ command: AgentDS4ControlCommand,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        guard let backend else {
            throw AgentDS4ControlError.noActiveBackend
        }
        return try await backend.ds4Control(command, sessionID: sessionID)
    }
}
