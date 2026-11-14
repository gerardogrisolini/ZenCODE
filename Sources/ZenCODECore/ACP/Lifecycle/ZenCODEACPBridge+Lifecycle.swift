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
                    "delete": [:],
                    "list": [:],
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
    ///   place of the default ones: `["--setup"]` makes it run
    ///   `zen --setup`, which opens the interactive setup (provider and
    ///   sign-in) and exits when the setup ends. The client then reconnects
    ///   and initializes the agent again.
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
                "args": [ZenCODESetupCommand.option]
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
        // The session's own tool grant, resolved before its MCP servers are
        // installed: it tells which of them a feature of the session replaces.
        let resolvedRequestedAllowedToolNames = await requestedSessionAllowedToolNames(
            from: params,
            selectedAgent: selectedAgent,
            workingDirectory: workingDirectoryURL
        )
        try ensureLifecycleOperationLive(operation)
        let (sessionEpoch, offersResumableTaskGraphs) = try await withNewIncarnation(
            sessionID: sessionID,
            cwd: cwd,
            params: params,
            requestedAllowedToolNames: resolvedRequestedAllowedToolNames,
            operation: operation
        ) { incarnation, acpMCPDescriptors in
            let cacheKey = (params["sessionKey"] as? String)
                ?? (params["cacheKey"] as? String)
            let allowedToolNames = Self.sessionAllowedToolNames(
                resolvedRequestedAllowedToolNames,
                adding: acpMCPDescriptors,
                selectedAgent: selectedAgent
            )
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
            // Past the last fence the session entry, the runner session and
            // the JSON-RPC reply are published.
            try publishNewIncarnation(
                incarnation,
                sessionID: sessionID,
                configuration: runnerConfiguration,
                selectedAgent: selectedAgent,
                operation: operation
            )
            // A runner session that cannot be created leaves no session
            // entry behind: the cleanup drops our own incarnation's entry.
            try await sessionRunner.createSession(configuration: runnerConfiguration)
            // Whether earlier sessions left task graphs to offer: only then
            // is the startup offer registered below.
            let offersResumableTaskGraphs = await hasOfferableResumableTaskGraphs(
                sessionID: sessionID,
                workingDirectory: workingDirectoryURL
            )
            // `createSession` and the scan suspend: if a shutdown or a
            // `session/close` landed during them, close the runner session we
            // just created instead of announcing it.
            try await ensureLifecycleOperationLiveAfterSessionWrite(
                operation,
                sessionID: sessionID
            )
            return (incarnation.epoch, offersResumableTaskGraphs)
        }

        // The startup offer of the task graphs earlier sessions left
        // incomplete, when there are any, is registered before the reply, so
        // a prompt sent right after it waits for the offer, and asks only
        // once the session is announced (see
        // `ZenCODEACPBridge+ResumeTaskGraph.swift`).
        let resumableTaskGraphOfferGate = offersResumableTaskGraphs
            ? registerResumableTaskGraphOffer(sessionID: sessionID, epoch: sessionEpoch)
            : nil
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
        await publishAvailableCommands(sessionID: sessionID, epoch: sessionEpoch)
        resumableTaskGraphOfferGate?.finish()
    }

    /// Opens, for the lifecycle `operation`, a new incarnation of the ACP
    /// session `sessionID` in `cwd`, installs the MCP servers `params`
    /// provide, and runs `body` with the incarnation and the descriptors of
    /// those servers: the shared part of `session/new` and of the restore of
    /// a session that is not live. `requestedAllowedToolNames` is the
    /// session's own tool grant (see `requestedSessionAllowedToolNames`): a
    /// server one of its features replaces is not installed.
    ///
    /// The incarnation is opened in the host before the MCP servers are
    /// installed: the ownership stamped on those registrations identifies
    /// exactly the incarnation the handler is about to publish, so a failed
    /// or fenced creation can release them again. Every `throw` after the
    /// opening, `body`'s included, means the incarnation never became (or did
    /// not stay) live: its session entry, if it is still ours, is dropped
    /// (a racing handler's newer incarnation is never touched), its host slot
    /// is closed (already, when the entry was dropped), and its MCP
    /// registrations are released before the error propagates. A successful
    /// exit keeps them bound to the live session.
    private func withNewIncarnation<Value>(
        sessionID: String,
        cwd: String,
        params: [String: Any],
        requestedAllowedToolNames: Set<String>?,
        operation: UInt64,
        _ body: (_ incarnation: ChatSessionIncarnation, _ acpMCPDescriptors: [DirectToolDescriptor]) async throws -> Value
    ) async throws -> Value {
        let incarnation = try await openACPSession(sessionID: sessionID, cwd: cwd)
        do {
            try ensureLifecycleOperationLive(operation)
            let acpMCPDescriptors = await registerACPProvidedMCPServers(
                from: params,
                requestedAllowedToolNames: requestedAllowedToolNames,
                ownership: DirectMCPToolRuntime.MCPSessionOwnership(
                    sessionID: sessionID,
                    epoch: incarnation.epoch
                ),
                operation: operation
            )
            try ensureLifecycleOperationLive(operation)
            return try await body(incarnation, acpMCPDescriptors)
        } catch {
            await discardSessionIfCurrent(id: sessionID, epoch: incarnation.epoch)
            await closeACPSlot(of: incarnation)
            await sessionRunner.releaseSessionMCPOwnership(
                sessionID: sessionID,
                epoch: incarnation.epoch
            )
            throw error
        }
    }

    /// Publishes the entry of the new `incarnation` of `sessionID` and binds
    /// the lifecycle `operation` to it, after the last fence before any
    /// observable effect: a shutdown that lands right before must abort
    /// rather than leave a live session and a backend behind a closed
    /// transport. From here the session exists, so a `session/close` for it
    /// invalidates the handler before it answers.
    private func publishNewIncarnation(
        _ incarnation: ChatSessionIncarnation,
        sessionID: String,
        configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?,
        savedSessionLink: ACPSavedSessionLink? = nil,
        operation: UInt64
    ) throws {
        try ensureLifecycleOperationLive(operation)
        var sessionEntry = sessionState(
            configuration: configuration,
            selectedAgent: selectedAgent,
            incarnation: incarnation
        )
        sessionEntry.savedSessionLink = savedSessionLink
        sessions[sessionID] = sessionEntry
        bindLifecycleOperation(operation, sessionID: sessionID, epoch: incarnation.epoch)
    }

    /// The tools of a new ACP session: the resolved request, with the tools
    /// of the MCP servers the session provided and the prompt-skill tools,
    /// then narrowed by the selected agent. `nil` (no restriction) stays
    /// `nil`.
    private static func sessionAllowedToolNames(
        _ resolvedRequestedAllowedToolNames: Set<String>?,
        adding acpMCPDescriptors: [DirectToolDescriptor],
        selectedAgent: AgentProfile?
    ) -> Set<String>? {
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
        return allowedToolNames
    }

    public func resolvedAllowedToolNames(
        _ requestedAllowedToolNames: Set<String>?,
        workingDirectory: URL
    ) async -> Set<String>? {
        _ = workingDirectory
        return ExternalToolAvailability.resolvedAllowedToolNames(requestedAllowedToolNames)
    }

    /// The tools a new session asks for on its own, before the tools of the
    /// MCP servers it provides are added: the request's, else the selected
    /// agent's. `nil` is a request with no tool grant of its own.
    private func requestedSessionAllowedToolNames(
        from params: [String: Any],
        selectedAgent: AgentProfile?,
        workingDirectory: URL
    ) async -> Set<String>? {
        await resolvedAllowedToolNames(
            Self.allowedToolNames(from: params) ?? selectedAgent?.allowedToolNames(),
            workingDirectory: workingDirectory
        )
    }

    /// The server ids (`DirectMCPToolRuntime.externalServerID(for:)`) of the
    /// features a session with the tool grant `requestedAllowedToolNames`
    /// runs. `nil` names none: a session without a grant of its own that
    /// installs an MCP server is granted the tools of its servers only (see
    /// `allowedToolNames(_:adding:)`), so no feature runs beside them.
    private func sessionFeatureServerIDs(
        requestedAllowedToolNames: Set<String>?
    ) async -> Set<String> {
        guard let requestedAllowedToolNames else {
            return []
        }
        let featureIDs = await sessionRunner.swiftFeatureRuntime.featureIDs(
            relevantTo: requestedAllowedToolNames
        )
        return Set(featureIDs.map(DirectMCPToolRuntime.externalServerID(for:)))
    }

    /// Installs the MCP servers `params` provide and returns their tools.
    ///
    /// A server named like a feature the session's own tool grant
    /// (`requestedAllowedToolNames`) already selects is the same integration
    /// offered twice: Xcode passes its `xcode-tools` MCP bridge to every
    /// session, including one whose agent runs the `xcode-tools` feature.
    /// Such a server is not installed, so the session opens one connection to
    /// the integration, and asks for its consent once, instead of twice, and
    /// the model is not given two copies of the same tools. Without a grant
    /// (`nil`) every server is installed.
    public func registerACPProvidedMCPServers(
        from params: [String: Any],
        requestedAllowedToolNames: Set<String>? = nil,
        ownership: DirectMCPToolRuntime.MCPSessionOwnership? = nil,
        operation: UInt64? = nil
    ) async -> [DirectToolDescriptor] {
        let definitions = Self.mcpServerDefinitions(from: params)
        guard !definitions.isEmpty else {
            return []
        }
        let featureServerIDs = await sessionFeatureServerIDs(
            requestedAllowedToolNames: requestedAllowedToolNames
        )

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
            guard !featureServerIDs.contains(
                DirectMCPToolRuntime.externalServerID(for: definition.name)
            ) else {
                ZenLogger.info(
                    .viewModelRuntime,
                    "ACP MCP server '\(definition.name)' is not installed: the session's feature of the same name provides its tools."
                )
                continue
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
        // The saved session of this id, unless the client sends its own
        // history, which wins. Read before the agent is resolved: the agent
        // decides the tool grant and the MCP servers that are installed. The
        // read does not suspend.
        let savedSession = Self.runtimeHistory(from: params["history"]).isEmpty
            ? savedACPSession(id: sessionID, workingDirectory: workingDirectory)
            : nil
        // Resolved before the incarnation opens, as `session/new` does: the
        // agent's tool grant tells which MCP servers its features replace.
        let selectedAgent = try resolvedACPAgentProfile(
            from: params,
            workingDirectory: workingDirectory,
            savedAgentID: savedSession?.agentID,
            savedAgentName: savedSession?.agentName
        )
        let requestedAllowedToolNames = await requestedSessionAllowedToolNames(
            from: params,
            selectedAgent: selectedAgent,
            workingDirectory: workingDirectory
        )
        try ensureLifecycleOperationLive(operation)
        let restoredSessionEpoch = try await withNewIncarnation(
            sessionID: sessionID,
            cwd: workingDirectory.path,
            params: params,
            requestedAllowedToolNames: requestedAllowedToolNames,
            operation: operation
        ) { incarnation, acpMCPDescriptors in
            let configuration = await restoredACPClientSessionConfiguration(
                sessionID: sessionID,
                params: params,
                workingDirectory: workingDirectory,
                acpMCPDescriptors: acpMCPDescriptors,
                selectedAgent: selectedAgent,
                savedSession: savedSession
            )
            try ensureLifecycleOperationLive(operation)
            // Past the last fence the session entry, the runner session, the
            // history replay and the reply become observable. The saved
            // session the incarnation was restored from is the one its saves
            // update.
            try publishNewIncarnation(
                incarnation,
                sessionID: sessionID,
                configuration: configuration,
                selectedAgent: selectedAgent,
                savedSessionLink: savedSession.map {
                    ACPSavedSessionLink(
                        name: $0.name,
                        createdAt: $0.createdAt,
                        checkpointTree: $0.checkpointTree
                    )
                },
                operation: operation
            )
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
            return incarnation.epoch
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
        await restoredACPClientSessionConfiguration(
            sessionID: sessionID,
            params: params,
            workingDirectory: workingDirectory,
            acpMCPDescriptors: acpMCPDescriptors,
            selectedAgent: selectedAgent,
            savedSession: nil
        )
    }

    /// The configuration of a restored session that is not live. Its history
    /// is the client's `history`, else the one of `savedSession`, the saved
    /// session of its id (`nil` when the client sent a history), without the
    /// dynamic context leading it. What the client asks for wins over the
    /// saved session, and the saved session over the defaults: the model is
    /// the client's `modelId`, else the saved one while the catalog still
    /// offers it, else the default; the thinking level is the client's, else
    /// the saved one when the chosen model offers it, else the resolved
    /// default; `preserveThinking` is the client's, else `false`. The system
    /// prompt, the dynamic context, the tool grant, and the cache key are
    /// composed as for any restore, never read from the file.
    func restoredACPClientSessionConfiguration(
        sessionID: String,
        params: [String: Any],
        workingDirectory: URL,
        acpMCPDescriptors: [DirectToolDescriptor],
        selectedAgent: AgentProfile?,
        savedSession: TerminalSavedSession?
    ) async -> AgentCoreSessionConfiguration {
        let requestedModelID = Self.modelID(from: params)
        let savedModelID = requestedModelID == nil
            ? savedSession?.modelID.flatMap { modelCatalog.containsModel(withID: $0) ? $0 : nil }
            : nil
        let modelID = requestedModelID
            ?? savedModelID
            ?? defaultSessionModelID()
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? selectedAgent?.allowedToolNames()
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectory
        )
        let allowedToolNames = Self.sessionAllowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPDescriptors,
            selectedAgent: selectedAgent
        )
        let promptSections = resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
        let requestedThinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let savedThinkingSelection = requestedThinkingSelection == nil
            ? savedSession?.thinkingSelection.flatMap {
                modelCatalog.validatedThinkingSelection($0, forModelID: modelID)
            }
            : nil
        // A model restored from the saved session stands where the client's
        // model would: the default level is resolved for it.
        let thinkingSelection = savedThinkingSelection ?? modelCatalog.resolvedThinkingSelection(
            requested: requestedThinkingSelection,
            explicitModelID: requestedModelID ?? savedModelID ?? configuration.modelID,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection,
            selectedModelID: modelID
        )
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let preserveThinking = (params["preserveThinking"] as? Bool)
            ?? (params["preserve_thinking"] as? Bool)
            ?? false
        let clientHistory = Self.runtimeHistory(from: params["history"])
        let history = clientHistory.isEmpty
            ? savedSession.map { AgentRuntimeDynamicContext.separating(from: $0.history).history } ?? []
            : clientHistory

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
            history: history,
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
