import Foundation
import ToolCore

/// How the HTTP transport authenticates beyond the configured headers.
public nonisolated enum MCPHTTPAuthentication: Hashable, Sendable {
    /// Only the configured headers (an `Authorization` header included).
    case none
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
}

public nonisolated enum MCPClientError: LocalizedError, Sendable {
    case malformedTransport(String)
    case invalidResponse
    case connectionClosed
    case unsupportedPlatform
    case authorizationRequired(service: String, message: String)
    case serverExited(status: Int32, message: String)
    case serverError(code: Int, message: String)
    case unsupportedMessageID

    public var errorDescription: String? {
        switch self {
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
        case let .serverExited(status, message):
            return "The MCP bridge exited early with status \(status). \(message)"
        case let .serverError(code, message):
            return "MCP server error \(code): \(message)"
        case .unsupportedMessageID:
            return "Unsupported MCP message identifier."
        }
    }
}
