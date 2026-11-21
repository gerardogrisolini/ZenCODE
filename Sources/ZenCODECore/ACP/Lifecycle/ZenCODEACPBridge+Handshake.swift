//
//  ZenCODEACPBridge+Handshake.swift
//  ZenCODE
//
//  The ACP connection handshake: initialize, authenticate with the methods it
//  advertises, and the _zencode/model/preload warm-up.
//

import Foundation
import ToolCore
import ZenCODERuntime

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
}
