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
import ToolCore
#if canImport(Network)
import Network
import Synchronization
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
        return components.url!
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

    public static func remoteHTTPFromEnvironment(
        urlKey: String,
        headersKey: String,
        bearerTokenKey: String? = nil,
        preferredProtocolVersion: String = "2025-03-26",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        guard let rawURL = environment[urlKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let endpointURL = URL(string: rawURL),
            !rawURL.isEmpty else {
            return nil
        }

        var httpHeaders = parseHTTPHeaders(
            from: environment[headersKey]
        )

        if let bearerTokenKey,
           let token = environment[bearerTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty,
           httpHeaders["Authorization"] == nil {
            httpHeaders["Authorization"] = "Bearer \(token)"
        }

        return MCPServerConfiguration(
            executablePath: "",
            arguments: [],
            environment: [:],
            endpointURL: endpointURL,
            httpHeaders: httpHeaders,
            preferredProtocolVersion: preferredProtocolVersion
        )
    }

    public static func localProcessFromEnvironment(
        executableKey: String,
        argumentsKey: String,
        inheritedEnvironmentPrefixes: [String],
        excludedEnvironmentKeys: Set<String> = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        guard let rawExecutablePath = environment[executableKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawExecutablePath.isEmpty else {
            return nil
        }

        let arguments = environment[argumentsKey]?
            .split(separator: "\n")
            .map(String.init) ?? []

        let processEnvironment = environment.reduce(into: [String: String]()) { partialResult, pair in
            let (key, value) = pair
            guard !excludedEnvironmentKeys.contains(key) else {
                return
            }

            guard inheritedEnvironmentPrefixes.contains(where: key.hasPrefix) else {
                return
            }

            partialResult[key] = value
        }

        return MCPServerConfiguration(
            executablePath: rawExecutablePath,
            arguments: arguments,
            environment: processEnvironment,
            preferredProtocolVersion: "2024-11-05"
        )
    }

    public static func figmaRemote() -> MCPServerConfiguration {
        MCPServerConfiguration(
            executablePath: "",
            arguments: [],
            environment: [:],
            endpointURL: URL(string: "https://mcp.figma.com/mcp"),
            httpHeaders: [:],
            httpAuthentication: .browserOAuth(
                MCPBrowserOAuthConfiguration(
                    clientName: "Figma MCP client",
                    serviceName: "Figma",
                    redirectHost: "127.0.0.1",
                    redirectPort: 8788,
                    redirectPath: "/figma-callback"
                )
            ),
            preferredProtocolVersion: "2025-03-26"
        )
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

    private static func parseHTTPHeaders(from rawValue: String?) -> [String: String] {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return [:]
        }

        return rawValue
            .split(separator: "\n")
            .reduce(into: [String: String]()) { partialResult, rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      let separatorIndex = line.firstIndex(of: ":") else {
                    return
                }

                let headerName = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let headerValue = line[line.index(after: separatorIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !headerName.isEmpty, !headerValue.isEmpty else {
                    return
                }

                partialResult[String(headerName)] = headerValue
            }
    }
}

public nonisolated enum MCPClientError: LocalizedError, Sendable {
    case missingContentLength
    case invalidContentLength
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
