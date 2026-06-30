//
//  ACPWriter.swift
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

public actor ACPWriter {
    private var nextRequestID = 1
    private var pendingRequests: [String: CheckedContinuation<JSONValue?, Error>] = [:]

    public init() {}

    public func request(method: String, params: JSONValue) async throws -> JSONValue? {
        let id = nextRequestID
        nextRequestID += 1
        let key = String(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[key] = continuation
                send(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(Double(id)),
                    "method": .string(method),
                    "params": params
                ]))
            }
        } onCancel: {
            Task {
                await self.cancelRequest(key)
            }
        }
    }

    public func handleResponse(_ message: JSONValue) {
        guard let object = message.mlxObjectValue,
              let rawID = object["id"],
              let continuation = pendingRequests.removeValue(forKey: requestKey(for: rawID)) else {
            return
        }

        if let errorObject = object["error"]?.mlxObjectValue {
            let message = errorObject["message"]?.acpStringValue ?? "ACP host request failed."
            continuation.resume(throwing: ACPError.internalError(message))
            return
        }

        continuation.resume(returning: object["result"])
    }

    private func cancelRequest(_ key: String) {
        guard let continuation = pendingRequests.removeValue(forKey: key) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    public func sendResultIfRequest(id: JSONValue?, result: JSONValue) async {
        guard let id else {
            return
        }
        send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]))
    }

    public func sendErrorIfRequest(id: JSONValue?, code: Int, message: String) async {
        guard let id else {
            return
        }
        sendError(id: id, code: code, message: message)
    }

    public func sendError(id: JSONValue, code: Int, message: String) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message)
            ])
        ]))
    }

    public func sendSessionUpdate(sessionID: String, update: JSONValue) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(sessionID),
                "update": update
            ])
        ]))
    }

    private func requestKey(for rawID: JSONValue) -> String {
        switch rawID {
        case let .number(value):
            let intValue = Int(value)
            return Double(intValue) == value ? String(intValue) : String(value)
        case let .string(value):
            return value
        default:
            return rawID.prettyPrinted()
        }
    }

    private func send(_ object: JSONValue) {
        guard let data = try? JSONEncoder().encode(object) else {
            AgentOutput.standardError.writeString("ZenCODE: failed to encode ACP message\n")
            return
        }

        AgentOutput.standardOutput.write(data)
        AgentOutput.standardOutput.write(Data([0x0a]))
    }
}
