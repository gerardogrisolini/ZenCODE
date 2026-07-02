//
//  MCPHTTPTransportClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

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
    public var connectTask: Task<Void, Error>?
    public var oauthMetadata: MCPOAuthAuthorizationServerMetadata?
    public var oauthClientRegistration: MCPOAuthClientRegistration?
    public var oauthAccessToken: MCPOAuthAccessToken?
    public var oauthAuthenticationTask: Task<MCPOAuthAccessToken, Error>?

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
