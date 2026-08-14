//
//  MCPServerConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(CryptoKit)

import CryptoKit
#else
import Crypto
#endif
import Foundation
import Synchronization
import ToolCore
#if canImport(Network)
import Network
#endif

public nonisolated struct MCPBrowserOAuthConfiguration: Hashable, Sendable {
    public let clientName: String
    public let serviceName: String
    public let redirectHost: String
    public let redirectPort: UInt16
    public let redirectPath: String
    public let metadataURL: URL?
    public let callbackTimeout: TimeInterval

    public init(
        clientName: String = "MCP client",
        serviceName: String = "MCP service",
        redirectHost: String = "127.0.0.1",
        redirectPort: UInt16 = 8787,
        redirectPath: String = "/callback",
        metadataURL: URL? = nil,
        callbackTimeout: TimeInterval = 300
    ) {
        self.clientName = clientName
        self.serviceName = serviceName
        self.redirectHost = redirectHost
        self.redirectPort = redirectPort
        self.redirectPath = redirectPath
        self.metadataURL = metadataURL
        self.callbackTimeout = callbackTimeout
    }

    public var redirectURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = redirectHost
        components.port = Int(redirectPort)
        components.path = redirectPath
        guard let url = components.url else {
            // The URL is assembled from init parameters; it can only fail if a
            // caller supplied an invalid host or path. Fail loudly with enough
            // context to diagnose instead of crashing on a bare force-unwrap.
            preconditionFailure(
                "Invalid MCP OAuth redirect URL: host=\(redirectHost), port=\(redirectPort), path=\(redirectPath)"
            )
        }
        return url
    }
}

public nonisolated enum MCPHTTPAuthentication: Hashable, Sendable {
    case none
    case browserOAuth(MCPBrowserOAuthConfiguration)
}

public nonisolated struct MCPServerConfiguration: Hashable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let endpointURL: URL?
    public let httpHeaders: [String: String]
    public let httpAuthentication: MCPHTTPAuthentication
    public let preferredProtocolVersion: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        endpointURL: URL? = nil,
        httpHeaders: [String: String] = [:],
        httpAuthentication: MCPHTTPAuthentication = .none,
        preferredProtocolVersion: String = "2024-11-05"
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.endpointURL = endpointURL
        self.httpHeaders = httpHeaders
        self.httpAuthentication = httpAuthentication
        self.preferredProtocolVersion = preferredProtocolVersion
    }

    public var usesHTTPTransport: Bool {
        endpointURL != nil
    }

    public static func figmaDesktopLocal() -> MCPServerConfiguration {
        MCPServerConfiguration(
            executablePath: "",
            arguments: [],
            environment: [:],
            endpointURL: URL(string: "http://127.0.0.1:3845/mcp"),
            httpHeaders: [:],
            httpAuthentication: .none,
            preferredProtocolVersion: "2025-03-26"
        )
    }

    public static func isFigmaDesktopServerRunning(
        timeout: TimeInterval = 0.5
    ) async -> Bool {
        #if canImport(Network)
        let configuration = figmaDesktopLocal()
        guard
            let endpointURL = configuration.endpointURL,
            let host = endpointURL.host,
            let portValue = endpointURL.port,
            let port = NWEndpoint.Port(rawValue: UInt16(portValue))
        else {
            return false
        }

        return await isReachableTCPServer(
            host: NWEndpoint.Host(host),
            port: port,
            timeout: timeout
        )
        #else
        _ = timeout
        return false
        #endif
    }

    #if canImport(Network)
    private static func isReachableTCPServer(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            final class ReachabilityContinuationState: Sendable {
                private let didResume = Mutex(false)

                func beginFinishing() -> Bool {
                    didResume.withLock { didResume in
                        guard !didResume else {
                            return false
                        }

                        didResume = true
                        return true
                    }
                }
            }

            let connection = NWConnection(host: host, port: port, using: .tcp)
            let queue = DispatchQueue(label: "FeatureMCPBridgeKit.MCPReachability")
            let state = ReachabilityContinuationState()

            let finish: @Sendable (Bool) -> Void = { isReachable in
                guard state.beginFinishing() else {
                    return
                }

                continuation.resume(returning: isReachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                    connection.cancel()
                case .failed:
                    finish(false)
                case .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
                connection.cancel()
            }

            connection.start(queue: queue)
        }
    }
    #endif

}

public nonisolated enum MCPClientError: LocalizedError, Sendable {
    case missingContentLength
    case invalidContentLength
    case malformedTransport(String)
    case invalidResponse
    case connectionClosed
    case unsupportedPlatform
    case authorizationRequired(service: String, message: String)
    case browserAuthenticationFailed(String)
    case serverExited(status: Int32, message: String)
    case serverError(code: Int, message: String)
    case unsupportedMessageID

    public var errorDescription: String? {
        switch self {
        case .missingContentLength:
            return "Missing Content-Length header in MCP response."
        case .invalidContentLength:
            return "Invalid Content-Length value in MCP response."
        case let .malformedTransport(message):
            return "Malformed MCP transport: \(message)"
        case .invalidResponse:
            return "Invalid MCP response."
        case .connectionClosed:
            return "The MCP connection closed unexpectedly."
        case .unsupportedPlatform:
            return "MCP desktop tooling is unavailable on this platform."
        case let .authorizationRequired(_, message):
            return message
        case let .browserAuthenticationFailed(message):
            return message
        case let .serverExited(status, message):
            return "The MCP bridge exited early with status \(status). \(message)"
        case let .serverError(code, message):
            return "MCP server error \(code): \(message)"
        case .unsupportedMessageID:
            return "Unsupported MCP message identifier."
        }
    }
}
