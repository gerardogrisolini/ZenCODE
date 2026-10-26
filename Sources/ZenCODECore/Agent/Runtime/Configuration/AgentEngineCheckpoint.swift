//
//  AgentEngineCheckpoint.swift
//  ZenCODE
//
//  Outcomes of the optional "engine checkpoint" of a runtime backend: the
//  in-process DS4 engine can persist the KV cache of a session next to the
//  saved `.session` file, so a restored session does not re-evaluate its whole
//  prompt. The checkpoint is written ONLY when the user saves the session
//  explicitly (`/sessions save`, `/sessions <name>`); no backend ever writes
//  one on its own (not after a generation, not on `closeSession`, not on
//  `shutdown`).
//
//  Backends without an in-process engine report `.notApplicable` (the default
//  implementations in `AgentRuntimeBackend`), and the caller stays silent.
//

import Foundation

/// Result of `AgentRuntimeBackend.saveEngineCheckpoint(sessionID:to:)`.
public enum AgentEngineCheckpointSaveOutcome: Sendable, Equatable {
    /// The checkpoint file was written.
    case saved
    /// Nothing was written: the session holds images (the engine never
    /// persists image-conditioned state) and the checkpoint would be unsafe.
    case skippedImages
    /// Nothing was written: the process holds no live engine state for the
    /// session (engine not open, session never generated here, or evicted).
    /// Saving never opens the model nor evaluates a prompt.
    case skippedNoLiveState
    /// The backend has no in-process engine; nothing to save, nothing to say.
    case notApplicable

    /// Whether a checkpoint file exists after the call because of it.
    public var wroteCheckpoint: Bool {
        self == .saved
    }
}

/// Result of `AgentRuntimeBackend.restoreEngineCheckpoint(sessionID:from:onEvent:)`.
public enum AgentEngineCheckpointRestoreOutcome: Sendable, Equatable {
    /// The KV cache was loaded into the engine session.
    case restored
    /// The file does not match the open model (model id, quantization,
    /// context size) or the stored text: the session simply re-evaluates its
    /// prompt on the next turn.
    case incompatible
    /// The backend has no in-process engine, or there is no checkpoint file.
    case notApplicable
    /// The checkpoint could not be loaded (I/O error, malformed file,
    /// engine failure). Never blocks loading the session.
    case failed(String)
}
