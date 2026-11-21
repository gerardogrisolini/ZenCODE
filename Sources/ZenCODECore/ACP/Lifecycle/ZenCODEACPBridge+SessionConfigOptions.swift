//
//  ZenCODEACPBridge+SessionConfigOptions.swift
//  ZenCODE
//
//  ACP session/set_mode, session/set_config_option, and
//  _zencode/session/set_model, with the publication of the config options of
//  a session.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODEACPBridge {
    public func setMode(id: JSONValue?, params: [String: Any]) async throws {
        try ensureNotShutDown()
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError(code: -32602, message: "Missing sessionId.")
        }
        guard sessions[sessionID] != nil else {
            throw ACPError(code: -32002, message: "Unknown session: \(sessionID)")
        }
        let modeID = ((params["modeId"] as? String) ?? (params["mode_id"] as? String) ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModeID = modeID.isEmpty ? "default" : modeID
        guard normalizedModeID == "default" || normalizedModeID == "chat" else {
            throw ACPError(code: -32602, message: "Unsupported mode: \(normalizedModeID)")
        }
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: [
                "sessionId": sessionID,
                "modeId": normalizedModeID
            ])
        )
    }

    public func setConfigOption(id: JSONValue?, params: [String: Any]) async throws {
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        guard let sessionID = Self.sessionID(from: params),
              let knownSession = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        let (reservation, session) = try await reserveReconfiguration(
            of: knownSession,
            busyMessage: "Cannot change session options while a prompt is running."
        )

        guard let configID = Self.configOptionID(from: params) else {
            try await failReconfiguration(reservation, ACPError.invalidParams("Missing configId."))
        }
        guard let value = Self.configOptionValue(from: params) else {
            try await failReconfiguration(reservation, ACPError.invalidParams("Missing config option value."))
        }
        guard configID == "model" || configID == "thinking" else {
            try await failReconfiguration(
                reservation,
                ACPError.invalidParams("Unsupported config option: \(configID)")
            )
        }

        let updatedConfiguration: AgentCoreSessionConfiguration
        switch configID {
        case "model":
            guard modelCatalog.containsModel(withID: value) else {
                try await failReconfiguration(reservation, ACPError.invalidParams("Unsupported model: \(value)"))
            }
            updatedConfiguration = session.configuration
                .withModelID(value)
                .withThinkingSelection(modelCatalog.thinkingSelection(
                    session.configuration.thinkingSelection,
                    carriedTo: value
                ))
        case "thinking":
            guard let thinkingSelection = modelCatalog.validatedThinkingSelection(
                value,
                forModelID: session.configuration.modelID
            ) else {
                try await failReconfiguration(
                    reservation,
                    ACPError.invalidParams("Unsupported thinking option: \(value)")
                )
            }
            updatedConfiguration = session.configuration.withThinkingSelection(thinkingSelection)
        default:
            try await failReconfiguration(
                reservation,
                ACPError.invalidParams("Unsupported config option: \(configID)")
            )
        }
        let sessionEpoch = session.epoch
        // Bind before the runner call: a `session/close` for this incarnation
        // must invalidate this operation, otherwise the suspended
        // `createSession` below would re-create the session in the backend and
        // answer success for a session the host already closed.
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
        do {
            try await sessionRunner.createSession(configuration: updatedConfiguration)
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            try await commitReconfiguration(
                reservation,
                configuration: updatedConfiguration,
                selectedAgent: session.selectedAgent
            )
            // Committed and still live: save before anything else suspends.
            if configID == "model" {
                persistModelSelection(of: updatedConfiguration)
            } else {
                persistThinkingSelection(updatedConfiguration.thinkingSelection)
            }
        } catch {
            await rollbackReconfiguration(reservation, originalSession: session)
            throw error
        }
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: [
                "configOptions": configOptions(
                    for: updatedConfiguration.modelID,
                    thinkingSelection: updatedConfiguration.thinkingSelection
                )
            ])
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: sessionEpoch)
    }

    public func setModel(id: JSONValue?, params: [String: Any]) async throws {
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        guard let sessionID = Self.sessionID(from: params),
              let knownSession = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        let (reservation, session) = try await reserveReconfiguration(
            of: knownSession,
            busyMessage: "Cannot change session model while a prompt is running."
        )
        guard let modelID = Self.modelID(from: params) else {
            try await failReconfiguration(reservation, ACPError.invalidParams("Missing modelId."))
        }
        guard modelCatalog.containsModel(withID: modelID) else {
            try await failReconfiguration(reservation, ACPError.invalidParams("Unsupported model: \(modelID)"))
        }

        let updatedConfiguration = session.configuration
            .withModelID(modelID)
            .withThinkingSelection(modelCatalog.thinkingSelection(
                session.configuration.thinkingSelection,
                carriedTo: modelID
            ))
        let sessionEpoch = session.epoch
        // Same close-invalidation contract as `setConfigOption`.
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
        do {
            try await sessionRunner.createSession(configuration: updatedConfiguration)
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            try await commitReconfiguration(
                reservation,
                configuration: updatedConfiguration,
                selectedAgent: session.selectedAgent
            )
            // Same save point as `setConfigOption`.
            persistModelSelection(of: updatedConfiguration)
        } catch {
            await rollbackReconfiguration(reservation, originalSession: session)
            throw error
        }
        await writer.sendResultIfRequest(id: id, result: .object([:]))
        // The model API does not return config options, so keep clients that
        // render `configOptions` (e.g. the thinking levels of the new model) in
        // sync with an agent-side `config_option_update`.
        await publishConfigOptions(sessionID: sessionID, epoch: sessionEpoch)
        await publishAvailableCommands(sessionID: sessionID, epoch: sessionEpoch)
    }

    func publishConfigOptions(sessionID: String, epoch: UInt64) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: JSONValue.acpValue(from: [
                "sessionUpdate": "config_option_update",
                "configOptions": configOptions(
                    for: session.configuration.modelID,
                    thinkingSelection: session.configuration.thinkingSelection
                )
            ])
        )
    }

    public static func configOptionID(from params: [String: Any]) -> String? {
        (params["configId"] as? String)?.nilIfBlank
            ?? (params["configID"] as? String)?.nilIfBlank
            ?? (params["config_id"] as? String)?.nilIfBlank
            ?? (params["id"] as? String)?.nilIfBlank
    }

    public static func configOptionValue(from params: [String: Any]) -> String? {
        if let value = (params["value"] as? String)?.nilIfBlank
            ?? (params["currentValue"] as? String)?.nilIfBlank
            ?? (params["current_value"] as? String)?.nilIfBlank {
            return value
        }
        if let option = params["option"] as? [String: Any] {
            return (option["value"] as? String)?.nilIfBlank
                ?? (option["id"] as? String)?.nilIfBlank
        }
        return nil
    }
}
