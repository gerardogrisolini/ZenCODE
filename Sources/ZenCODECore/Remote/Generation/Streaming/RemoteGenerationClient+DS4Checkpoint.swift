//
//  RemoteGenerationClient+DS4Checkpoint.swift
//  ZenCODE
//
//  Explicit KV checkpoints of the in-process DS4 engine. These two methods are
//  the ONLY code of the client that touches `DS4Engine.saveCheckpoint` /
//  `loadCheckpoint`, and they run only when the user saves a session
//  (`/sessions save`, `/sessions <name>`) or loads a saved one. A generation,
//  `closeSession`, `shutdown` and `releaseDS4EngineSession` never write or
//  read a checkpoint.
//
//  Save (`saveEngineCheckpoint`)
//  - writes the LIVE KV state of the session (the one left by the last
//    `sync`/`generate` of this process), with a `DS4CheckpointTrailer` that
//    carries the private `ds4_*` message keys;
//  - never opens the model and never evaluates a prompt: without an open
//    engine, or without a live session in it, it reports
//    `.skippedNoLiveState`; a session that holds images (messages with image
//    content, or engine vision state) reports `.skippedImages` and writes
//    nothing;
//  - runs in the registry's generation lease (`withGenerationLeaseIfOpen`),
//    so it never overlaps a generation.
//
//  Restore (`restoreEngineCheckpoint`)
//  - loads the file into the engine session (opening the engine when
//    needed, with the usual "Loading DS4 model …" status) inside the
//    generation lease, then re-attaches the trailer keys to the restored
//    messages whose fingerprint agrees, so the next prompt renders the same
//    text that is in the KV and only prefills the new suffix;
//  - `kvIncompatible` (other model, quantization, context size, text) is
//    `.incompatible`: the session works and re-evaluates its prompt.
//

import Foundation

extension RemoteGenerationClient {
    public func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome {
        guard let ds4Generation else {
            return .notApplicable
        }
        guard let lease = sessionLease(for: sessionID), let session = currentSession(for: lease) else {
            return .skippedNoLiveState
        }
        if Self.messagesContainImageContent(session.messages) {
            return .skippedImages
        }
        // An unresolvable configuration (library not built, model moved) means
        // no engine of this manifest can be open: there is nothing live.
        guard let configuration = try? ds4Generation.engineConfiguration() else {
            return .skippedNoLiveState
        }
        let trailer = try DS4CheckpointTrailer.capture(from: session.messages).encoded()

        let outcome = try await ds4Generation.registry.withGenerationLeaseIfOpen(
            configuration: configuration,
            sessionID: sessionID
        ) { engine -> AgentEngineCheckpointSaveOutcome in
            // `stats` reports an empty session when it was never synced, was
            // evicted or released: nothing live to persist.
            guard await engine.stats(sessionID: sessionID).position > 0 else {
                return .skippedNoLiveState
            }
            switch try await engine.saveCheckpoint(sessionID: sessionID, to: url, trailer: trailer) {
            case .saved:
                return .saved
            case .skippedVision:
                return .skippedImages
            }
        } ?? .skippedNoLiveState
        if outcome == .saved {
            // The checkpoint embeds the conversation text: same mode as `.session`.
            try? SensitiveFilePermissions.hardenExistingFile(at: url)
        }
        return outcome
    }

    public func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome {
        guard let ds4Generation else {
            return .notApplicable
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notApplicable
        }
        guard let lease = sessionLease(for: sessionID) else {
            return .failed("session \(sessionID) is not available")
        }
        let configuration: DS4EngineConfiguration
        do {
            configuration = try ds4Generation.engineConfiguration()
        } catch {
            return .failed(error.localizedDescription)
        }

        if await ds4Generation.registry.currentIdentity != configuration.identity {
            await onEvent(.status("Loading DS4 model …"))
        }
        let trailerData: Data?
        do {
            trailerData = try await ds4Generation.registry.withGenerationLease(
                configuration: configuration,
                sessionID: sessionID,
                onStatus: { message in await onEvent(.status(message)) }
            ) { engine in
                try await engine.loadCheckpoint(sessionID: sessionID, from: url)
            }
        } catch DS4EngineError.kvIncompatible {
            return .incompatible
        } catch is CancellationError {
            return .failed("cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }

        // The engine now holds a session for this ID: closing the session or
        // shutting the client down must release it. A session closed while the
        // checkpoint was loading would never release it, so do it here.
        guard currentSession(for: lease) != nil else {
            await ds4Generation.registry.releaseSession(sessionID)
            return .failed("session \(sessionID) was closed while the checkpoint was loading")
        }
        ds4State.engineSessionIDs.insert(sessionID)
        if let trailerData {
            if let trailer = DS4CheckpointTrailer.decode(trailerData) {
                mutateSession(for: lease) { session in
                    trailer.apply(to: &session.messages)
                }
                // The restored context holds hints notes of the earlier run
                // (the preference itself is not saved): whatever the setting is
                // now, the next conversation boundary states it again.
                if trailer.messages.contains(where: { $0.ds4.hintsNote != nil }) {
                    ds4State.hintsBySessionID[sessionID, default: DS4HintsState()].contextRestoredWithNotes()
                }
            } else {
                ZenLogger.warning(
                    .sessionService,
                    "DS4 checkpoint \(url.lastPathComponent) has no usable message metadata; "
                        + "the prompt will be partially re-evaluated"
                )
            }
        }
        return .restored
    }
}
