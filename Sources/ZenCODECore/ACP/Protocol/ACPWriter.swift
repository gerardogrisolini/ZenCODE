//
//  ACPWriter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// A JSON-RPC error the ACP client answered one of the agent's requests with.
///
/// It keeps the code the client sent, so a caller can tell a missing file
/// (`-32002`) from a denied one: the message alone cannot.
public struct ACPClientError: LocalizedError, Sendable {
    /// ACP `Resource not found`: the path does not exist for the client.
    public static let resourceNotFoundCode = -32002

    public let code: Int
    public let message: String

    public var errorDescription: String? {
        message
    }

    /// `true` when the client said the path does not exist, which is not an
    /// error of the operation that asked for it.
    public var isResourceNotFound: Bool {
        code == Self.resourceNotFoundCode
    }
}

public actor ACPWriter {
    /// Sink for encoded JSON-RPC messages. Injectable so tests can observe the
    /// exact bytes the bridge puts on the wire; production still writes to the
    /// duplicated stdout handle.
    public typealias Sink = @Sendable (Data) -> Void

    private var nextRequestID = 1
    private var pendingRequests: [String: CheckedContinuation<JSONValue?, Error>] = [:]
    private let sink: Sink
    /// Latches on `close()`. Once set nothing is ever written again: late
    /// prompt results, buffered session updates, tool-call events and error
    /// responses are dropped instead of reaching a transport the host already
    /// considers closed.
    private var isClosed = false

    public init(sink: Sink? = nil) {
        self.sink = sink ?? { data in
            Self.writeToStandardOutput(data)
        }
    }

    /// Writes one encoded message, with its newline, to the preserved standard
    /// output without trapping the process when the client closed the pipe.
    ///
    /// `FileHandle.write(_:)` raises an Objective-C exception on `EPIPE`, which
    /// aborts the process before any shutdown can run. The throwing
    /// `write(contentsOf:)` fails with an error instead: the message is dropped
    /// and the input side reports EOF, which ends the session through the normal
    /// shutdown path. `SIGPIPE` itself is suppressed by ``AgentRuntimeLauncher``
    /// before the bridge is built, so the write cannot kill the process either.
    static func writeToStandardOutput(_ data: Data) {
        var payload = data
        payload.append(0x0a)
        do {
            try AgentOutput.standardOutput.write(contentsOf: payload)
        } catch {
            // The client is gone: nothing can be delivered anymore.
        }
    }

    public func request(method: String, params: JSONValue) async throws -> JSONValue? {
        try Task.checkCancellation()
        // A request issued after the fence would suspend forever: the host is
        // gone, so no response can ever resolve the continuation.
        guard !isClosed else {
            throw ACPError.internalError("ACP transport closed.")
        }
        let id = nextRequestID
        nextRequestID += 1
        let key = String(id)
        let requestObject: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])
        // Encode before registering the continuation so an encoding failure
        // (e.g. NaN/Infinity in a JSON number) throws instead of leaving the
        // continuation suspended in `pendingRequests` with no message ever
        // written to the host.
        let payload = try JSONEncoder().encode(requestObject)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[key] = continuation
                write(payload)
            }
        } onCancel: {
            Task(name: "ACPWriter.cancelRequest") {
                await self.cancelRequest(key)
            }
        }
    }

    public func handleResponse(_ message: JSONValue) {
        guard let object = message.objectValue,
              let rawID = object["id"],
              let continuation = pendingRequests.removeValue(forKey: requestKey(for: rawID)) else {
            return
        }

        if let errorObject = object["error"]?.objectValue {
            let message = errorObject["message"]?.acpStringValue ?? "ACP host request failed."
            // The code tells a caller what the host refused: a missing file is
            // not an empty one, and a denied path is not a missing file.
            let code = errorObject["code"]?.numberValue.map { Int($0) } ?? -32603
            continuation.resume(throwing: ACPClientError(code: code, message: message))
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

    /// Fails every in-flight `request(...)` continuation and clears the pending
    /// table. Call this when the ACP transport is shutting down so callers do
    /// not remain suspended forever waiting for a host response that will never
    /// arrive (which would also leak the actor and everything the continuation
    /// captured).
    public func failAllPending(_ error: Error = ACPError.internalError("ACP transport closed.")) {
        guard !pendingRequests.isEmpty else {
            return
        }
        let pending = pendingRequests
        pendingRequests.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    /// Closes the transport: fences every later write and fails every pending
    /// host request.
    ///
    /// This is the single choke point that makes the shutdown contract
    /// enforceable. A prompt still unwinding reaches the host only through this
    /// actor — its `onEvent` callbacks, its buffered-update flush and its final
    /// `stopReason` result all funnel here — so latching once is what
    /// guarantees no result, update or error is emitted after `shutdown()`,
    /// however far the in-flight work had progressed when the fence landed.
    public func close(_ error: Error = ACPError.internalError("ACP transport closed.")) {
        isClosed = true
        failAllPending(error)
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
        guard !isClosed else {
            return
        }
        send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(sessionID),
                "update": update
            ])
        ]))
    }

    /// Sends a namespaced custom notification (method prefixed with `_`). Per
    /// ACP v1 extensibility, custom methods use an underscore prefix and carry
    /// arbitrary params. Unlike `sendSessionUpdate`, custom notifications bypass
    /// the prompt update buffer and reach the host immediately.
    public func sendCustomNotification(method: String, params: JSONValue) {
        guard !isClosed else {
            return
        }
        send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ]))
    }

    private func requestKey(for rawID: JSONValue) -> String {
        switch rawID {
        case let .number(value):
            guard value.isFinite,
                  let intValue = Int(exactly: value) else {
                return String(value)
            }
            return String(intValue)
        case let .string(value):
            return value
        default:
            return rawID.prettyPrinted()
        }
    }

    private func send(_ object: JSONValue) {
        guard !isClosed else {
            return
        }
        guard let data = try? JSONEncoder().encode(object) else {
            AgentOutput.standardError.writeString("ZenCODE: failed to encode ACP message\n")
            return
        }

        write(data)
    }

    private func write(_ data: Data) {
        guard !isClosed else {
            return
        }
        sink(data)
    }
}
