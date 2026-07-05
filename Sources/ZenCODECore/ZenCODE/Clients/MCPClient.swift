//
//  MCPClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

#if os(macOS)
public actor MCPClient {
    public let configuration: MCPServerConfiguration
    public let httpTransport: MCPHTTPTransportClient?
    public var process: Process?
    public var inputHandle: FileHandle?
    public var readLoopTask: Task<Void, Never>?
    public var errorLoopTask: Task<Void, Never>?
    var mcpBridgeLogMonitorProcess: Process?
    var mcpBridgeLogMonitorTask: Task<Void, Never>?
    public var buffer = Data()
    public var stderrBuffer = Data()
    public var terminalBridgeError: MCPClientError?
    public var nextRequestID = 1
    public var pendingResponses: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    public let isDebugLoggingEnabled = false
    public let buildMarker = "MCPClient build marker: optimistic-handshake-ndjson-v5"
    public var lastBufferedPrefixSnapshot = ""
    public var stdoutChunkTraceURLs: [URL] = []
    public var stdoutReassembledBufferURLs: [URL] = []
    public var lastReassembledBufferSize: Int = -1
    var pendingRequestMethods: [Int: String] = [:]

    public init(configuration: MCPServerConfiguration) {
        self.configuration = configuration
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
    public init(configuration: MCPServerConfiguration) {}

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
