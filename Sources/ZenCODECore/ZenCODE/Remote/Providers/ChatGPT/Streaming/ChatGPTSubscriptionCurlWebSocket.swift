//
//  ChatGPTSubscriptionCurlWebSocket.swift
//  ZenCODE
//

#if os(Linux)
import CLibCURLWebSocket
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChatGPTSubscriptionCurlWebSocket: @unchecked Sendable {
    private enum Status: Int32 {
        case ok = 0
        case timeout = 1
        case closed = 2
        case error = 3
        case unsupported = 4
    }

    private struct TransportError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private let connection: UnsafeMutableRawPointer

    private init(connection: UnsafeMutableRawPointer) {
        self.connection = connection
    }

    deinit {
        zen_curl_ws_close(connection)
    }

    static func connect(request: URLRequest) async throws -> Self {
        guard let url = request.url?.absoluteString else {
            throw ChatGPTSubscriptionGenerationError.invalidResponse
        }
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        return try await Task.detached {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let connection = url.withCString { urlPointer in
                headers.withCString { headerPointer in
                    zen_curl_ws_connect(
                        urlPointer,
                        headerPointer,
                        &errorMessage
                    )
                }
            }
            defer {
                zen_curl_ws_free_error(errorMessage)
            }
            guard let connection else {
                throw TransportError(
                    message: decodedError(errorMessage)
                )
            }
            return Self(connection: connection)
        }.value
    }

    func send(text: String) async throws {
        let data = Data(text.utf8)
        try await Task.detached { [self] in
            var errorMessage: UnsafeMutablePointer<CChar>?
            let rawStatus = data.withUnsafeBytes { buffer in
                zen_curl_ws_send_text(
                    connection,
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    buffer.count,
                    &errorMessage
                )
            }
            defer {
                zen_curl_ws_free_error(errorMessage)
            }
            guard Status(rawValue: rawStatus) == .ok else {
                throw TransportError(message: Self.decodedError(errorMessage))
            }
        }.value
    }

    func receive() async throws -> Data {
        while true {
            try Task.checkCancellation()
            let result = try await Task.detached { [self] in
                var bytes: UnsafeMutablePointer<UInt8>?
                var length = 0
                var isText: Int32 = 0
                var errorMessage: UnsafeMutablePointer<CChar>?
                let rawStatus = zen_curl_ws_receive(
                    connection,
                    &bytes,
                    &length,
                    &isText,
                    &errorMessage
                )
                defer {
                    zen_curl_ws_free_bytes(bytes)
                    zen_curl_ws_free_error(errorMessage)
                }
                let status = Status(rawValue: rawStatus) ?? .error
                switch status {
                case .ok:
                    guard let bytes else {
                        return (status, Data())
                    }
                    return (status, Data(bytes: bytes, count: length))
                case .timeout:
                    return (status, Data())
                case .closed:
                    throw TransportError(
                        message: "The ChatGPT Subscription WebSocket is closed."
                    )
                case .error, .unsupported:
                    throw TransportError(message: Self.decodedError(errorMessage))
                }
            }.value
            if result.0 == .ok {
                return result.1
            }
        }
    }

    private static func decodedError(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> String {
        guard let pointer else {
            return "Unknown libcurl WebSocket error"
        }
        return String(cString: pointer)
    }
}
#endif
