//
//  RemoteTransportModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation

/// A single HTTP header, preserving duplicate header names and their order.
public struct RemoteHTTPHeader: Sendable, Hashable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// HTTP headers returned by the remote transport.
public struct RemoteHTTPHeaders: Sendable, Equatable {
    public let entries: [RemoteHTTPHeader]

    public init(_ entries: [RemoteHTTPHeader] = []) {
        self.entries = entries
    }

    /// All values for `name`, using HTTP's case-insensitive header matching.
    public func values(for name: String) -> [String] {
        entries.compactMap { header in
            header.name.caseInsensitiveCompare(name) == .orderedSame
                ? header.value
                : nil
        }
    }

    /// The first value for `name`, using HTTP's case-insensitive matching.
    public func firstValue(for name: String) -> String? {
        values(for: name).first
    }
}

/// TLS settings accepted by the shared transport.
///
/// Certificate and hostname verification cannot be disabled through this API.
/// `serverName` optionally overrides the URL host for both SNI and hostname
/// validation. Extra PEM roots are additive to the platform trust store, which
/// makes deterministic local TLS tests possible without weakening production
/// validation.
public struct RemoteTransportTLSConfiguration: Sendable, Equatable {
    public let serverName: String?
    public let additionalTrustRootPEMs: [Data]

    public init(
        serverName: String? = nil,
        additionalTrustRootPEMs: [Data] = []
    ) {
        self.serverName = serverName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.additionalTrustRootPEMs = additionalTrustRootPEMs
    }

    public static let systemDefault = Self()
}

/// A value request for an incremental HTTP/SSE response.
public struct RemoteHTTPStreamingRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [RemoteHTTPHeader]
    public let body: Data?
    public let timeout: Duration?
    public let tls: RemoteTransportTLSConfiguration

    public init(
        url: URL,
        method: String = "GET",
        headers: [RemoteHTTPHeader] = [],
        body: Data? = nil,
        timeout: Duration? = .seconds(60),
        tls: RemoteTransportTLSConfiguration = .systemDefault
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.tls = tls
    }
}

/// The response head and unicast incremental body from an HTTP request.
///
/// `status` and `headers` are available as soon as the response head arrives;
/// consuming `body` drives subsequent network reads. The body is intentionally
/// unicast, so pass it to one parser/consumer only.
public struct RemoteHTTPStreamingResponse: Sendable {
    public let status: Int
    public let headers: RemoteHTTPHeaders
    public let body: RemoteHTTPBody

    public init(
        status: Int,
        headers: RemoteHTTPHeaders,
        body: RemoteHTTPBody
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// An RFC 6455 connection request.
public struct RemoteWebSocketRequest: Sendable {
    public let url: URL
    public let headers: [RemoteHTTPHeader]
    public let timeout: Duration?
    public let tls: RemoteTransportTLSConfiguration
    public let maximumFrameSize: Int

    public init(
        url: URL,
        headers: [RemoteHTTPHeader] = [],
        timeout: Duration? = .seconds(60),
        tls: RemoteTransportTLSConfiguration = .systemDefault,
        maximumFrameSize: Int = 16 * 1_024 * 1_024
    ) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.tls = tls
        self.maximumFrameSize = maximumFrameSize
    }
}

/// Frame-level WebSocket API. Text and binary frames retain their FIN flag so
/// callers that need to handle fragmented messages can do so without losing
/// protocol information. Ping and pong payloads are exposed as control frames.
public enum RemoteWebSocketFrame: Sendable, Equatable {
    case text(String, final: Bool = true)
    case binary(Data, final: Bool = true)
    case continuation(Data, final: Bool)
    case ping(Data = Data())
    case pong(Data = Data())
    case close(code: UInt16? = nil, reason: String? = nil)
}

/// Cross-platform transport failures. Underlying NIO/OpenSSL errors are
/// converted to a stable, Sendable textual description rather than leaking
/// platform-specific error types through provider APIs.
public enum RemoteTransportError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidHTTPMethod(String)
    case invalidHeader(String)
    case invalidWebSocketFrameSize(Int)
    case timeout
    case shutdown
    case upgradeRejected
    case closed
    case bodyAlreadyConsumed
    case concurrentBodyRead
    case concurrentWebSocketReceive
    case protocolViolation(String)
    case tlsFailure(String)
    case connectionFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "Invalid remote transport URL: \(value)"
        case let .unsupportedScheme(value):
            return "Unsupported remote transport scheme: \(value)"
        case let .invalidHTTPMethod(value):
            return "Invalid HTTP method: \(value)"
        case let .invalidHeader(value):
            return "Invalid HTTP header: \(value)"
        case let .invalidWebSocketFrameSize(value):
            return "Invalid WebSocket maximum frame size: \(value)"
        case .timeout:
            return "Remote transport request timed out."
        case .shutdown:
            return "Remote transport has been shut down."
        case .upgradeRejected:
            return "The remote peer rejected the WebSocket upgrade."
        case .closed:
            return "Remote transport connection is closed."
        case .bodyAlreadyConsumed:
            return "Remote HTTP response bodies support one consumer only."
        case .concurrentBodyRead:
            return "Concurrent reads from a remote HTTP body are not supported."
        case .concurrentWebSocketReceive:
            return "Concurrent receives from a WebSocket are not supported."
        case let .protocolViolation(message):
            return "Remote transport protocol violation: \(message)"
        case let .tlsFailure(message):
            return "Remote transport TLS failure: \(message)"
        case let .connectionFailure(message):
            return "Remote transport connection failure: \(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
