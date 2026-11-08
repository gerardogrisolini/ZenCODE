//
//  ChatGPTSubscriptionAuthService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct CodexAgentCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountID: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    public var isExpiredOrNearlyExpired: Bool {
        expiresAt.timeIntervalSinceNow <= 60
    }
}

#if canImport(os)
import os
#endif

public enum ChatGPTSubscriptionAuthError: LocalizedError {
    case unsupportedPlatform
    case callbackServerUnavailable
    case callbackCancelled
    case callbackRequestInvalid
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(status: Int, body: String)
    case invalidTokenResponse
    case browserOpenFailed
    case deviceCodeRequestFailed(status: Int, body: String)
    case deviceCodeResponseInvalid
    case deviceCodePollingFailed(status: Int, body: String)
    case deviceCodeTimedOut
    case deviceCodeCancelled
    case randomBytesFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "ChatGPT Subscription sign-in is unavailable on this platform."
        case .callbackServerUnavailable:
            return "Unable to start the local ChatGPT sign-in callback server."
        case .callbackCancelled:
            return "ChatGPT sign-in was cancelled."
        case .callbackRequestInvalid:
            return "ChatGPT sign-in callback was invalid."
        case .stateMismatch:
            return "ChatGPT sign-in state did not match."
        case .missingAuthorizationCode:
            return "ChatGPT sign-in did not return an authorization code."
        case let .tokenExchangeFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT sign-in token exchange failed with HTTP \(status)."
            }
            return "ChatGPT sign-in token exchange failed with HTTP \(status): \(detail)"
        case .invalidTokenResponse:
            return "ChatGPT sign-in returned an invalid token response."
        case .browserOpenFailed:
            return "Unable to open the ChatGPT sign-in page."
        case let .deviceCodeRequestFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT sign-in device-code request failed with HTTP \(status)."
            }
            return "ChatGPT sign-in device-code request failed with HTTP \(status): \(detail)"
        case .deviceCodeResponseInvalid:
            return "ChatGPT sign-in returned an invalid device-code response."
        case let .deviceCodePollingFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT sign-in device-code polling failed with HTTP \(status)."
            }
            return "ChatGPT sign-in device-code polling failed with HTTP \(status): \(detail)"
        case .deviceCodeTimedOut:
            return "ChatGPT sign-in timed out waiting for browser authorization."
        case .deviceCodeCancelled:
            return "ChatGPT sign-in was cancelled."
        case let .randomBytesFailed(status):
            return "Unable to create ChatGPT sign-in verifier (\(status))."
        }
    }
}

#if os(macOS)
public final class ChatGPTSubscriptionSignInSession: Sendable {
    public let authorizationURL: URL

    /// True when the local callback listener started successfully. When false
    /// the browser cannot redirect back to ZenCODE and ``waitForCredentials(persist:)``
    /// falls back to asking the user to paste the authorization code.
    public let isCallbackServerAvailable: Bool

    private let verifier: String
    private let callbackServer: ChatGPTSubscriptionCallbackServer
    private let promptAuthorizationInput: @Sendable (_ label: String) throws -> String

    fileprivate init(
        authorizationURL: URL,
        verifier: String,
        callbackServer: ChatGPTSubscriptionCallbackServer,
        isCallbackServerAvailable: Bool,
        promptAuthorizationInput: @escaping @Sendable (_ label: String) throws -> String = { _ in
            readLine() ?? ""
        }
    ) {
        self.authorizationURL = authorizationURL
        self.verifier = verifier
        self.callbackServer = callbackServer
        self.isCallbackServerAvailable = isCallbackServerAvailable
        self.promptAuthorizationInput = promptAuthorizationInput
    }

    public func waitForCredentials() async throws -> CodexAgentCredentials {
        try await waitForCredentials(persist: true)
    }

    func waitForCredentials(
        persist: Bool
    ) async throws -> CodexAgentCredentials {
        defer {
            Task(name: "ChatGPT authorization background task") {
                await callbackServer.stop()
            }
        }

        let code: String
        if isCallbackServerAvailable {
            code = try await callbackServer.waitForCode()
        } else {
            // No local callback: the browser has nowhere to redirect back, so
            // degrade gracefully and collect the authorization code directly
            // from the user instead of suspending forever.
            let input = try promptAuthorizationInput("Authorization code")
            code = try callbackServer.authorizationCode(fromAuthorizationInput: input)
        }
        let credentials = try await ChatGPTSubscriptionAuthService.exchangeAuthorizationCode(
            code: code,
            verifier: verifier
        )
        if persist {
            try ChatGPTSubscriptionAuthService.saveCredentials(credentials)
        }
        return credentials
    }

    public func submitAuthorizationInput(_ input: String) throws {
        try callbackServer.submitAuthorizationInput(input)
    }

    public func cancel() {
        Task(name: "ChatGPT authorization background task") {
            await callbackServer.stop()
        }
    }
}
#endif

public enum ChatGPTSubscriptionAuthService {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// A refresh token can be rotated by the authorization server. Keep one
    /// request in flight per token so simultaneous expired-session checks and
    /// 401/403 upgrade retries do not race to use the same token.
    private static let refreshCoordinator = ChatGPTSubscriptionRefreshCoordinator()
    private static let issuer = "https://auth.openai.com"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = "openid profile email offline_access"
    private static let originator = "ZenCODE"

    public static func signIn() async throws -> CodexAgentCredentials {
        #if os(macOS)
        let session = try await startSignIn()
        print("To continue, complete ChatGPT login in your browser.")
        if session.isCallbackServerAvailable {
            print("If the browser does not open, open this URL:")
            print(session.authorizationURL.absoluteString)
        } else {
            print("The local sign-in callback server is unavailable; the browser will not redirect back automatically.")
            print("After completing the login, paste the authorization code here.")
            print("Open this URL to start the login:")
            print(session.authorizationURL.absoluteString)
        }
        guard await openAuthorizationURL(session.authorizationURL) else {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }
        return try await session.waitForCredentials()
        #else
        return try await signInWithDeviceCode { url, code in
            print("Open this URL to connect ChatGPT Subscription:")
            print(url.absoluteString)
            print("Enter this code: \(code)")
            _ = await openAuthorizationURL(url)
        }
        #endif
    }

    public static func openAuthorizationURL(_ url: URL) async -> Bool {
        await SubscriptionBrowserLauncher.open(url)
    }

    #if os(macOS)
    public static func startSignIn(
        promptAuthorizationInput: @escaping @Sendable (_ label: String) throws -> String = { _ in
            readLine() ?? ""
        }
    ) async throws -> ChatGPTSubscriptionSignInSession {
        let flow = try authorizationFlow()
        let callbackServer = ChatGPTSubscriptionCallbackServer(state: flow.state)
        var isCallbackServerAvailable = true
        do {
            try await callbackServer.start()
        } catch {
            // The port (typically 1455) is taken or the listener failed to
            // start. Do not fail the whole sign-in: the session degrades to a
            // manually pasted authorization code.
            isCallbackServerAvailable = false
        }
        return ChatGPTSubscriptionSignInSession(
            authorizationURL: flow.url,
            verifier: flow.verifier,
            callbackServer: callbackServer,
            isCallbackServerAvailable: isCallbackServerAvailable,
            promptAuthorizationInput: promptAuthorizationInput
        )
    }
    #endif

    public static func refresh(credentials: CodexAgentCredentials) async throws -> CodexAgentCredentials {
        try await refresh(credentials: credentials, persist: true)
    }

    static func refresh(
        credentials: CodexAgentCredentials,
        persist: Bool,
        tokenRefresher: @escaping @Sendable (String) async throws -> CodexAgentCredentials = {
            try await refreshAccessToken(refreshToken: $0)
        }
    ) async throws -> CodexAgentCredentials {
        let refreshedCredentials = try await refreshCoordinator.refresh(
            credentials: credentials
        ) { credentials in
            let refreshedCredentials = try await tokenRefresher(credentials.refreshToken)
            return refreshedCredentials
        }
        if persist {
            try ChatGPTSubscriptionAuthService.saveCredentials(refreshedCredentials)
        }
        return refreshedCredentials
    }

    private static func authorizationFlow() throws -> (
        verifier: String,
        state: String,
        url: URL
    ) {
        let verifier = try Data.randomBase64URLString(
            byteCount: 32,
            randomBytesFailure: ChatGPTSubscriptionAuthError.randomBytesFailed
        )
        let challenge = verifier.sha256Base64URL()
        let state = try Data.randomBase64URLString(
            byteCount: 16,
            randomBytesFailure: ChatGPTSubscriptionAuthError.randomBytesFailed
        )

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator)
        ]

        guard let url = components.url else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        return (verifier, state, url)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        verifier: String
    ) async throws -> CodexAgentCredentials {
        try await exchangeAuthorizationCode(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI
        )
    }
}
