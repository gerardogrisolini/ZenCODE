//
//  RemoteGenerationClient+DS4Control.swift
//  ZenCODE
//
//  `/ds4` for a DS4 model: status, power, directional steering and hints of
//  the session. Nothing here is persisted (not in settings, not in saved
//  sessions) and nothing opens the model.
//
//  Power and steering
//  - With the engine already open they are applied at once, inside the
//    registry's generation lease (`withGenerationLeaseIfOpen`, so never in the
//    middle of a generation): `DS4Engine.setPower` / `setSteeringFFN` store the
//    value per session id in the engine pool, which reapplies it whenever the
//    session is recreated after an LRU eviction.
//  - Without an open engine the value is only stored in `ds4State`; the next
//    generation applies it inside its lease, before the `sync`. The same
//    happens when another model configuration replaced the engine meanwhile:
//    the values remember the engine instance they were applied to.
//  - Power is validated 1...100, steering -100...100 (the manifest range) and
//    only when the model's runtime has a steering file.
//
//  Hints
//  - The on/off preference is per session (`DS4HintsState`). The note is not
//    part of the initial system prompt, which would invalidate the whole KV
//    prefix: `prepareDS4Round` records it on the next user message
//    (`DS4MessageKeys.hintsNote`) and the renderer emits it before that message.
//

import Foundation

/// Power and steering the user set for one session. A value is "pending" for an
/// engine instance until it has been applied to that instance.
struct DS4SessionControls: Sendable, Equatable {
    var powerPercent: Int?
    var steeringScale: Double?
    /// Engine instance `powerPercent` was applied to.
    var powerEngine: ObjectIdentifier?
    /// Engine instance `steeringScale` was applied to.
    var steeringEngine: ObjectIdentifier?

    var hasValues: Bool {
        powerPercent != nil || steeringScale != nil
    }

    func hasPending(for engine: ObjectIdentifier?) -> Bool {
        (powerPercent != nil && powerEngine != engine)
            || (steeringScale != nil && steeringEngine != engine)
    }
}

/// What applying the stored controls inside a generation lease did.
struct DS4ControlApplication: Sendable {
    let engine: ObjectIdentifier
    let warnings: [String]
}

/// Facts read from the open engine for `/ds4 status`.
private struct DS4EngineSnapshot: Sendable {
    let info: DS4EngineInfo
    let stats: DS4SessionStats
    let liveSessions: Int
    let engine: ObjectIdentifier
}

extension RemoteGenerationClient {
    public func ds4Control(
        _ command: AgentDS4ControlCommand,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        guard let ds4Generation else {
            throw AgentDS4ControlError.unavailable
        }
        switch command {
        case .status:
            return try await ds4StatusResult(ds4Generation, sessionID: sessionID)
        case let .power(percent):
            return try await setDS4Power(ds4Generation, percent: percent, sessionID: sessionID)
        case let .steer(scale):
            return try await setDS4Steering(ds4Generation, scale: scale, sessionID: sessionID)
        case let .hints(enabled):
            return try setDS4Hints(enabled: enabled, sessionID: sessionID)
        }
    }

    // MARK: - Power and steering

    private func setDS4Power(
        _ ds4: DS4LocalGeneration,
        percent: Int,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        guard AgentDS4ControlCommand.powerRange.contains(percent) else {
            throw AgentDS4ControlError.invalidPower(percent)
        }
        try requireDS4ControlSession(sessionID)
        let engine = try await applyDS4ControlNow(ds4, sessionID: sessionID) { engine in
            try await engine.setPower(sessionID: sessionID, percent: percent)
        }
        var controls = ds4State.controlsBySessionID[sessionID] ?? DS4SessionControls()
        controls.powerPercent = percent
        controls.powerEngine = engine
        ds4State.controlsBySessionID[sessionID] = controls
        if engine != nil {
            ds4State.engineSessionIDs.insert(sessionID)
            return AgentDS4ControlResult(message: "DS4 power set to \(percent)% for this session.")
        }
        return AgentDS4ControlResult(
            message: "DS4 power set to \(percent)%; it is applied when the model loads, before the next prompt.",
            isApplied: false
        )
    }

    private func setDS4Steering(
        _ ds4: DS4LocalGeneration,
        scale: Double,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        guard ds4.manifest.steeringRelativePath != nil else {
            throw AgentDS4ControlError.noSteeringFile
        }
        guard scale.isFinite, AgentDS4ControlCommand.steeringRange.contains(scale) else {
            throw AgentDS4ControlError.invalidSteering(scale)
        }
        try requireDS4ControlSession(sessionID)
        let engine = try await applyDS4ControlNow(ds4, sessionID: sessionID) { engine in
            try await engine.setSteeringFFN(sessionID: sessionID, scale: scale)
        }
        var controls = ds4State.controlsBySessionID[sessionID] ?? DS4SessionControls()
        controls.steeringScale = scale
        controls.steeringEngine = engine
        ds4State.controlsBySessionID[sessionID] = controls
        let text = AgentDS4Status.formatted(scale)
        if engine != nil {
            ds4State.engineSessionIDs.insert(sessionID)
            return AgentDS4ControlResult(message: "DS4 steering FFN set to \(text) for this session.")
        }
        return AgentDS4ControlResult(
            message: "DS4 steering FFN set to \(text); it is applied when the model loads, before the next prompt.",
            isApplied: false
        )
    }

    private func requireDS4ControlSession(_ sessionID: String) throws {
        guard sessionLease(for: sessionID) != nil else {
            throw AgentDS4ControlError.sessionNotFound(sessionID)
        }
    }

    /// Runs `body` on the open engine inside the generation lease and returns
    /// the engine instance, or `nil` (nothing run) when the engine is not open.
    /// The model is never opened.
    private func applyDS4ControlNow(
        _ ds4: DS4LocalGeneration,
        sessionID: String,
        _ body: @escaping @Sendable (any DS4Engine) async throws -> Void
    ) async throws -> ObjectIdentifier? {
        // An unresolvable configuration (library not built, model moved) means
        // no engine of this manifest can be open.
        guard let configuration = try? ds4.engineConfiguration() else {
            return nil
        }
        do {
            return try await ds4.registry.withGenerationLeaseIfOpen(
                configuration: configuration,
                sessionID: sessionID
            ) { engine -> ObjectIdentifier in
                try await body(engine)
                return ObjectIdentifier(engine)
            }
        } catch let error as DS4EngineError {
            throw AgentDS4ControlError.engineRejected(error.localizedDescription)
        }
    }

    /// Applies the stored controls of a session to the engine of the lease about
    /// to run a turn. A failing change is reported (once per engine instance)
    /// and never fails the generation.
    static func applyDS4Controls(
        _ controls: DS4SessionControls?,
        to engine: any DS4Engine,
        sessionID: String
    ) async -> DS4ControlApplication? {
        guard let controls else {
            return nil
        }
        let identity = ObjectIdentifier(engine)
        guard controls.hasPending(for: identity) else {
            return nil
        }
        var warnings: [String] = []
        if let power = controls.powerPercent, controls.powerEngine != identity {
            do {
                try await engine.setPower(sessionID: sessionID, percent: power)
            } catch {
                warnings.append("DS4 power \(power)% was not applied: \(error.localizedDescription)")
            }
        }
        if let scale = controls.steeringScale, controls.steeringEngine != identity {
            do {
                try await engine.setSteeringFFN(sessionID: sessionID, scale: scale)
            } catch {
                warnings.append(
                    "DS4 steering FFN \(AgentDS4Status.formatted(scale)) was not applied: "
                        + error.localizedDescription
                )
            }
        }
        return DS4ControlApplication(engine: identity, warnings: warnings)
    }

    /// Records that a generation lease handled the stored controls, so the same
    /// engine instance is not asked again (a rejected value is not retried).
    func recordDS4ControlApplication(_ application: DS4ControlApplication, sessionID: String) {
        guard var controls = ds4State.controlsBySessionID[sessionID] else {
            return
        }
        if controls.powerPercent != nil {
            controls.powerEngine = application.engine
        }
        if controls.steeringScale != nil {
            controls.steeringEngine = application.engine
        }
        ds4State.controlsBySessionID[sessionID] = controls
    }

    // MARK: - Hints

    private func setDS4Hints(enabled: Bool, sessionID: String) throws -> AgentDS4ControlResult {
        try requireDS4ControlSession(sessionID)
        var hints = ds4State.hintsBySessionID[sessionID] ?? DS4HintsState()
        hints.enabled = enabled
        ds4State.hintsBySessionID[sessionID] = hints
        return AgentDS4ControlResult(
            message: "DS4 hints \(enabled ? "on" : "off") (applies at the next conversation boundary)."
        )
    }

    /// `agent_worker_append_hints_context`: at the start of a user turn (the last
    /// message is the new user message) asks the hints state for a note and
    /// records it on that message. `replacingRecordedNote` re-decides a message
    /// that already carries a note, after a compaction kept it in the tail.
    func applyDS4HintsBoundary(lease: SessionLease, replacingRecordedNote: Bool = false) throws {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        guard var state = ds4State.hintsBySessionID[lease.id],
              let index = session.messages.indices.last,
              DS4TranscriptRenderer.role(of: session.messages[index]) == "user" else {
            return
        }
        let hasRecordedNote = session.messages[index][DS4MessageKeys.hintsNote] != nil
        if hasRecordedNote, !replacingRecordedNote {
            return
        }
        let note = state.nextNote()
        if note != nil {
            ds4State.hintsBySessionID[lease.id] = state
        }
        guard note != nil || hasRecordedNote else {
            return
        }
        mutateSession(for: lease) { session in
            guard index < session.messages.count else {
                return
            }
            if let note {
                session.messages[index][DS4MessageKeys.hintsNote] = note
            } else {
                session.messages[index].removeValue(forKey: DS4MessageKeys.hintsNote)
            }
        }
    }

    // MARK: - Status

    private func ds4StatusResult(
        _ ds4: DS4LocalGeneration,
        sessionID: String
    ) async throws -> AgentDS4ControlResult {
        let manifest = ds4.manifest
        let library = ds4.environment.libraryStatus(manifest)
        let configuration = try? ds4.engineConfiguration()
        var snapshot: DS4EngineSnapshot?
        if let configuration {
            // Reads the live state of an engine that is already open: it waits
            // for a generation in progress but never opens the model.
            snapshot = try await ds4.registry.withGenerationLeaseIfOpen(
                configuration: configuration,
                sessionID: sessionID
            ) { engine in
                DS4EngineSnapshot(
                    info: engine.info,
                    stats: await engine.stats(sessionID: sessionID),
                    liveSessions: await engine.liveSessionCount(),
                    engine: ObjectIdentifier(engine)
                )
            }
        }

        let libraryState: AgentDS4LibraryState
        let libraryPath: String
        switch library {
        case let .built(url):
            (libraryState, libraryPath) = (.built, url.path)
        case let .missing(expected):
            (libraryState, libraryPath) = (.missing, expected.path)
        case let .stale(_, expected):
            (libraryState, libraryPath) = (.stale, expected.path)
        }

        let controls = ds4State.controlsBySessionID[sessionID]
        let steeringFile = manifest.steeringRelativePath
        let contextSize = snapshot.map { $0.stats.contextSize > 0 ? $0.stats.contextSize : $0.info.contextSize }
            ?? configuration?.contextSize
            ?? manifest.contextWindow
        let position = snapshot?.stats.position ?? 0
        let status = AgentDS4Status(
            modelID: self.configuration.modelID ?? provider.modelID,
            modelRelativePath: manifest.modelRelativePath,
            engineModelName: snapshot?.info.modelName,
            engineModelID: snapshot.map { Int($0.info.modelID) },
            engineIsOpen: snapshot != nil,
            backend: manifest.backend.rawValue,
            libraryPath: libraryPath,
            libraryState: libraryState,
            contextUsedTokens: position > 0 ? position : nil,
            contextTotalTokens: contextSize,
            cachedTokens: position > 0 ? snapshot?.stats.cachedTokens : nil,
            liveSessions: snapshot?.liveSessions,
            sessionCapacity: configuration?.sessionCapacity ?? manifest.engineSessions,
            powerPercent: controls?.powerPercent ?? manifest.power,
            powerIsOverride: controls?.powerPercent != nil,
            steeringFile: steeringFile,
            steeringScale: steeringFile == nil ? nil : (controls?.steeringScale ?? manifest.steeringFFN ?? 1),
            steeringIsOverride: controls?.steeringScale != nil,
            hasPendingControls: snapshot.map { controls?.hasPending(for: $0.engine) ?? false }
                ?? (controls?.hasValues ?? false),
            hintsEnabled: ds4State.hintsBySessionID[sessionID]?.enabled ?? false
        )
        return AgentDS4ControlResult(message: status.renderedText, status: status)
    }
}
