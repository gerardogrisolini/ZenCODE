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
        try ensureNotShutDown()
        clientFileSystem = ACPClientFileSystem.negotiated(writer: writer, params: params)
        let protocolVersion = 1
        let authMethods = Self.authenticationMethods(from: params)
        advertisedAuthenticationMethodIDs = Set(
            authMethods.compactMap { $0["id"] as? String }
        )
        let defaultModelID = defaultSessionModelID()
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
            "configOptions": configOptions(for: defaultModelID),
            "agentInfo": [
                "name": "ZenCODE",
                "title": "ZenCODE",
                "version": agentVersion
            ],
            "authMethods": authMethods,
            "_meta": [
                "models": modelState(for: defaultModelID)
            ]
        ]
        await writer.sendResultIfRequest(id: id, result: JSONValue.acpValue(from: result))
    }

    public func authenticate(id: JSONValue?, params: [String: Any]) async throws {
        try ensureNotShutDown()

        guard let methodID = params["methodId"] as? String else {
            throw ACPError.invalidParams("Missing or invalid methodId.")
        }
        guard advertisedAuthenticationMethodIDs.contains(methodID) else {
            throw ACPError.invalidParams("Authentication method was not advertised: \(methodID)")
        }

        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    /// Authentication methods advertised by `initialize`, depending on what the
    /// client declares in `clientCapabilities`.
    ///
    /// - `zencode-client-compatibility` (`type: agent`): offered to clients that
    ///   declare an `auth` capability. Some ACP clients require an
    ///   authentication-method acknowledgement before starting a session even
    ///   when provider authentication is managed by the agent itself, so this
    ///   method is a no-op acknowledgement.
    /// - `zencode-setup` (`type: terminal`): offered to clients that declare
    ///   `_meta.terminal-auth: true`, the ACP terminal-authentication
    ///   extension. The client launches the agent with the method's `args` in
    ///   place of the default ones; the empty `args` here make it run plain
    ///   `zen`, which opens the interactive setup (provider and sign-in) when
    ///   ZenCODE is not configured yet, and exits once it completes. The client
    ///   then reconnects and initializes the agent again.
    ///
    /// The agent method, when present, always comes first. A client declaring
    /// neither capability receives no authentication method.
    static func authenticationMethods(from params: [String: Any]) -> [[String: Any]] {
        let clientCapabilities = params["clientCapabilities"] as? [String: Any]
        var methods: [[String: Any]] = []

        if clientCapabilities?["auth"] != nil {
            methods.append([
                "id": "zencode-client-compatibility",
                "name": "Continue with ZenCODE",
                "description": "Continue to the ZenCODE session.",
                "type": "agent"
            ])
        }

        let clientMeta = clientCapabilities?["_meta"] as? [String: Any]
        if clientMeta?["terminal-auth"] as? Bool == true {
            methods.append([
                "id": "zencode-setup",
                "name": "Set up ZenCODE",
                "type": "terminal",
                "args": [String]()
            ])
        }

        return methods
    }

    public func preloadModel(id: JSONValue?, params: [String: Any]) async throws {
        try ensureConfigured()
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
        try ensureConfigured()
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
        try ensureLifecycleOperationLive(operation)
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? defaultSessionModelID()

        let workingDirectoryURL = URL(fileURLWithPath: cwd)
        let selectedAgent = try resolvedACPAgentProfile(
            from: params,
            workingDirectory: workingDirectoryURL
        )
        let sessionID = "swift-agent-\(UUID().uuidString.lowercased())"
        // Open the incarnation in the host before the MCP servers are
        // installed: the ownership stamped on those registrations must
        // identify exactly the session incarnation this handler is about to
        // publish, so a failed or fenced creation can release them again.
        let incarnation = try await openACPSession(sessionID: sessionID, cwd: cwd)
        let sessionEpoch = incarnation.epoch
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        // MCP servers installed below carry this incarnation's ownership. Every
        // `throw` from here on means this incarnation never became (or did not
        // stay) live, so the catch releases its registrations before
        // propagating; a successful exit keeps them bound to the live session.
        do {
            try ensureLifecycleOperationLive(operation)
            let acpMCPDescriptors = await registerACPProvidedMCPServers(
                from: params,
                ownership: DirectMCPToolRuntime.MCPSessionOwnership(
                    sessionID: sessionID,
                    epoch: sessionEpoch
                ),
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
            try ensureLifecycleOperationLive(operation)
            let promptSections = resolvedPromptSections(
                providedSystemPrompt: nil,
                cwd: cwd,
                allowedToolNames: allowedToolNames,
                selectedAgent: selectedAgent
            )
            let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
            let thinkingSelection = modelCatalog.resolvedThinkingSelection(
                requested: requestedThinkingSelection,
                explicitModelID: requestedModelID ?? configuration.modelID,
                agentModelID: selectedAgent?.modelID,
                agentThinkingSelection: selectedAgent?.thinkingSelection,
                selectedModelID: modelID
            )
            let preserveThinking = (params["preserveThinking"] as? Bool) ?? false
            let runnerConfiguration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: modelID,
                agentID: selectedAgent?.id,
                agentName: selectedAgent?.name,
                agentRole: selectedAgent?.role,
                workingDirectory: cwd,
                systemPrompt: promptSections.systemPrompt,
                dynamicContext: promptSections.dynamicContext,
                cacheKey: cacheKey,
                history: Self.runtimeHistory(from: params["history"]),
                allowedToolNames: allowedToolNames,
                maxToolRounds: self.configuration.maxToolRounds,
                maxOutputTokens: self.configuration.maxOutputTokens,
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
                configuration: runnerConfiguration,
                selectedAgent: selectedAgent,
                incarnation: incarnation
            )
            sessions[sessionID] = sessionEntry
            // From here the session exists, so a `session/close` for it must be
            // able to invalidate this handler before it answers.
            bindLifecycleOperation(operation, sessionID: sessionID, epoch: sessionEpoch)
            do {
                try await sessionRunner.createSession(configuration: runnerConfiguration)
            } catch {
                // Do not leave a session entry that has no runner session behind.
                // Scope the removal to our own incarnation so a racing handler's
                // newer session is never dropped.
                await discardSessionIfCurrent(id: sessionID, epoch: sessionEpoch)
                throw error
            }
            // `createSession` suspends: if shutdown landed during it, drop the
            // session we just created instead of announcing it to a closing host.
            guard isLifecycleOperationLive(operation) else {
                await discardSessionIfCurrent(id: sessionID, epoch: sessionEpoch)
                throw ACPShutdownFenceError()
            }
        } catch {
            // This incarnation never became live, or was discarded again: its
            // host slot (closed already when it was discarded) and its MCP
            // registrations are orphaned, so release them before propagating
            // the failure.
            await closeACPSlot(of: incarnation)
            await sessionRunner.releaseSessionMCPOwnership(
                sessionID: sessionID,
                epoch: sessionEpoch
            )
            throw error
        }

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: sessionEpoch)
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
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil,
        operation: UInt64? = nil
    ) async -> [DirectToolDescriptor] {
        let definitions = Self.mcpServerDefinitions(from: params)
        guard !definitions.isEmpty else {
            return []
        }

        var descriptors: [DirectToolDescriptor] = []
        for definition in definitions {
            // Re-check per iteration, not only after the whole loop: each
            // install suspends, so a shutdown landing inside one must stop the
            // remaining definitions from connecting new servers at all.
            if let operation, !isLifecycleOperationLive(operation) {
                // Servers already installed for this incarnation are orphaned
                // by the aborted creation: release them before bailing out.
                if let ownership {
                    await sessionRunner.releaseSessionMCPOwnership(
                        sessionID: ownership.sessionID,
                        epoch: ownership.epoch
                    )
                }
                return []
            }
            do {
                let installedDescriptors = try await sessionRunner.installACPProvidedMCPServer(
                    name: definition.name,
                    configuration: definition.configuration,
                    ownership: ownership
                )
                descriptors.append(contentsOf: installedDescriptors)
            } catch {
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
        let reservation = try await reserveReconfiguration(
            of: session,
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
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        let reservation = try await reserveReconfiguration(
            of: session,
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

    /// Reserves, in the host, the reconfiguration of the incarnation `session`
    /// names: from here no prompt can be reserved on it until the
    /// reconfiguration commits, rolls back, or fails. Answers as the bridge
    /// always did: `busyMessage` while a prompt (or another reconfiguration)
    /// holds the session, the unknown-session error when the entry is not this
    /// incarnation anymore after the hop, and silence after a shutdown.
    private func reserveReconfiguration(
        of session: SessionState,
        busyMessage: String
    ) async throws -> ChatReconfigurationReservation {
        let reservation: ChatReconfigurationReservation
        do {
            reservation = try await host.reserveReconfiguration(in: session.slotID)
        } catch {
            throw acpError(for: error, busyMessage: busyMessage)
        }
        guard liveSession(id: session.id, epoch: session.epoch) != nil else {
            await host.releaseReconfiguration(reservation)
            try ensureNotShutDown()
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        return reservation
    }

    /// Releases a reservation whose operation stops at a parameter check, and
    /// throws `error`.
    private func failReconfiguration(
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

    /// Commits only the reconfiguration reserved by this operation. The ACP
    /// state is written first, while the reservation still keeps every prompt
    /// out, then the reservation is released in the host: no prompt can
    /// observe the previous configuration under a released reservation. A
    /// reservation that is gone (the incarnation ended) commits nothing: the
    /// entry is gone with it, or the write is undone.
    private func commitReconfiguration(
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
    private func persistModelSelection(
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
    private func persistThinkingSelection(_ selection: AgentThinkingSelection?) {
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
    private func rollbackReconfiguration(
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

        public func restoreSession(
        id: JSONValue?,
        params: [String: Any],
        replayHistory: Bool
    ) async throws {
        try ensureConfigured()
        // Same claim-before-first-await rule as `newSession`: `session/load`
        // and `session/resume` also create sessions and backends.
        let operation = try registerLifecycleOperation()
        defer { finishLifecycleOperation(operation) }

        // A session_id is optional: stateless clients can resume by resending
        // their transcript. When omitted we mint an internal session id.
        let sessionID = Self.sessionID(from: params)
            ?? "swift-agent-\(UUID().uuidString.lowercased())"
        if let session = sessions[sessionID] {
            // Bind before the first suspension: a concurrent close must fence
            // both the Planner teardown and the subsequent replay/reply.
            bindLifecycleOperation(operation, sessionID: sessionID, epoch: session.epoch)
            // ACP load/resume is a restore boundary even when the client reuses
            // an already-live id. Never infer an unfinished Planner exchange
            // from replayed chat history.
            await clearACPPlanBrainstorming(sessionID: sessionID, epoch: session.epoch)
            // The approval handshake is the controller's transient state: it
            // is cleared under the controller's lock, inside the fenced step.
            _ = updateLiveSession(id: sessionID, epoch: session.epoch) { live in
                live.controller.commitCommandState(ifToken: nil) { $0.pendingPlanApprovalPlanID = nil }
            }
            try ensureLifecycleOperationLive(operation)
            // The remaining replay belongs to the same fenced incarnation.
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
        try ensureLifecycleOperationLive(operation)
        // Same early incarnation as `newSession`: the MCP registrations
        // installed below carry the ownership of the incarnation this handler
        // is about to publish, so a fenced or failed restore can release them.
        let incarnation = try await openACPSession(sessionID: sessionID, cwd: workingDirectory.path)
        let restoredSessionEpoch = incarnation.epoch
        // Every `throw` after the installs began means this incarnation never
        // became (or did not stay) live, so the catch releases its MCP
        // registrations before propagating.
        do {
            try ensureLifecycleOperationLive(operation)
            let acpMCPDescriptors = await registerACPProvidedMCPServers(
                from: params,
                ownership: DirectMCPToolRuntime.MCPSessionOwnership(
                    sessionID: sessionID,
                    epoch: restoredSessionEpoch
                ),
                operation: operation
            )
            try ensureLifecycleOperationLive(operation)
            let selectedAgent = try resolvedACPAgentProfile(
                from: params,
                workingDirectory: workingDirectory
            )
            let configuration = await restoredACPClientSessionConfiguration(
                sessionID: sessionID,
                params: params,
                workingDirectory: workingDirectory,
                acpMCPDescriptors: acpMCPDescriptors,
                selectedAgent: selectedAgent
            )
            try ensureLifecycleOperationLive(operation)
            // Last fence before the session entry, the runner session, the history
            // replay and the reply become observable.
            try ensureLifecycleOperationLive(operation)
            let sessionEntry = sessionState(
                configuration: configuration,
                selectedAgent: selectedAgent,
                incarnation: incarnation
            )
            sessions[sessionID] = sessionEntry
            bindLifecycleOperation(operation, sessionID: sessionID, epoch: restoredSessionEpoch)
            try await sessionRunner.restoreSession(configuration: configuration)
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
                        dynamicContext: configuration.dynamicContext,
                        cacheKey: configuration.cacheKey,
                        history: configuration.history,
                        allowedToolNames: configuration.allowedToolNames,
                        thinkingSelection: configuration.thinkingSelection,
                        preserveThinking: configuration.preserveThinking
                    )
                )
                try ensureLifecycleOperationLive(operation)
            }
        } catch {
            // The incarnation never became live, or was discarded again: drop
            // the entry we may have published, close its host slot, and
            // release its orphaned MCP registrations before propagating the
            // failure.
            await discardSessionIfCurrent(id: sessionID, epoch: restoredSessionEpoch)
            await closeACPSlot(of: incarnation)
            await sessionRunner.releaseSessionMCPOwnership(
                sessionID: sessionID,
                epoch: restoredSessionEpoch
            )
            throw error
        }
        try ensureLifecycleOperationLive(operation)

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        try ensureLifecycleOperationLive(operation)
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: workingDirectory.lastPathComponent
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: restoredSessionEpoch)
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
            agentID: configuration.selectedAgent?.id,
            agentName: configuration.selectedAgent?.name,
            agentRole: configuration.selectedAgent?.role,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
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
            ?? defaultSessionModelID()
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
        let promptSections = resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
        let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let thinkingSelection = modelCatalog.resolvedThinkingSelection(
            requested: requestedThinkingSelection,
            explicitModelID: requestedModelID ?? configuration.modelID,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection,
            selectedModelID: modelID
        )
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let preserveThinking = (params["preserveThinking"] as? Bool)
            ?? (params["preserve_thinking"] as? Bool)
            ?? false

        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            agentRole: selectedAgent?.role,
            workingDirectory: workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: promptSections.dynamicContext,
            cacheKey: cacheKey,
            history: Self.runtimeHistory(from: params["history"]),
            allowedToolNames: allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            appMode: configuration.appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public func sessionLifecycleResult(sessionID: String) -> [String: Any] {
        let session = sessions[sessionID]
        let sessionConfiguration = session?.configuration
        let modelID = sessionConfiguration?.modelID
            ?? defaultSessionModelID()
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
