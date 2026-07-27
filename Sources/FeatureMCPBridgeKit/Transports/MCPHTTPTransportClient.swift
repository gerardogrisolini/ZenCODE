//
//  MCPHTTPTransportClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

#if os(macOS)
public actor MCPHTTPTransportClient {
    public let endpointURL: URL
    public let httpHeaders: [String: String]
    public let httpAuthentication: MCPHTTPAuthentication
    public let preferredProtocolVersion: String
    public let urlSession: URLSession
    public let hasStaticAuthorizationHeader: Bool
    public var sessionIdentifier: String?
    public var isInitialized = false
    public var nextRequestID = 1
    /// Monotonically fences all request completions from a previous session.
    var sessionGeneration: UInt64 = 0
    /// URLSession work has to be cancelled explicitly: cancelling only the
    /// waiter does not stop an already-scheduled HTTP request.
    var requestTasks: [UUID: URLSessionDataTask] = [:]
    /// Coalesces concurrent `connect()` calls. Unlike a bare `Task` handle it is
    /// cancellation-aware for every joiner and fences a late handshake result
    /// after `disconnect()`.
    public let connectFlight = MCPSingleFlight<Void>()
    public var oauthMetadata: MCPOAuthAuthorizationServerMetadata?
    public var oauthClientRegistration: MCPOAuthClientRegistration?
    public var oauthAccessToken: MCPOAuthAccessToken?
    /// Coalesces concurrent browser sign-ins with the same cancellation and
    /// late-result fencing guarantees as `connectFlight`.
    public let oauthAuthenticationFlight = MCPSingleFlight<MCPOAuthAccessToken>()

    public init(
        endpointURL: URL,
        httpHeaders: [String: String],
        httpAuthentication: MCPHTTPAuthentication,
        preferredProtocolVersion: String
    ) {
        self.endpointURL = endpointURL
        self.httpHeaders = httpHeaders
        self.httpAuthentication = httpAuthentication
        self.preferredProtocolVersion = preferredProtocolVersion
        self.hasStaticAuthorizationHeader = httpHeaders.keys.contains(where: Self.isAuthorizationHeader)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        self.urlSession = URLSession(configuration: configuration)
    }
}
#endif
