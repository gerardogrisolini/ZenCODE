//
//  AnthropicSubscriptionAuthService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
#if canImport(os)
import os
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import AppKit
import CryptoKit
#if canImport(Network)
import Network
#endif

public struct AnthropicSubscriptionCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpiredOrNearlyExpired: Bool {
        expiresAt.timeIntervalSinceNow <= 60
    }
}

public enum AnthropicSubscriptionAuthError: LocalizedError {
    case unsupportedPlatform
    case callbackServerUnavailable
    case callbackCancelled
    case callbackRequestInvalid
    case stateMismatch
    case missingAuthorizationCode
    case missingOAuthState
    case tokenExchangeFailed(status: Int, body: String)
    case invalidTokenResponse
    case browserOpenFailed
    case randomBytesFailed(Int32)
    case missingCredentials
    case invalidCredentials
    case missingAccessToken
    case missingRefreshToken

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Anthropic Subscription browser sign-in is available on macOS."
        case .callbackServerUnavailable:
            return "Unable to start the local Anthropic sign-in callback server."
        case .callbackCancelled:
            return "Anthropic sign-in was cancelled."
        case .callbackRequestInvalid:
            return "Anthropic sign-in callback was invalid."
        case .stateMismatch:
            return "Anthropic sign-in state did not match."
        case .missingAuthorizationCode:
            return "Anthropic sign-in did not return an authorization code."
        case .missingOAuthState:
            return "Anthropic sign-in did not return an OAuth state."
        case let .tokenExchangeFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Anthropic sign-in token exchange failed with HTTP \(status)."
            }
            return "Anthropic sign-in token exchange failed with HTTP \(status): \(detail)"
        case .invalidTokenResponse:
            return "Anthropic sign-in returned an invalid token response."
        case .browserOpenFailed:
            return "Unable to open the Anthropic sign-in page."
        case let .randomBytesFailed(status):
            return "Unable to create Anthropic sign-in verifier (\(status))."
        case .missingCredentials:
            return "Anthropic Subscription is not connected. Sign in from Settings, then try again."
        case .invalidCredentials:
            return "Anthropic Subscription credentials could not be read."
        case .missingAccessToken:
            return "Anthropic Subscription credentials do not contain an access token."
        case .missingRefreshToken:
            return "Anthropic Subscription credentials do not contain a refresh token."
        }
    }
}

public final class AnthropicSubscriptionSignInSession: @unchecked Sendable {
    public let authorizationURL: URL

    private let verifier: String
    private let state: String
    private let authorizationState = AnthropicSubscriptionSignInAuthorizationState()

    fileprivate init(
        authorizationURL: URL,
        verifier: String,
        state: String
    ) {
        self.authorizationURL = authorizationURL
        self.verifier = verifier
        self.state = state
    }

    public func waitForCredentials() async throws -> AnthropicSubscriptionCredentials {
        let result = try await waitForAuthorizationResult()
        let credentials = try await AnthropicSubscriptionAuthService.exchangeAuthorizationCode(
            code: result.code,
            state: result.state,
            verifier: verifier
        )
        try AnthropicSubscriptionAuthService.saveCredentials(credentials)
        return credentials
    }

    public func submitAuthorizationInput(_ input: String) throws {
        let result = try authorizationResult(fromAuthorizationInput: input)
        complete(.success(result))
    }

    public func cancel() {
        Task {
            let continuation = await authorizationState.cancel()
            continuation?.resume(throwing: AnthropicSubscriptionAuthError.callbackCancelled)
        }
    }

    private func waitForAuthorizationResult() async throws -> AnthropicSubscriptionAuthorizationResult {
        try await authorizationState.waitForAuthorizationResult()
    }

    private func authorizationResult(
        fromAuthorizationInput input: String
    ) throws -> AnthropicSubscriptionAuthorizationResult {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }

        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "code" }) == true {
            return try authorizationResult(from: components, requireState: false)
        }

        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let returnedState = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard returnedState == state else {
                    throw AnthropicSubscriptionAuthError.stateMismatch
                }
                let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else {
                    throw AnthropicSubscriptionAuthError.missingAuthorizationCode
                }
                return AnthropicSubscriptionAuthorizationResult(
                    code: code,
                    state: returnedState
                )
            }
        }

        if value.contains("code=") {
            let query = value.hasPrefix("?") ? String(value.dropFirst()) : value
            if let components = URLComponents(string: "https://console.anthropic.com/oauth/code/callback?\(query)"),
               components.queryItems?.contains(where: { $0.name == "code" }) == true {
                return try authorizationResult(from: components, requireState: false)
            }
        }

        throw AnthropicSubscriptionAuthError.missingOAuthState
    }

    private func authorizationResult(
        from components: URLComponents,
        requireState: Bool
    ) throws -> AnthropicSubscriptionAuthorizationResult {
        let queryItems = components.queryItems ?? []
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let returnedState {
            guard returnedState == state else {
                throw AnthropicSubscriptionAuthError.stateMismatch
            }
        } else if requireState {
            throw AnthropicSubscriptionAuthError.missingOAuthState
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw AnthropicSubscriptionAuthError.missingAuthorizationCode
        }
        return AnthropicSubscriptionAuthorizationResult(
            code: code,
            state: returnedState ?? state
        )
    }

    private func complete(_ result: Result<AnthropicSubscriptionAuthorizationResult, Error>) {
        Task {
            let continuation = await authorizationState.complete(result)
            continuation?.resume(with: result)
        }
    }
}

private actor AnthropicSubscriptionSignInAuthorizationState {
    private var waitContinuation: CheckedContinuation<AnthropicSubscriptionAuthorizationResult, Error>?
    private var pendingResult: Result<AnthropicSubscriptionAuthorizationResult, Error>?
    private var isCancelled = false

    func waitForAuthorizationResult() async throws -> AnthropicSubscriptionAuthorizationResult {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingResult {
                self.pendingResult = nil
                continuation.resume(with: pendingResult)
                return
            }
            if isCancelled {
                continuation.resume(throwing: AnthropicSubscriptionAuthError.callbackCancelled)
                return
            }
            waitContinuation = continuation
        }
    }

    func cancel() -> CheckedContinuation<AnthropicSubscriptionAuthorizationResult, Error>? {
        guard !isCancelled else {
            return nil
        }
        isCancelled = true
        let continuation = waitContinuation
        waitContinuation = nil
        return continuation
    }

    func complete(
        _ result: Result<AnthropicSubscriptionAuthorizationResult, Error>
    ) -> CheckedContinuation<AnthropicSubscriptionAuthorizationResult, Error>? {
        guard !isCancelled else {
            return nil
        }
        isCancelled = true
        let continuation = waitContinuation
        waitContinuation = nil
        if continuation == nil {
            pendingResult = result
        }
        return continuation
    }
}

public enum AnthropicSubscriptionAuthService {
    private static let refreshCoordinator = AnthropicSubscriptionRefreshCoordinator()
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURLs = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!
    ]

    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    public static func signIn() async throws -> AnthropicSubscriptionCredentials {
        let session = try await startSignIn()

        let didOpen = await openAuthorizationURL(session.authorizationURL)
        guard didOpen else {
            throw AnthropicSubscriptionAuthError.browserOpenFailed
        }

        print("After authorizing Claude, paste the authorization code shown in the browser.")
        if let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !input.isEmpty {
            try session.submitAuthorizationInput(input)
        }
        return try await session.waitForCredentials()
    }

    public static func openAuthorizationURL(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    public static func startSignIn() async throws -> AnthropicSubscriptionSignInSession {
        let flow = try authorizationFlow()
        return AnthropicSubscriptionSignInSession(
            authorizationURL: flow.url,
            verifier: flow.verifier,
            state: flow.state
        )
    }

    public static func refresh(
        credentials: AnthropicSubscriptionCredentials
    ) async throws -> AnthropicSubscriptionCredentials {
        try await refreshCoordinator.refresh(credentials: credentials) { credentials in
            let refreshedCredentials = try await refreshAccessToken(
                refreshToken: credentials.refreshToken
            )
            try saveCredentials(refreshedCredentials)
            return refreshedCredentials
        }
    }

    public static func loadCredentials() throws -> AnthropicSubscriptionCredentials {
        if let environmentToken = ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            let refreshToken = ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? environmentToken
            return AnthropicSubscriptionCredentials(
                accessToken: environmentToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                scope: ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_SCOPE"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            )
        }

        guard let credentials = AgentSettingsManifestStore.load()?.anthropicSubscriptionCredentials else {
            throw AnthropicSubscriptionAuthError.missingCredentials
        }
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicSubscriptionAuthError.invalidCredentials
        }
        return credentials
    }

    public static func loadValidCredentials() async throws -> AnthropicSubscriptionCredentials {
        let credentials = try loadCredentials()
        guard credentials.isExpiredOrNearlyExpired else {
            return credentials
        }
        return try await refresh(credentials: credentials)
    }

    public static func saveCredentials(_ credentials: AnthropicSubscriptionCredentials) throws {
        try AgentSettingsManifestStore.saveAnthropicSubscriptionCredentials(credentials)
    }

    public static func removeCredentials() {
        try? AgentSettingsManifestStore.saveAnthropicSubscriptionCredentials(nil)
    }

    private static func authorizationFlow() throws -> (
        verifier: String,
        state: String,
        url: URL
    ) {
        let verifier = try randomBase64URLString(byteCount: 32)
        let challenge = sha256Base64URL(verifier)
        // Anthropic's Claude Code OAuth flow uses the verifier as the state value.
        let state = verifier

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components.url else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }
        return (verifier, state, url)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        state: String,
        verifier: String
    ) async throws -> AnthropicSubscriptionCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
    }

    private static func refreshAccessToken(
        refreshToken: String
    ) async throws -> AnthropicSubscriptionCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ], fallbackRefreshToken: refreshToken)
    }

    private static func tokenRequest(
        parameters: [String: String],
        fallbackRefreshToken: String? = nil
    ) async throws -> AnthropicSubscriptionCredentials {
        var lastFailure: AnthropicSubscriptionAuthError?
        for tokenURL in tokenURLs {
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AnthropicSubscriptionAuthError.invalidTokenResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                lastFailure = AnthropicSubscriptionAuthError.tokenExchangeFailed(
                    status: httpResponse.statusCode,
                    body: String(decoding: data, as: UTF8.self)
                )
                continue
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            let accessToken = tokenResponse.accessToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let refreshToken = tokenResponse.refreshToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? fallbackRefreshToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty

            guard !accessToken.isEmpty else {
                throw AnthropicSubscriptionAuthError.missingAccessToken
            }
            guard let refreshToken else {
                throw AnthropicSubscriptionAuthError.missingRefreshToken
            }
            guard tokenResponse.expiresIn > 0 else {
                throw AnthropicSubscriptionAuthError.invalidTokenResponse
            }

            let expirationInterval = max(tokenResponse.expiresIn, 60)

            return AnthropicSubscriptionCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expirationInterval)),
                scope: tokenResponse.scope?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            )
        }
        throw lastFailure ?? AnthropicSubscriptionAuthError.invalidTokenResponse
    }


    private static func randomBase64URLString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AnthropicSubscriptionAuthError.randomBytesFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private actor AnthropicSubscriptionRefreshCoordinator {
    private var inFlightRefreshes: [String: Task<AnthropicSubscriptionCredentials, Error>] = [:]

    func refresh(
        credentials: AnthropicSubscriptionCredentials,
        operation: @escaping @Sendable (AnthropicSubscriptionCredentials) async throws -> AnthropicSubscriptionCredentials
    ) async throws -> AnthropicSubscriptionCredentials {
        let refreshKey = credentials.refreshToken
        if let inFlightRefresh = inFlightRefreshes[refreshKey] {
            return try await inFlightRefresh.value
        }

        let task = Task {
            try await operation(credentials)
        }
        inFlightRefreshes[refreshKey] = task
        defer {
            inFlightRefreshes[refreshKey] = nil
        }
        return try await task.value
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct AnthropicSubscriptionAuthorizationResult: Sendable {
    let code: String
    let state: String
}
#endif
