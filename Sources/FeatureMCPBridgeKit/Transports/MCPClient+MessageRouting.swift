//
//  MCPClient+MessageRouting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

#if os(macOS)
/// Framing, JSON-RPC routing, and pending-response completion for the local
/// transport. Byte transport stops at `append(_:)`; everything below it is wire
/// semantics and continuation ownership.
extension MCPClient {
    func append(_ chunk: Data) {
        // `buffer` only contains incomplete frames. Refuse a peer that exceeds
        // its residual-frame budget rather than repeatedly reallocating memory.
        guard chunk.count <= MCPTransportCodec.maxFrameBytes,
              buffer.count <= MCPTransportCodec.maxFrameBytes - chunk.count else {
            handleMalformedTransport(.frameTooLarge(limit: MCPTransportCodec.maxFrameBytes))
            return
        }
        buffer.append(chunk)

        if let error = classifiedPolicyError(
            kind: .stdout,
            message: String(data: buffer, encoding: .utf8) ?? ""
        ) {
            applyClassifiedPolicyError(error)
            resumeAllPending(with: error)
            buffer.removeAll(keepingCapacity: false)
            return
        }

        var parsedMessageCount = 0
        parseLoop: while true {
            switch MCPTransportCodec.nextMessage(from: &buffer) {
            case let .message(body):
                guard !body.isEmpty else {
                    continue
                }
                parsedMessageCount += 1
                handleMessage(body)
            case .needMoreData:
                break parseLoop
            case let .malformed(error):
                handleMalformedTransport(error)
                return
            }
        }

        if parsedMessageCount == 0, !buffer.isEmpty {
            logBufferedPrefixIfNeeded()
        }

    }

    private func handleMalformedTransport(_ error: MCPTransportCodecError) {
        let clientError = MCPClientError.malformedTransport(error.localizedDescription)
        buffer.removeAll(keepingCapacity: false)
        terminalBridgeError = clientError
        resumeAllPending(with: clientError)
        // Framing cannot be safely re-synchronized. Always close the local
        // transport; this is intentionally independent of optional policy hooks.
        terminateLocalProcessAfterPolicyError(clientError)
    }

    func handleMessage(_ body: Data) {
        log("message <- \(String(data: body, encoding: .utf8) ?? "<non-utf8>")")
        guard let message = try? JSONDecoder().decode(MCPIncomingMessage.self, from: body) else {
            if let error = classifiedPolicyError(
                kind: .invalidMessage,
                message: String(data: body, encoding: .utf8) ?? ""
            ) {
                applyClassifiedPolicyError(error)
                resumeAllPending(with: error)
            }
            log("Failed to decode incoming MCP message")
            return
        }

        guard let id = message.id else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            return
        }

        guard case let .int(requestID) = id else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            resumeAllPending(with: MCPClientError.unsupportedMessageID)
            return
        }

        let method = pendingRequestMethods.removeValue(forKey: requestID)
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            if handleUnroutedPolicyMessage(message) {
                return
            }
            return
        }

        if let error = message.error {
            log("Request \(requestID) failed with server error \(error.code): \(error.message)")
            if let policyError = classifiedPolicyError(
                kind: .serverError,
                message: error.message,
                requestMethod: method,
                errorCode: error.code
            ) {
                applyClassifiedPolicyError(policyError)
                continuation.resume(throwing: policyError)
            } else {
                continuation.resume(
                    throwing: MCPClientError.serverError(
                        code: error.code,
                        message: error.message
                    )
                )
            }
            return
        }

        guard let result = message.result else {
            log("Request \(requestID) failed: missing result")
            if let error = classifiedPolicyError(
                kind: .missingResult,
                requestMethod: method
            ) {
                applyClassifiedPolicyError(error)
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: MCPClientError.invalidResponse)
            }
            return
        }

        log("Request \(requestID) completed successfully")
        continuation.resume(returning: result)
    }

    func resumeAllPending(with error: Error) {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        pendingRequestMethods.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func cancelPendingResponse(id requestID: Int) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        pendingRequestMethods.removeValue(forKey: requestID)
        continuation.resume(throwing: CancellationError())
    }

    func recordPendingRequestMethodForTesting(id: Int, method: String) {
        pendingRequestMethods[id] = method
    }
}
#endif
