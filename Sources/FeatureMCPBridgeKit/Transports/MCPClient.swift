//
//  MCPClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

#if os(macOS)
public actor MCPClient {
    public let configuration: MCPServerConfiguration
    public let httpTransport: MCPHTTPTransportClient?
    public var process: Process?
    public var inputHandle: FileHandle?
    /// Parent-owned read ends of the local bridge pipes. They are closed after
    /// their detached non-blocking readers have joined, including when a bridge
    /// exits badly or leaves a descendant holding its write end open.
    public var outputHandle: FileHandle?
    public var errorHandle: FileHandle?
    public var readLoopTask: Task<Void, Never>?
    public var errorLoopTask: Task<Void, Never>?
    var diagnosticMonitorProcess: Process?
    var diagnosticMonitorTask: Task<Void, Never>?
    var diagnosticMonitorOutputHandle: FileHandle?
    var diagnosticMonitorConnectionID: UUID?
    public var buffer = Data()
    public var stderrBuffer = Data()
    public var terminalBridgeError: MCPClientError?
    /// Readers are bound to one local bridge generation. This prevents a
    /// callback that was already in flight during teardown from mutating a
    /// subsequent connection.
    var activeConnectionID: UUID?
    /// The generation whose process exited and whose non-blocking readers are
    /// draining their final bytes before the exit is classified.
    var terminatingConnectionID: UUID?
    public var nextRequestID = 1
    public var pendingResponses: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    public let isDebugLoggingEnabled = false
    public let buildMarker = "MCPClient build marker: optimistic-handshake-ndjson-v5"
    public var lastBufferedPrefixSnapshot = ""
    public var stdoutChunkTraceURLs: [URL] = []
    public var stdoutReassembledBufferURLs: [URL] = []
    public var lastReassembledBufferSize: Int = -1
    var pendingRequestMethods: [Int: String] = [:]
    public let localTransportPolicy: LocalMCPTransportPolicy

    public init(
        configuration: MCPServerConfiguration,
        localTransportPolicy: LocalMCPTransportPolicy = .standard
    ) {
        self.configuration = configuration
        self.localTransportPolicy = localTransportPolicy
        self.httpTransport = configuration.endpointURL.map {
            MCPHTTPTransportClient(
                endpointURL: $0,
                httpHeaders: configuration.httpHeaders,
                httpAuthentication: configuration.httpAuthentication,
                preferredProtocolVersion: configuration.preferredProtocolVersion
            )
        }
    }
}
#else
public actor MCPClient {
    public init(
        configuration: MCPServerConfiguration,
        localTransportPolicy: LocalMCPTransportPolicy = .standard
    ) {
        _ = configuration
        _ = localTransportPolicy
    }

    public func connect() async throws {
        throw MCPClientError.unsupportedPlatform
    }

    public func listTools() async throws -> MCPListToolsResult {
        throw MCPClientError.unsupportedPlatform
    }

    public func callTool(named: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        throw MCPClientError.unsupportedPlatform
    }

    public func disconnect() async {}
}
#endif
