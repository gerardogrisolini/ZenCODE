//
//  ZenCODEACPBridge.swift
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

public actor ZenCODEACPBridge {
    public struct SessionState {
        public let id: String
        public let cwd: String
        public let allowedToolNames: Set<String>?
        public let configuration: AgentCoreSessionConfiguration
        public var activePromptTask: Task<PromptCompletion, Error>?
    }

    public struct PromptCompletion: Sendable {
        public let text: String
        public let stopReason: String
    }

    public let configuration: AgentConfiguration
    public let writer: ACPWriter
    public let permissionBroker: ACPPermissionBroker
    public let sessionRunner: AgentCoreSessionRunner
    public let xcodeIsRunning: @Sendable () -> Bool
    public let verboseLogFile: ACPVerboseLogFile?
    public var sessions: [String: SessionState] = [:]
    private var sessionSleepAssertion: ZenCODESleepAssertion?

    public init(
        configuration: AgentConfiguration,
        writer: ACPWriter,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        xcodeIsRunning: @escaping @Sendable () -> Bool = {
            MCPServerConfiguration.isXcodeRunning()
        }
    ) {
        self.configuration = configuration
        self.writer = writer
        self.xcodeIsRunning = xcodeIsRunning
        let verboseLogFile = configuration.verboseLogging ? ACPVerboseLogFile.open() : nil
        self.verboseLogFile = verboseLogFile
        let permissionBroker = ACPPermissionBroker(writer: writer)
        self.permissionBroker = permissionBroker
        self.sessionRunner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionBroker.authorize(request)
            },
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
    }

    public func shutdown() async {
        for sessionID in sessions.keys {
            sessions[sessionID]?.activePromptTask?.cancel()
            await refreshSessionStateIfAvailable(
                sessionID: sessionID,
                saveRuntimeCache: true
            )
        }
        sessions.removeAll()
        updateSessionSleepAssertion()
        await sessionRunner.shutdown()
    }

    public func holdSessionSleepAssertionIfNeeded() {
        guard sessionSleepAssertion == nil else {
            return
        }
        sessionSleepAssertion = ZenCODESleepAssertion(
            reason: "ZenCODE ACP session active"
        )
    }

    public func updateSessionSleepAssertion() {
        if sessions.isEmpty {
            sessionSleepAssertion?.invalidate()
            sessionSleepAssertion = nil
        } else {
            holdSessionSleepAssertionIfNeeded()
        }
    }

    public func verboseACPLog(_ message: @autoclosure () -> String) async {
        guard configuration.verboseLogging else {
            return
        }
        let message = message()
        await verboseLogFile?.write("[ZenCODE][ACP] \(message)")
    }

    public func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            await writer.sendError(id: .null, code: -32700, message: "Input is not valid UTF-8.")
            return
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let object = value.mlxObjectValue else {
                await writer.sendError(id: .null, code: -32600, message: "JSON-RPC message must be an object.")
                return
            }
            let message = object.mapValues(\.jsonObject)
            await handleMessage(message)
        } catch {
            await writer.sendError(id: .null, code: -32700, message: "Invalid JSON.")
        }
    }

    public func handleMessage(_ message: [String: Any]) async {
        let id = JSONValue.acpRequestID(
            from: message.keys.contains("id") ? message["id"] : nil
        )
        if message["jsonrpc"] as? String == "2.0",
           message["method"] == nil,
           id != nil {
            await permissionBroker.handleResponse(JSONValue.acpValue(from: message))
            return
        }
        guard message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32600,
                message: "Invalid JSON-RPC request."
            )
            return
        }

        do {
            switch method {
            case "initialize":
                try await initialize(id: id, params: objectParams(from: message))
            case "authenticate":
                await writer.sendResultIfRequest(id: id, result: .object([:]))
            case "model/preload":
                try await preloadModel(id: id, params: objectParams(from: message))
            case "session/new":
                try await newSession(id: id, params: objectParams(from: message))
            case "session/set_mode":
                try await setMode(id: id, params: objectParams(from: message))
            case "session/set_model":
                try await setModel(id: id, params: objectParams(from: message))
            case "session/set_config_option":
                try await setConfigOption(id: id, params: objectParams(from: message))
            case "session/prompt":
                try await prompt(id: id, params: objectParams(from: message))
            case "session/cancel":
                try await cancel(id: id, params: objectParams(from: message))
            case "session/close":
                try await close(id: id, params: objectParams(from: message))
            case "session/load":
                try await loadSession(id: id, params: objectParams(from: message))
            case "session/resume":
                try await resumeSession(id: id, params: objectParams(from: message))
            default:
                await writer.sendErrorIfRequest(
                    id: id,
                    code: -32601,
                    message: "Method not found: \(method)"
                )
            }
        } catch let error as ACPError {
            await writer.sendErrorIfRequest(
                id: id,
                code: error.code,
                message: error.message
            )
        } catch is CancellationError {
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": "cancelled"])
            )
        } catch {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32603,
                message: error.localizedDescription
            )
        }
    }

    public func objectParams(from message: [String: Any]) throws -> [String: Any] {
        guard let params = message["params"] as? [String: Any] else {
            return [:]
        }
        return params
    }
}
