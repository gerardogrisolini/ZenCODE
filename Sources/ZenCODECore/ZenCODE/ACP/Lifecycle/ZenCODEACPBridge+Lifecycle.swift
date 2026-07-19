//
//  ZenCODEACPBridge+Lifecycle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

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
            "models": modelState(for: configuration.effectiveModelID),
            "agentInfo": [
                "name": "ZenCODE",
                "title": "ZenCODE",
                "version": agentVersion
            ],
            "authMethods": Self.authenticationMethods(from: params)
        ]
        await writer.sendResultIfRequest(id: id, result: JSONValue.acpValue(from: result))
    }

    /// Xcode 27 beta 3 treats every custom ACP agent as requiring authentication.
    /// This no-op method only acknowledges that client-mandated step; it does not handle provider access.
    static func authenticationMethods(from params: [String: Any]) -> [[String: Any]] {
        guard requiresXcodeAuthenticationCompatibilityMethod(from: params) else {
            return []
        }

        return [[
            "id": "zencode-xcode-compatibility",
            "name": "Continue with ZenCODE",
            "description": "Continue to the ZenCODE session.",
            "type": "agent"
        ]]
    }

    private static func requiresXcodeAuthenticationCompatibilityMethod(from params: [String: Any]) -> Bool {
        guard let clientInfo = params["clientInfo"] as? [String: Any] else {
            return false
        }
        let clientName = ((clientInfo["name"] as? String) ?? (clientInfo["title"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard clientName == "xcode" else {
            return false
        }

        if let version = (clientInfo["version"] as? String)?.nilIfBlank,
           let majorVersion = Int(version.split(separator: ".", maxSplits: 1).first ?? ""),
           majorVersion >= 27 {
            return true
        }

        let clientCapabilities = params["clientCapabilities"] as? [String: Any]
        return clientCapabilities?["auth"] != nil
    }

    public func preloadModel(id: JSONValue?, params: [String: Any]) async throws {
        let preloadConfiguration = defaultSessionConfiguration(sessionID: "preload")
            .withModelID(Self.modelID(from: params) ?? configuration.effectiveModelID)
        let modelID = try await sessionRunner.preloadModel(
            configuration: preloadConfiguration
        ) { _ in }
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: ["modelID": modelID])
        )
    }

    public func newSession(id: JSONValue?, params: [String: Any]) async throws {
        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let cwd = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: rawCwd,
            applyLaunchDirectoryFallback: false
        ).path
        await verboseACPLog(
            "session/new cwd=\(cwd) mcpServers=\(Self.mcpServerInputSummary(from: params))"
        )
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? configuration.effectiveModelID

        let sessionID = "swift-agent-\(UUID().uuidString.lowercased())"
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let workingDirectoryURL = URL(fileURLWithPath: cwd)
        let hasACPProvidedXcodeMCPServer = Self.mcpServerDefinitions(from: params).contains {
            $0.isXcodeCandidate
        }
        let acpMCPDescriptors = await registerACPProvidedMCPServers(from: params)
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? configuration.selectedAgent?.allowedToolNames()
        let hasACPProvidedXcodeTools = acpMCPDescriptors.contains {
            DirectMCPToolRuntime.isXcodeToolName($0.name)
        }
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectoryURL,
            skipXcodeDiscovery: hasACPProvidedXcodeMCPServer || hasACPProvidedXcodeTools
        )
        let allowedToolNames = Self.allowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPDescriptors
        )
        await verboseACPLog(
            "session/new allowedTools=\(Self.verboseToolNameSummary(allowedToolNames))"
        )
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: cwd,
            allowedToolNames: allowedToolNames
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
            agentModelID: configuration.selectedAgent?.modelID,
            agentThinkingSelection: configuration.selectedAgent?.thinkingSelection,
            manifest: hostedManifest ?? AgentSettingsManifestStore.load()
        )
        let preserveThinking = (params["preserveThinking"] as? Bool) ?? false
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            bearerToken: self.configuration.bearerToken,
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
        sessions[sessionID] = sessionState(configuration: configuration)
        updateSessionSleepAssertion()
        try await sessionRunner.createSession(configuration: configuration)

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
        workingDirectory: URL,
        skipXcodeDiscovery: Bool = false
    ) async -> Set<String>? {
        guard let allowedToolNames = ExternalToolAvailability.resolvedAllowedToolNames(requestedAllowedToolNames) else {
            return nil
        }

        guard !skipXcodeDiscovery else {
            return allowedToolNames
        }
        guard allowedToolNames.contains(where: DirectMCPToolRuntime.isXcodeToolName) else {
            return allowedToolNames
        }
        guard xcodeIsRunning() else {
            return allowedToolNames
        }

        let requestedXcodePrefixes: Set<String> = [XcodeToolIntegration.toolPrefix]
        _ = await sessionRunner.mcpToolDescriptors(
            allowedToolNames: requestedXcodePrefixes,
            preferredWorkspaceRootURL: workingDirectory
        )
        return allowedToolNames
    }

    public func registerACPProvidedMCPServers(
        from params: [String: Any]
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
        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
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
        sessions[sessionID] = sessionState(configuration: updatedConfiguration)
        try await sessionRunner.createSession(configuration: updatedConfiguration)
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
        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
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
        sessions[sessionID] = sessionState(configuration: updatedConfiguration)
        try await sessionRunner.createSession(configuration: updatedConfiguration)
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

        public func restoreSession(
        id: JSONValue?,
        params: [String: Any],
        replayHistory: Bool
    ) async throws {
        // A session_id is optional: stateless clients can resume by resending
        // their transcript. When omitted we mint an internal session id.
        let sessionID = Self.sessionID(from: params)
            ?? "swift-agent-\(UUID().uuidString.lowercased())"
        if let session = sessions[sessionID] {
            if replayHistory,
               let snapshot = await sessionRunner.snapshotSession(id: sessionID) {
                await replaySessionHistory(snapshot)
            }
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
            )
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
        let hasACPProvidedXcodeMCPServer = Self.mcpServerDefinitions(from: params).contains {
            $0.isXcodeCandidate
        }
        let acpMCPDescriptors = await registerACPProvidedMCPServers(from: params)
        let configuration = await restoredACPClientSessionConfiguration(
            sessionID: sessionID,
            params: params,
            workingDirectory: workingDirectory,
            acpMCPDescriptors: acpMCPDescriptors,
            hasACPProvidedXcodeMCPServer: hasACPProvidedXcodeMCPServer
        )
        await verboseACPLog(
            "session/restore allowedTools=\(Self.verboseToolNameSummary(configuration.allowedToolNames)) history=\(configuration.history.count)"
        )
        sessions[sessionID] = sessionState(configuration: configuration)
        updateSessionSleepAssertion()
        try await sessionRunner.restoreSession(configuration: configuration)
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
        }

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
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
            bearerToken: configuration.bearerToken,
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
        hasACPProvidedXcodeMCPServer: Bool = false
    ) async -> AgentCoreSessionConfiguration {
        let requestedModelID = Self.modelID(from: params)
        let modelID = requestedModelID
            ?? configuration.effectiveModelID
        let requestedAllowedToolNames = Self.allowedToolNames(from: params)
            ?? configuration.selectedAgent?.allowedToolNames()
        let hasACPProvidedXcodeTools = acpMCPDescriptors.contains {
            DirectMCPToolRuntime.isXcodeToolName($0.name)
        }
        let resolvedRequestedAllowedToolNames = await resolvedAllowedToolNames(
            requestedAllowedToolNames,
            workingDirectory: workingDirectory,
            skipXcodeDiscovery: hasACPProvidedXcodeMCPServer || hasACPProvidedXcodeTools
        )
        let allowedToolNames = Self.allowedToolNames(
            resolvedRequestedAllowedToolNames,
            adding: acpMCPDescriptors
        )
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames
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
            agentModelID: configuration.selectedAgent?.modelID,
            agentThinkingSelection: configuration.selectedAgent?.thinkingSelection,
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
            bearerToken: configuration.bearerToken,
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
        let sessionConfiguration = sessions[sessionID]?.configuration
        let modelID = sessionConfiguration?.modelID
            ?? configuration.effectiveModelID
        return [
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
            "models": modelState(for: modelID)
        ]
    }

}
