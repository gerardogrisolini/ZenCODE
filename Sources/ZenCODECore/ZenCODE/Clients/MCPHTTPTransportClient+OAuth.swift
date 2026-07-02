//
//  MCPHTTPTransportClient+OAuth.swift
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

#if os(macOS)
import AppKit

extension MCPHTTPTransportClient {
    public var shouldUseBrowserOAuth: Bool {
        guard !hasStaticAuthorizationHeader else {
            return false
        }

        if case .browserOAuth = httpAuthentication {
            return true
        }

        return false
    }

    public func ensureOAuthAccessToken(
        requiringFreshLogin: Bool
    ) async throws -> MCPOAuthAccessToken {
        if requiringFreshLogin {
            oauthAccessToken = nil
        } else if let oauthAccessToken {
            return oauthAccessToken
        }

        if let oauthAuthenticationTask {
            return try await oauthAuthenticationTask.value
        }

        let authenticationTask = Task<MCPOAuthAccessToken, Error> {
            try await self.performBrowserOAuthLogin()
        }
        oauthAuthenticationTask = authenticationTask

        do {
            let accessToken = try await authenticationTask.value
            oauthAccessToken = accessToken
            oauthAuthenticationTask = nil
            return accessToken
        } catch {
            oauthAuthenticationTask = nil
            throw error
        }
    }

    public func performBrowserOAuthLogin() async throws -> MCPOAuthAccessToken {
        guard case let .browserOAuth(oauthConfiguration) = httpAuthentication else {
            throw MCPClientError.browserAuthenticationFailed(
                "This MCP endpoint is not configured for browser sign-in."
            )
        }
        let serviceName = oauthConfiguration.serviceName

        let metadata = try await loadOAuthMetadata(using: oauthConfiguration)
        let callbackServer = try MCPBrowserOAuthCallbackServer(
            redirectURL: oauthConfiguration.redirectURL,
            serviceName: serviceName
        )
        try await callbackServer.start()

        let callbackTask = Task {
            try await callbackServer.waitForCallback(timeout: oauthConfiguration.callbackTimeout)
        }

        defer {
            callbackTask.cancel()
            callbackServer.stop()
        }

        let clientRegistration = try await registerOAuthClient(
            using: metadata,
            oauthConfiguration: oauthConfiguration
        )
        let state = Self.randomURLSafeToken(byteCount: 24)
        let codeVerifier = Self.randomURLSafeToken(byteCount: 48)
        let authorizationURL = try makeAuthorizationURL(
            using: metadata,
            clientRegistration: clientRegistration,
            redirectURL: oauthConfiguration.redirectURL,
            serviceName: serviceName,
            state: state,
            codeVerifier: codeVerifier
        )

        try await Self.openBrowser(at: authorizationURL, serviceName: serviceName)

        let callback = try await callbackTask.value
        guard callback.state == state else {
            throw MCPClientError.browserAuthenticationFailed(
                "The \(serviceName) sign-in callback was rejected because the OAuth state did not match."
            )
        }

        return try await exchangeAuthorizationCode(
            callback.code,
            using: metadata,
            clientRegistration: clientRegistration,
            redirectURL: oauthConfiguration.redirectURL,
            serviceName: serviceName,
            codeVerifier: codeVerifier
        )
    }

    public func loadOAuthMetadata(
        using oauthConfiguration: MCPBrowserOAuthConfiguration
    ) async throws -> MCPOAuthAuthorizationServerMetadata {
        if let oauthMetadata {
            return oauthMetadata
        }

        let metadataURL = oauthConfiguration.metadataURL ?? Self.defaultOAuthMetadataURL(for: endpointURL)
        var request = URLRequest(url: metadataURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MCPClientError.browserAuthenticationFailed(
                "Unable to load \(oauthConfiguration.serviceName) sign-in metadata. \(message)"
            )
        }

        let metadata = try JSONDecoder().decode(MCPOAuthAuthorizationServerMetadata.self, from: data)
        oauthMetadata = metadata
        return metadata
    }

    public func registerOAuthClient(
        using metadata: MCPOAuthAuthorizationServerMetadata,
        oauthConfiguration: MCPBrowserOAuthConfiguration
    ) async throws -> MCPOAuthClientRegistration {
        if let oauthClientRegistration {
            return oauthClientRegistration
        }

        if let persistedClientRegistration = Self.loadPersistedOAuthClientRegistration(
            endpointURL: endpointURL,
            redirectURL: oauthConfiguration.redirectURL
        ) {
            oauthClientRegistration = persistedClientRegistration
            return persistedClientRegistration
        }

        var request = URLRequest(url: metadata.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            MCPOAuthDynamicClientRegistrationRequest(
                clientName: oauthConfiguration.clientName,
                redirectURIs: [oauthConfiguration.redirectURL.absoluteString],
                grantTypes: ["authorization_code", "refresh_token"],
                responseTypes: ["code"],
                tokenEndpointAuthMethod: "none"
            )
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MCPClientError.browserAuthenticationFailed(
                "Unable to register ZenCODE for \(oauthConfiguration.serviceName) sign-in. \(message)"
            )
        }

        let oauthClientRegistration = try JSONDecoder().decode(MCPOAuthClientRegistration.self, from: data)
        self.oauthClientRegistration = oauthClientRegistration
        Self.persistOAuthClientRegistration(
            oauthClientRegistration,
            endpointURL: endpointURL,
            redirectURL: oauthConfiguration.redirectURL
        )
        return oauthClientRegistration
    }

    public func makeAuthorizationURL(
        using metadata: MCPOAuthAuthorizationServerMetadata,
        clientRegistration: MCPOAuthClientRegistration,
        redirectURL: URL,
        serviceName: String,
        state: String,
        codeVerifier: String
    ) throws -> URL {
        let codeChallenge = Self.pkceCodeChallenge(for: codeVerifier)
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw MCPClientError.browserAuthenticationFailed(
                "Unable to build the \(serviceName) browser sign-in URL."
            )
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientRegistration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "resource", value: endpointURL.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizationURL = components.url else {
            throw MCPClientError.browserAuthenticationFailed(
                "Unable to build the \(serviceName) browser sign-in URL."
            )
        }

        return authorizationURL
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        using metadata: MCPOAuthAuthorizationServerMetadata,
        clientRegistration: MCPOAuthClientRegistration,
        redirectURL: URL,
        serviceName: String,
        codeVerifier: String
    ) async throws -> MCPOAuthAccessToken {
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncodedBody([
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientRegistration.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "resource", value: endpointURL.absoluteString),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MCPClientError.browserAuthenticationFailed(
                "\(serviceName) browser sign-in did not complete successfully. \(message)"
            )
        }

        let tokenResponse = try JSONDecoder().decode(MCPOAuthTokenResponse.self, from: data)
        return MCPOAuthAccessToken(
            accessToken: tokenResponse.accessToken,
            tokenType: tokenResponse.tokenType ?? "Bearer"
        )
    }

    public nonisolated static func firstJSONEventPayload(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var eventLines: [String] = []

        func payload(from lines: [String]) -> Data? {
            let dataLines = lines.compactMap { line -> String? in
                guard line.hasPrefix("data:") else {
                    return nil
                }

                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }

            let joined = dataLines.joined(separator: "\n")
            guard !joined.isEmpty, joined != "[DONE]" else {
                return nil
            }

            return joined.data(using: .utf8)
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.isEmpty {
                if let payload = payload(from: eventLines) {
                    return payload
                }
                eventLines.removeAll(keepingCapacity: true)
                continue
            }

            eventLines.append(rawLine)
        }

        return payload(from: eventLines)
    }

    public nonisolated static func isAuthorizationHeader(_ headerName: String) -> Bool {
        headerName.caseInsensitiveCompare("Authorization") == .orderedSame
    }

    public nonisolated static func defaultOAuthMetadataURL(for endpointURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = endpointURL.scheme
        components.host = endpointURL.host
        components.port = endpointURL.port
        components.path = "/.well-known/oauth-authorization-server"
        return components.url!
    }

    public nonisolated static func randomURLSafeToken(byteCount: Int) -> String {
        let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }
        let data = Data(bytes)
        return base64URLString(from: data)
    }

    public nonisolated static func pkceCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLString(from: Data(digest))
    }

    public nonisolated static func base64URLString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public nonisolated static func formEncodedBody(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    public nonisolated static func openBrowser(
        at url: URL,
        serviceName: String
    ) async throws {
        let didOpen = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        guard didOpen else {
            throw MCPClientError.browserAuthenticationFailed(
                "ZenCODE could not open the browser for \(serviceName) sign-in."
            )
        }
    }

    public nonisolated static func loadPersistedOAuthClientRegistration(
        endpointURL: URL,
        redirectURL: URL
    ) -> MCPOAuthClientRegistration? {
        guard let data = UserDefaults.standard.data(
            forKey: oauthClientRegistrationStorageKey(
                endpointURL: endpointURL,
                redirectURL: redirectURL
            )
        ) else {
            return nil
        }

        return try? JSONDecoder().decode(MCPOAuthClientRegistration.self, from: data)
    }

    public nonisolated static func persistOAuthClientRegistration(
        _ registration: MCPOAuthClientRegistration,
        endpointURL: URL,
        redirectURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(registration) else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey: oauthClientRegistrationStorageKey(
                endpointURL: endpointURL,
                redirectURL: redirectURL
            )
        )
    }

    public nonisolated static func oauthClientRegistrationStorageKey(
        endpointURL: URL,
        redirectURL: URL
    ) -> String {
        "MCPHTTPTransportClient.oauthClientRegistration.\(endpointURL.absoluteString)|\(redirectURL.absoluteString)"
    }
}

public nonisolated struct MCPOAuthAuthorizationServerMetadata: Decodable, Hashable, Sendable {
    public let issuer: URL?
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL

    public enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

public nonisolated struct MCPOAuthDynamicClientRegistrationRequest: Encodable, Hashable, Sendable {
    public let clientName: String
    public let redirectURIs: [String]
    public let grantTypes: [String]
    public let responseTypes: [String]
    public let tokenEndpointAuthMethod: String

    public enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

public nonisolated struct MCPOAuthClientRegistration: Codable, Hashable, Sendable {
    public let clientID: String

    public enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

public nonisolated struct MCPOAuthTokenResponse: Decodable, Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String?

    public enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

public nonisolated struct MCPOAuthAccessToken: Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String

    public var authorizationHeaderValue: String {
        "\(tokenType) \(accessToken)"
    }
}

public nonisolated struct MCPOAuthCallback: Hashable, Sendable {
    public let code: String
    public let state: String
}
#endif
