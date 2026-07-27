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
    let configuration: MCPServerConfiguration
    let httpTransport: MCPHTTPTransportClient?
    var process: Process?
    var inputHandle: FileHandle?
    /// Serialized, non-blocking writer for the local bridge's stdin. It lives
    /// outside this actor so a full pipe back-pressures the writer task instead
    /// of blocking the actor (which would deadlock disconnect()/cancellation).
    var writer: MCPLocalTransportWriter?
    /// Parent-owned read ends of the local bridge pipes. They are closed after
    /// their detached non-blocking readers have joined, including when a bridge
    /// exits badly or leaves a descendant holding its write end open.
    var outputHandle: FileHandle?
    var errorHandle: FileHandle?
    var readLoopTask: Task<Void, Never>?
    var errorLoopTask: Task<Void, Never>?
    var diagnosticMonitorProcess: Process?
    var diagnosticMonitorTask: Task<Void, Never>?
    var diagnosticMonitorOutputHandle: FileHandle?
    var diagnosticMonitorConnectionID: UUID?
    var buffer = Data()
    var stderrBuffer = Data()
    var terminalBridgeError: MCPClientError?
    /// Readers are bound to one local bridge generation. This prevents a
    /// callback that was already in flight during teardown from mutating a
    /// subsequent connection.
    var activeConnectionID: UUID?
    /// The generation whose process exited and whose non-blocking readers are
    /// draining their final bytes before the exit is classified.
    var terminatingConnectionID: UUID?
    var nextRequestID = 1
    var pendingResponses: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    let isDebugLoggingEnabled = false
    let buildMarker = "MCPClient build marker: optimistic-handshake-ndjson-v5"
    var lastBufferedPrefixSnapshot = ""
    var stdoutChunkTraceURLs: [URL] = []
    var stdoutReassembledBufferURLs: [URL] = []
    var lastReassembledBufferSize: Int = -1
    var pendingRequestMethods: [Int: String] = [:]
    let localTransportPolicy: LocalMCPTransportPolicy
    /// Coalesces concurrent local process handshakes and fences a late handshake
    /// after disconnect() invalidates the current connection generation.
    let localConnectFlight = MCPSingleFlight<Void>()

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
