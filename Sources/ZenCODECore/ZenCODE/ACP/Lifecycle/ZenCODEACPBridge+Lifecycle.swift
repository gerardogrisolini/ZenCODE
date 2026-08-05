//
//  ZenCODEACPBridge+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
    public func initialize(id: JSONValue?, params: [String: Any]) async throws {
        let protocolVersion = 1
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "agentCapabilities": [
                "loadSession": true,
                "promptCapabilities": [
                    "image": true,
                    "audio": false,
                    "embeddedContext": true
                ],
                "mcpCapabilities": [
                    "http": true,
                    "sse": false
                ],
                "sessionCapabilities": [
                    "close": [:],
                    "resume": [:]
                ]
            ],
            "configOptions": configOptions(for: configuration.effectiveModelID),
            "agentInfo": [
                "name": "ZenCODE",
                "title": "ZenCODE",
                "version": agentVersion
            ],
            "authMethods": Self.authenticationMethods(from: params),
            "_meta": [
                "models": modelState(for: configuration.effectiveModelID)
            ]
        ]
        await writer.sendResultIfRequest(id: id, result: JSONValue.acpValue(from: result))
    }

    /// Some ACP clients require an authentication-method acknowledgement before
    /// starting a session even when provider authentication is managed by the
    /// agent itself.
    static func authenticationMethods(from params: [String: Any]) -> [[String: Any]] {
        let clientCapabilities = params["clientCapabilities"] as? [String: Any]
        guard clientCapabilities?["auth"] != nil else {
            return []
        }

        return [[
            "id": "zencode-client-compatibility",
            "name": "Continue with ZenCODE",
            "description": "Continue to the ZenCODE session.",
            "type": "agent"
        ]]
    }

    public func preloadModel(id: JSONValue?, params: [String: Any]) async throws {
        // `preloadModel` builds a runtime backend, so it is fenced like the
        // session-creating handlers.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        let preloadConfiguration = defaultSessionConfiguration(sessionID: "preload")
            .withModelID(Self.modelID(from: params) ?? configuration.effectiveModelID)
        let modelID = try await sessionRunner.preloadModel(
            configuration: preloadConfiguration
        ) { _ in }
        try ensureLifecycleOperationLive(operation)
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: ["modelID": modelID])
        )
    }

    public func newSession(id: JSONValue?, params: [String: Any]) async throws {
        // Claim the operation synchronously, before the first `await`: from now
        // on a concurrent `shutdown()` invalidates this token and every
        // re-check below aborts instead of creating a session or a backend.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let cwd = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: rawCwd,
            applyLaunchDirectoryFallback: false
        ).path
        await verboseACPLog(
            "session/new cwd=\(cwd) mcpServers=\(Self.mcpServerInputSummary(from: params))"
        )
        try ensureLifecycleOperationLive(operation)
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? configuration.effectiveModelID

        let selectedAgent = try resolvedACPAgentProfile(from: params)
        let sessionID = "swift-agent-\(UUID().uuidString.lowercased())"
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let workingDirectoryURL = URL(fileURLWithPath: cwd)
        let acpMCPDescriptors = await registerACPProvidedMCPServers(
            from: params,
            operation: operation
        )
        try ensureLifecycleOperationLive(operation)
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? selectedAgent?.allowedToolNames()
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectoryURL
        )
        try ensureLifecycleOperationLive(operation)
        var allowedToolNames = Self.allowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPDescriptors
        )
        if var effectiveAllowedToolNames = allowedToolNames {
            effectiveAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
            allowedToolNames = effectiveAllowedToolNames
        }
        if let selectedAgent, let effectiveAllowedToolNames = allowedToolNames {
            allowedToolNames = selectedAgent.resolvedAllowedToolNames(
                effectiveAllowedToolNames
            )
        }
        await verboseACPLog(
            "session/new allowedTools=\(Self.verboseToolNameSummary(allowedToolNames))"
        )
        try ensureLifecycleOperationLive(operation)
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
        let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let hostedManifest = configuration.hostedModels.map { hostedModels in
            AgentSettingsManifest(
                models: hostedModels,
                selectedModelID: modelID
            )
        }
        let thinkingSelection = AgentSettingsStore.thinkingSelection(
            requestedSelection: requestedThinkingSelection,
            explicitModelID: requestedModelID ?? configuration.modelID,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection,
            manifest: hostedManifest ?? AgentSettingsManifestStore.load()
        )
        let preserveThinking = (params["preserveThinking"] as? Bool) ?? false
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectory: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: runtimeHistory(from: params["history"]),
            allowedToolNames: allowedToolNames,
            maxToolRounds: self.configuration.maxToolRounds,
            maxOutputTokens: self.configuration.maxOutputTokens,
            verboseLogging: self.configuration.verboseLogging,
            appMode: self.configuration.appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        // Last fence before any observable effect. Past this point the session
        // entry, the runner session and the JSON-RPC reply are published, so a
        // shutdown that lands *here* must abort rather than leave a live
        // session and a backend behind a closed transport.
        try ensureLifecycleOperationLive(operation)
        let sessionEntry = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent
        )
        let sessionEpoch = sessionEntry.epoch
        sessions[sessionID] = sessionEntry
        // From here the session exists, so a `session/close` for it must be
        // able to invalidate this handler before it answers.
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
        updateSessionSleepAssertion()
        do {
            try await sessionRunner.createSession(configuration: configuration)
        } catch {
            // Do not leave a session entry that has no runner session behind.
            // Scope the removal to our own incarnation so a racing handler's
            // newer session is never dropped.
            discardSessionIfCurrent(id: sessionID, epoch: sessionEpoch)
            throw error
        }
        // `createSession` suspends: if shutdown landed during it, drop the
        // session we just created instead of announcing it to a closing host.
        guard isLifecycleOperationLive(operation) else {
            discardSessionIfCurrent(id: sessionID, epoch: sessionEpoch)
            throw ACPShutdownFenceError()
        }

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
    }

    public func resolvedAllowedToolNames(
        _ requestedAllowedToolNames: Set<String>?,
        workingDirectory: URL
    ) async -> Set<String>? {
        _ = workingDirectory
        return ExternalToolAvailability.resolvedAllowedToolNames(requestedAllowedToolNames)
    }

    public func registerACPProvidedMCPServers(
        from params: [String: Any],
        operation: UInt64? = nil
    ) async -> [DirectToolDescriptor] {
        let definitions = Self.mcpServerDefinitions(from: params)
        await verboseACPLog(
            "ACP mcpServers input=\(Self.mcpServerInputSummary(from: params)) parsed=\(definitions.count)"
        )
        await verboseACPLog(
            "ACP mcpServers detail=\(Self.mcpServerInputDetails(from: params))"
        )
        guard !definitions.isEmpty else {
            return []
        }

        var descriptors: [DirectToolDescriptor] = []
        for definition in definitions {
            // Re-check per iteration, not only after the whole loop: each
            // install suspends, so a shutdown landing inside one must stop the
            // remaining definitions from connecting new servers at all.
            if let operation, !isLifecycleOperationLive(operation) {
                return []
            }
            do {
                await verboseACPLog(
                    "connecting ACP MCP server name=\(definition.name) type=\(definition.type)"
                )
                let installedDescriptors = try await sessionRunner.installACPProvidedMCPServer(
                    name: definition.name,
                    configuration: definition.configuration
                )
                                        await verboseACPLog(
                    "installed ACP MCP server name=\(definition.name) tools=\(Self.verboseDescriptorSummary(installedDescriptors))"
                )
                descriptors.append(contentsOf: installedDescriptors)
            } catch {
                await verboseACPLog(
                    "failed ACP MCP server name=\(definition.name): \(error.localizedDescription)"
                )
                ZenLogger.warning(
                    .viewModelRuntime,
                    "failed to install ACP MCP server '\(definition.name)': \(error.localizedDescription)"
                )
            }
        }
        return DirectToolExecutor.canonicalized(descriptors)
    }

    public func loadSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: true)
    }

    public func resumeSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: false)
    }

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
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard case .idle = session.operationState,
              session.activePromptTask == nil,
              session.activePromptID == nil else {
            throw ACPError.invalidParams("Cannot change session options while a prompt is running.")
        }

        guard let configID = Self.configOptionID(from: params) else {
            throw ACPError.invalidParams("Missing configId.")
        }
        guard let value = Self.configOptionValue(from: params) else {
            throw ACPError.invalidParams("Missing config option value.")
        }
        guard configID == "model" || configID == "thinking" else {
            throw ACPError.invalidParams("Unsupported config option: \(configID)")
        }

        let updatedConfiguration: AgentCoreSessionConfiguration
        switch configID {
        case "model":
            let availableModels = modelConfigOptions()
            guard availableModels.contains(where: { option in
                (option["value"] as? String) == value
            }) else {
                throw ACPError.invalidParams("Unsupported model: \(value)")
            }
            let model = modelManifest(for: value)
            updatedConfiguration = session.configuration
                .withModelID(value)
                .withThinkingSelection(model?.thinkingSelection(
                    for: session.configuration.thinkingSelection
                ))
        case "thinking":
            guard let model = modelManifest(for: session.configuration.modelID),
                  let requestedSelection = AgentThinkingSelection(rawValue: value),
                  let thinkingSelection = model.thinkingSelection(for: requestedSelection),
                  thinkingSelection == requestedSelection else {
                throw ACPError.invalidParams("Unsupported thinking option: \(value)")
            }
            updatedConfiguration = session.configuration.withThinkingSelection(thinkingSelection)
        default:
            throw ACPError.invalidParams("Unsupported config option: \(configID)")
        }
        let sessionEpoch = session.epoch
        let reconfigurationID = UUID()
        var reconfiguringSession = session
        reconfiguringSession.operationState = .reconfiguring(reconfigurationID)
        sessions[sessionID] = reconfiguringSession
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
            try commitReconfiguration(
                sessionID: sessionID,
                epoch: sessionEpoch,
                reconfigurationID: reconfigurationID,
                configuration: updatedConfiguration,
                selectedAgent: session.selectedAgent
            )
        } catch {
            await rollbackReconfiguration(
                sessionID: sessionID,
                epoch: sessionEpoch,
                reconfigurationID: reconfigurationID,
                originalSession: session
            )
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
    }

    public func setModel(id: JSONValue?, params: [String: Any]) async throws {
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard case .idle = session.operationState,
              session.activePromptTask == nil,
              session.activePromptID == nil else {
            throw ACPError.invalidParams("Cannot change session model while a prompt is running.")
        }
        guard let modelID = Self.modelID(from: params) else {
            throw ACPError.invalidParams("Missing modelId.")
        }
        guard modelConfigOptions().contains(where: { option in
            (option["value"] as? String) == modelID
        }) else {
            throw ACPError.invalidParams("Unsupported model: \(modelID)")
        }

        let model = modelManifest(for: modelID)
        let updatedConfiguration = session.configuration
            .withModelID(modelID)
            .withThinkingSelection(model?.thinkingSelection(
                for: session.configuration.thinkingSelection
            ))
        let sessionEpoch = session.epoch
        let reconfigurationID = UUID()
        var reconfiguringSession = session
        reconfiguringSession.operationState = .reconfiguring(reconfigurationID)
        sessions[sessionID] = reconfiguringSession
        // Same close-invalidation contract as `setConfigOption`.
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
        do {
            try await sessionRunner.createSession(configuration: updatedConfiguration)
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            try commitReconfiguration(
                sessionID: sessionID,
                epoch: sessionEpoch,
                reconfigurationID: reconfigurationID,
                configuration: updatedConfiguration,
                selectedAgent: session.selectedAgent
            )
        } catch {
            await rollbackReconfiguration(
                sessionID: sessionID,
                epoch: sessionEpoch,
                reconfigurationID: reconfigurationID,
                originalSession: session
            )
            throw error
        }
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    /// Re-check for the handlers that reconfigure an existing session through
    /// the runner.
    ///
    /// `createSession` suspends, so a `session/close` or `shutdown` can land
    /// inside it and re-create the session in the runner after the host already
    /// dropped it. When that happened, undo the resurrection before failing, so
    /// no orphan runner session survives a closed ACP session.
    private func ensureLifecycleOperationLiveAfterSessionWrite(
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

    /// Commits only the reconfiguration reserved by this operation. A matching
    /// state check makes a later operation unable to publish over an earlier
    /// one that was cancelled, closed, or rolled back.
    private func commitReconfiguration(
        sessionID: String,
        epoch: UInt64,
        reconfigurationID: UUID,
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?
    ) throws {
        guard let currentState = liveSession(id: sessionID, epoch: epoch),
              case let .reconfiguring(activeID) = currentState.operationState,
              activeID == reconfigurationID else {
            throw ACPShutdownFenceError()
        }
        sessions[sessionID] = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent,
            epoch: epoch
        )
    }

    /// Rebuilds the prior runner configuration, then releases the reservation.
    /// If close/shutdown invalidated the incarnation, nothing is restored: the
    /// close path owns the backend cleanup in that case.
    private func rollbackReconfiguration(
        sessionID: String,
        epoch: UInt64,
        reconfigurationID: UUID,
        originalSession: SessionState
    ) async {
        guard let priorState = liveSession(id: sessionID, epoch: epoch),
              case let .reconfiguring(activeID) = priorState.operationState,
              activeID == reconfigurationID else {
            return
        }
        _ = try? await sessionRunner.createSession(
            configuration: originalSession.configuration
        )
        guard let currentState = liveSession(id: sessionID, epoch: epoch),
              case let .reconfiguring(activeID) = currentState.operationState,
              activeID == reconfigurationID else {
            return
        }
        sessions[sessionID] = originalSession
    }

        public func restoreSession(
        id: JSONValue?,
        params: [String: Any],
        replayHistory: Bool
    ) async throws {
        // Same claim-before-first-await rule as `newSession`: `session/load`
        // and `session/resume` also create sessions and backends.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        // A session_id is optional: stateless clients can resume by resending
        // their transcript. When omitted we mint an internal session id.
        let sessionID = Self.sessionID(from: params)
            ?? "swift-agent-\(UUID().uuidString.lowercased())"
        if let session = sessions[sessionID] {
            // Bind to the incarnation we are about to replay/answer for: a
            // `session/close` landing inside `snapshotSession` must stop this
            // handler from replaying history and reporting success for a
            // session that no longer exists.
            bindLifecycleOperation(operation, sessionID: sessionID, epoch: session.epoch)
            if replayHistory,
               let snapshot = await sessionRunner.snapshotSession(id: sessionID) {
                try ensureLifecycleOperationLive(operation)
                await replaySessionHistory(snapshot)
            }
            try ensureLifecycleOperationLive(operation)
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
            )
            try ensureLifecycleOperationLive(operation)
            await sendSessionInfoUpdate(
                sessionID: sessionID,
                title: URL(fileURLWithPath: session.cwd).lastPathComponent
            )
            return
        }

        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let workingDirectory = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: rawCwd,
            applyLaunchDirectoryFallback: false
        )
        await verboseACPLog(
            "session/restore id=\(sessionID) cwd=\(workingDirectory.path) replay=\(replayHistory) mcpServers=\(Self.mcpServerInputSummary(from: params))"
        )
        try ensureLifecycleOperationLive(operation)
        let acpMCPDescriptors = await registerACPProvidedMCPServers(
            from: params,
            operation: operation
        )
        try ensureLifecycleOperationLive(operation)
        let selectedAgent = try resolvedACPAgentProfile(from: params)
        let configuration = await restoredACPClientSessionConfiguration(
            sessionID: sessionID,
            params: params,
            workingDirectory: workingDirectory,
            acpMCPDescriptors: acpMCPDescriptors,
            selectedAgent: selectedAgent
        )
        try ensureLifecycleOperationLive(operation)
        await verboseACPLog(
            "session/restore allowedTools=\(Self.verboseToolNameSummary(configuration.allowedToolNames)) history=\(configuration.history.count)"
        )
        // Last fence before the session entry, the runner session, the history
        // replay and the reply become observable.
        try ensureLifecycleOperationLive(operation)
        let sessionEntry = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent
        )
        let sessionEpoch = sessionEntry.epoch
        sessions[sessionID] = sessionEntry
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
        updateSessionSleepAssertion()
        do {
            try await sessionRunner.restoreSession(configuration: configuration)
        } catch {
            discardSessionIfCurrent(id: sessionID, epoch: sessionEpoch)
            throw error
        }
        try await ensureLifecycleOperationLiveAfterSessionWrite(
            operation,
            sessionID: sessionID
        )
        if replayHistory {
            await replaySessionHistory(
                AgentRuntimeSessionSnapshot(
                    sessionID: configuration.sessionID,
                    modelID: configuration.modelID,
                    workingDirectoryPath: configuration.workingDirectoryPath,
                    systemPrompt: configuration.systemPrompt,
                    cacheKey: configuration.cacheKey,
                    history: configuration.history,
                    allowedToolNames: configuration.allowedToolNames,
                    thinkingSelection: configuration.thinkingSelection,
                    preserveThinking: configuration.preserveThinking
                )
            )
            try ensureLifecycleOperationLive(operation)
        }

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        try ensureLifecycleOperationLive(operation)
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: workingDirectory.lastPathComponent
        )
    }

    public static func sessionID(from params: [String: Any]) -> String? {
        for key in ["sessionId", "session_id", "id"] {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
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

    public static func modelID(from params: [String: Any]) -> String? {
        if let value = (params["modelId"] as? String)?.nilIfBlank
            ?? (params["modelID"] as? String)?.nilIfBlank
            ?? (params["model_id"] as? String)?.nilIfBlank
            ?? (params["currentModelId"] as? String)?.nilIfBlank
            ?? (params["current_model_id"] as? String)?.nilIfBlank
            ?? (params["model"] as? String)?.nilIfBlank {
            return value
        }
        if let config = params["config"] as? [String: Any],
           let value = (config["model"] as? String)?.nilIfBlank
               ?? (config["modelId"] as? String)?.nilIfBlank
               ?? (config["model_id"] as? String)?.nilIfBlank {
            return value
        }
        if let models = params["models"] as? [String: Any] {
            return (models["currentModelId"] as? String)?.nilIfBlank
                ?? (models["current_model_id"] as? String)?.nilIfBlank
        }
        return nil
    }

    private func defaultSessionConfiguration(
        sessionID: String
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: configuration.effectiveModelID,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: nil,
            preserveThinking: false
        )
    }

    public func restoredACPClientSessionConfiguration(
        sessionID: String,
        params: [String: Any],
        workingDirectory: URL,
        acpMCPDescriptors: [DirectToolDescriptor],
        selectedAgent: AgentProfile? = nil
    ) async -> AgentCoreSessionConfiguration {
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? configuration.effectiveModelID
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? selectedAgent?.allowedToolNames()
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectory
        )
        var allowedToolNames = Self.allowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPDescriptors
        )
        if var effectiveAllowedToolNames = allowedToolNames {
            effectiveAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
            allowedToolNames = effectiveAllowedToolNames
        }
        if let selectedAgent, let effectiveAllowedToolNames = allowedToolNames {
            allowedToolNames = selectedAgent.resolvedAllowedToolNames(
                effectiveAllowedToolNames
            )
        }
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
        let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let hostedManifest = configuration.hostedModels.map { hostedModels in
            AgentSettingsManifest(
                models: hostedModels,
                selectedModelID: modelID
            )
        }
        let thinkingSelection = AgentSettingsStore.thinkingSelection(
            requestedSelection: requestedThinkingSelection,
            explicitModelID: requestedModelID ?? configuration.modelID,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection,
            manifest: hostedManifest ?? AgentSettingsManifestStore.load()
        )
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let preserveThinking = (params["preserveThinking"] as? Bool)
            ?? (params["preserve_thinking"] as? Bool)
            ?? false

        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: runtimeHistory(from: params["history"]),
            allowedToolNames: allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public func sessionLifecycleResult(sessionID: String) -> [String: Any] {
        let session = sessions[sessionID]
        let sessionConfiguration = session?.configuration
        let modelID = sessionConfiguration?.modelID
            ?? configuration.effectiveModelID
        var result: [String: Any] = [
            "sessionId": sessionID,
            "modes": [
                "availableModes": [
                    [
                        "id": "default",
                        "name": "Default",
                        "description": "Use the configured ZenCODE agent runtime."
                    ],
                    [
                        "id": "chat",
                        "name": "Chat",
                        "description": "Alias for the default ZenCODE agent runtime."
                    ]
                ],
                "currentModeId": "default"
            ],
            "configOptions": configOptions(
                for: modelID,
                thinkingSelection: sessionConfiguration?.thinkingSelection
            ),
            "_meta": [
                "models": modelState(for: modelID)
            ]
        ]
        if let selectedAgent = session?.selectedAgent {
            result["agentId"] = selectedAgent.id
            result["agentName"] = selectedAgent.name
        }
        return result
    }

}
