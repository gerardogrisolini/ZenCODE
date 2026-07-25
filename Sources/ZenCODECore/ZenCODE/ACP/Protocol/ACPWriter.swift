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
            AgentOutput.standardOutput.write(data)
            AgentOutput.standardOutput.write(Data([0x0a]))
        }
    }

    public func request(method: String, params: JSONValue) async throws -> JSONValue? {
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
                pendingRequests[key] = continuation
                write(payload)
            }
        } onCancel: {
            Task {
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
