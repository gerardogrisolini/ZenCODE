//
//  ZenCODEACPBridge+MessageDispatch.swift
//  ZenCODE
//
//  JSON-RPC dispatch of the ACP bridge: the decoding of each input line and
//  the routing of every method to its handler.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODEACPBridge {
    public func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            await writer.sendError(id: .null, code: -32700, message: "Input is not valid UTF-8.")
            return
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let object = value.objectValue else {
                await writer.sendError(id: .null, code: -32600, message: "JSON-RPC message must be an object.")
                return
            }
            await handleJSONMessage(object)
        } catch {
            await writer.sendError(id: .null, code: -32700, message: "Invalid JSON.")
        }
    }

    private func handleJSONMessage(_ message: [String: JSONValue]) async {
        let id = JSONValue.acpRequestID(from: message)
        if message["jsonrpc"]?.stringValue == "2.0",
           message["method"] == nil,
           id != nil {
            await permissionBroker.handleResponse(.object(message))
            return
        }
        guard message["jsonrpc"]?.stringValue == "2.0",
              let method = message["method"]?.stringValue else {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32600,
                message: "Invalid JSON-RPC request."
            )
            return
        }

        do {
            let params = jsonObjectParams(from: message).mapValues(\.jsonObject)
            switch method {
            case "initialize":
                try await initialize(id: id, params: params)
            case "authenticate":
                try await authenticate(id: id, params: params)
            case "_zencode/model/preload":
                try await preloadModel(id: id, params: params)
            case "session/new":
                try await newSession(id: id, params: params)
            case "session/set_mode":
                try await setMode(id: id, params: params)
            case "_zencode/session/set_model":
                try await setModel(id: id, params: params)
            case "session/set_config_option":
                try await setConfigOption(id: id, params: params)
            case "session/prompt":
                try await prompt(id: id, params: params)
            case "session/cancel":
                try await cancel(id: id, params: params)
            case "session/close":
                try await close(id: id, params: params)
            case "session/delete":
                try await deleteSession(id: id, params: params)
            case "session/list":
                try await listSessions(id: id, params: params)
            case "session/load":
                try await loadSession(id: id, params: params)
            case "session/resume":
                try await resumeSession(id: id, params: params)
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
        } catch is ACPShutdownFenceError {
            // Only a `shutdown()` ends here: the transport is closing, so
            // deliberately send nothing. `shutdown()` already failed every
            // pending host request, and writing a late response here is
            // exactly the leak this fence prevents. A lifecycle operation
            // whose incarnation a `session/close` (or a replacement of the
            // same id) ended is an `ACPError` instead
            // (`lifecycleOperationFenceError()`), answered above: the
            // transport is open and JSON-RPC requires a response.
        } catch is CancellationError {
            // A prompt answers cancellation inside its own drain token.
            // Cancellation of any other request is a JSON-RPC error.
            await writer.sendErrorIfRequest(
                id: id,
                code: -32800,
                message: "Request cancelled."
            )
        } catch {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32603,
                message: error.localizedDescription
            )
        }
    }

    private func jsonObjectParams(from message: [String: JSONValue]) -> [String: JSONValue] {
        message["params"]?.objectValue ?? [:]
    }
}
