//
//  ZenCODEACPBridge+Reconfiguration.swift
//  ZenCODE
//
//  Reservation, commit, and rollback of the reconfiguration of an ACP session
//  (session/set_config_option and _zencode/session/set_model).
//

import Foundation

extension ZenCODEACPBridge {
    /// Reserves, in the host, the reconfiguration of the incarnation `session`
    /// names: from here no prompt can be reserved on it until the
    /// reconfiguration commits, rolls back, or fails. Answers as the bridge
    /// always did: `busyMessage` while a prompt (or another reconfiguration)
    /// holds the session, the unknown-session error when the entry is not this
    /// incarnation anymore after the hop, and silence after a shutdown.
    ///
    /// Returns with the reservation the entry as it is after the hop, which
    /// the reconfiguration starts from: a prompt that ended while the host
    /// was asked (an agent mention routes the session to another agent) may
    /// have written it since `session` was read.
    func reserveReconfiguration(
        of session: SessionState,
        busyMessage: String
    ) async throws -> (reservation: ChatReconfigurationReservation, session: SessionState) {
        let reservation: ChatReconfigurationReservation
        do {
            reservation = try await host.reserveReconfiguration(in: session.slotID)
        } catch {
            throw acpError(for: error, busyMessage: busyMessage)
        }
        guard let current = liveSession(id: session.id, epoch: session.epoch) else {
            await host.releaseReconfiguration(reservation)
            try ensureNotShutDown()
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        return (reservation, current)
    }

    /// Releases a reservation whose operation stops at a parameter check, and
    /// throws `error`.
    func failReconfiguration(
        _ reservation: ChatReconfigurationReservation,
        _ error: Error
    ) async throws -> Never {
        await host.releaseReconfiguration(reservation)
        throw error
    }

    /// Re-check for the handlers that reconfigure an existing session through
    /// the runner.
    ///
    /// `createSession` suspends, so a `session/close` or `shutdown` can land
    /// inside it and re-create the session in the runner after the host already
    /// dropped it. When that happened, undo the resurrection before failing, so
    /// no orphan runner session survives a closed ACP session.
    func ensureLifecycleOperationLiveAfterSessionWrite(
        _ operation: UInt64,
        sessionID: String
    ) async throws {
        guard !isLifecycleOperationLive(operation) else {
            return
        }
        // Only clean up when the id is genuinely gone: if a newer incarnation
        // exists, it owns the runner session and must not be torn down.
        if sessions[sessionID] == nil {
            await sessionRunner.closeSession(id: sessionID)
        }
        throw ACPShutdownFenceError()
    }

    /// Commits only the reconfiguration reserved by this operation. The ACP
    /// state is written first, while the reservation still keeps every prompt
    /// out, then the reservation is released in the host: no prompt can
    /// observe the previous configuration under a released reservation. A
    /// reservation that is gone (the incarnation ended) commits nothing: the
    /// entry is gone with it, or the write is undone.
    func commitReconfiguration(
        _ reservation: ChatReconfigurationReservation,
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?
    ) async throws {
        let previous = liveSession(id: reservation.sessionID, epoch: reservation.epoch)
        let written = updateLiveSession(id: reservation.sessionID, epoch: reservation.epoch) { live in
            live = sessionState(configuration: configuration, selectedAgent: selectedAgent, inheriting: live)
        }
        guard written else {
            throw ACPShutdownFenceError()
        }
        guard await host.releaseReconfiguration(reservation) else {
            if let previous {
                updateLiveSession(id: reservation.sessionID, epoch: reservation.epoch) { $0 = previous }
            }
            throw ACPShutdownFenceError()
        }
    }

    /// Saves a committed model choice, with the thinking level it resulted
    /// in, as the default of the next sessions (nothing with hosted models,
    /// see ``ChatModelCatalog/persistsSelections``).
    ///
    /// Call it only right after a successful `commitReconfiguration` and
    /// before any suspension, so the operation is still the live one. A
    /// failed write is logged and never changes the response.
    func persistModelSelection(
        of sessionConfiguration: AgentCoreSessionConfiguration
    ) {
        guard let modelID = sessionConfiguration.modelID else {
            return
        }
        do {
            try modelCatalog.saveModelSelection(
                modelID: modelID,
                thinking: sessionConfiguration.thinkingSelection
            )
        } catch {
            ZenLogger.warning(
                .viewModelRuntime,
                "failed to save the ACP model selection '\(modelID)': \(error.localizedDescription)"
            )
        }
    }

    /// Saves a committed thinking choice as the default of the next sessions,
    /// under the same rules as ``persistModelSelection(of:)``.
    func persistThinkingSelection(_ selection: AgentThinkingSelection?) {
        do {
            try modelCatalog.saveThinkingSelection(selection)
        } catch {
            ZenLogger.warning(
                .viewModelRuntime,
                "failed to save the ACP thinking selection '\(selection?.rawValue ?? "default")': \(error.localizedDescription)"
            )
        }
    }

    /// Rebuilds the prior runner configuration, then releases the reservation.
    /// If close/shutdown invalidated the incarnation, nothing is restored: the
    /// close path owns the backend cleanup in that case.
    func rollbackReconfiguration(
        _ reservation: ChatReconfigurationReservation,
        originalSession: SessionState
    ) async {
        guard liveSession(id: reservation.sessionID, epoch: reservation.epoch) != nil,
              await host.holdsReconfiguration(reservation) else {
            return
        }
        _ = try? await sessionRunner.createSession(
            configuration: originalSession.configuration
        )
        guard liveSession(id: reservation.sessionID, epoch: reservation.epoch) != nil,
              await host.holdsReconfiguration(reservation) else {
            return
        }
        // The ACP state goes back first, then the reservation is released:
        // the next prompt reads the restored configuration.
        updateLiveSession(id: reservation.sessionID, epoch: reservation.epoch) { live in
            live = sessionState(
                configuration: originalSession.configuration,
                selectedAgent: originalSession.selectedAgent,
                inheriting: live
            )
        }
        await host.releaseReconfiguration(reservation)
    }
}
