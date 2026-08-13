//
//  ChatGPTSubscriptionAuthService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif
#if canImport(Security)
import Security
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

    private let verifier: String
    private let callbackServer: ChatGPTSubscriptionCallbackServer

    fileprivate init(
        authorizationURL: URL,
        verifier: String,
        callbackServer: ChatGPTSubscriptionCallbackServer
    ) {
        self.authorizationURL = authorizationURL
        self.verifier = verifier
        self.callbackServer = callbackServer
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

        let code = try await callbackServer.waitForCode()
        let credentials = try await ChatGPTSubscriptionAuthService.exchangeAuthorizationCode(
            code: code,
            verifier: verifier
        )
        if persist {
            try CodexAgentModel.saveCredentials(credentials)
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
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// A refresh token can be rotated by the authorization server. Keep one
    /// request in flight per token so simultaneous expired-session checks and
    /// 401/403 upgrade retries do not race to use the same token.
    private static let refreshCoordinator = ChatGPTSubscriptionRefreshCoordinator()
    private static let issuer = "https://auth.openai.com"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let deviceCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let deviceAuthorizationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = "openid profile email offline_access"
    private static let originator = "ZenCODE"

    public static func signIn() async throws -> CodexAgentCredentials {
        #if os(macOS)
        let session = try await startSignIn()
        print("To continue, complete ChatGPT login in your browser.")
        print("If the browser does not open, open this URL:")
        print(session.authorizationURL.absoluteString)
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

    public static func signInWithDeviceCode(
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        try await signInWithDeviceCode(
            persist: true,
            notifyUser: notifyUser
        )
    }

    static func signInWithDeviceCode(
        persist: Bool,
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        let credentials = try await runDeviceCodeFlow(notifyUser: notifyUser)
        if persist {
            try CodexAgentModel.saveCredentials(credentials)
        }
        return credentials
    }

    public static func openAuthorizationURL(_ url: URL) async -> Bool {
        await SubscriptionBrowserLauncher.open(url)
    }

    #if os(macOS)
    public static func startSignIn() async throws -> ChatGPTSubscriptionSignInSession {
        let flow = try authorizationFlow()
        let callbackServer = await ChatGPTSubscriptionCallbackServer(
            state: flow.state
        ).start()
        return ChatGPTSubscriptionSignInSession(
            authorizationURL: flow.url,
            verifier: flow.verifier,
            callbackServer: callbackServer
        )
    }
    #endif


    public static func requestDeviceCode() async throws -> ChatGPTSubscriptionDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID
        ])
        let request = RemoteHTTPStreamingRequest(
            url: deviceCodeURL,
            method: "POST",
            headers: [
                RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
                RemoteHTTPHeader(name: "Accept", value: "application/json")
            ],
            body: body
        )
        let response = try await RemoteTransportCore().sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw ChatGPTSubscriptionAuthError.deviceCodeRequestFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }

        return try decodedDeviceCode(from: response.body)
    }

    private static func decodedDeviceCode(
        from data: Data
    ) throws -> ChatGPTSubscriptionDeviceCode {
        let responseBody: DeviceCodeResponse
        do {
            responseBody = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
        }

        let userCode = responseBody.userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceAuthID = responseBody.deviceAuthID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userCode.isEmpty,
              !deviceAuthID.isEmpty else {
            throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
        }
        return ChatGPTSubscriptionDeviceCode(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            verificationURL: deviceAuthorizationURL,
            pollInterval: max(responseBody.interval?.value ?? 5, 3)
        )
    }

    private static func runDeviceCodeFlow(
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        let deviceCode = try await requestDeviceCode()
        await notifyUser(deviceCode.verificationURL, deviceCode.userCode)
        let authorization = try await pollDeviceAuthorization(deviceCode)
        return try await exchangeAuthorizationCode(
            code: authorization.authorizationCode,
            verifier: authorization.codeVerifier,
            redirectURI: deviceRedirectURI
        )
    }

    private static func pollDeviceAuthorization(
        _ deviceCode: ChatGPTSubscriptionDeviceCode
    ) async throws -> DeviceAuthorizationResponse {
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(
                nanoseconds: UInt64(deviceCode.pollInterval) * 1_000_000_000
            )

            let body = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceCode.deviceAuthID,
                "user_code": deviceCode.userCode
            ])
            let request = RemoteHTTPStreamingRequest(
                url: deviceTokenURL,
                method: "POST",
                headers: [
                    RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
                    RemoteHTTPHeader(name: "Accept", value: "application/json")
                ],
                body: body
            )
            let response = try await RemoteTransportCore().sendRequest(request)

            if (200..<300).contains(response.status) {
                let responseBody: DeviceAuthorizationResponse
                do {
                    responseBody = try JSONDecoder().decode(
                        DeviceAuthorizationResponse.self,
                        from: response.body
                    )
                } catch {
                    throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
                }
                guard !responseBody.authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !responseBody.codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
                }
                return responseBody
            }
            if response.status == 403 || response.status == 404 {
                continue
            }
            throw ChatGPTSubscriptionAuthError.deviceCodePollingFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }
        throw ChatGPTSubscriptionAuthError.deviceCodeTimedOut
    }

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
            try CodexAgentModel.saveCredentials(refreshedCredentials)
        }
        return refreshedCredentials
    }

    private static func authorizationFlow() throws -> (
        verifier: String,
        state: String,
        url: URL
    ) {
        let verifier = try randomBase64URLString(byteCount: 32)
        let challenge = verifier.sha256Base64URL()
        let state = try randomBase64URLString(byteCount: 16)

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

    private static func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ])
    }

    private static func refreshAccessToken(
        refreshToken: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private static func tokenRequest(
        parameters: [String: String]
    ) async throws -> CodexAgentCredentials {
        let request = RemoteHTTPStreamingRequest(
            url: tokenURL,
            method: "POST",
            headers: [
                RemoteHTTPHeader(
                    name: "Content-Type",
                    value: "application/x-www-form-urlencoded"
                )
            ],
            body: formURLEncodedBody(parameters)
        )
        let response = try await RemoteTransportCore().sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw ChatGPTSubscriptionAuthError.tokenExchangeFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }
        let accessToken = tokenResponse.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = tokenResponse.refreshToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              !refreshToken.isEmpty,
              tokenResponse.expiresIn > 0 else {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }

        return CodexAgentCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            accountID: try CodexAgentModel.chatGPTAccountID(from: accessToken)
        )
    }

    private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncoded(key))=\(urlEncoded(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomBase64URLString(byteCount: Int) throws -> String {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ChatGPTSubscriptionAuthError.randomBytesFailed(status)
        }
        #else
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        #endif
        return Data(bytes).base64URLEncodedString()
    }

#if DEBUG
    static func testDecodeDeviceCodeResponse(
        _ data: Data
    ) throws -> ChatGPTSubscriptionDeviceCode {
        try decodedDeviceCode(from: data)
    }
#endif
}

/// Shares a token refresh across all consumers that still hold the same
/// refresh token. The underlying task is intentionally independent of any one
/// caller: cancelling one request must not abort an auth refresh another
/// stream is awaiting. When the final waiter leaves, the task is cancelled so
/// an abandoned refresh cannot outlive its consumers.
actor ChatGPTSubscriptionRefreshCoordinator {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CodexAgentCredentials, Error>]
    }

    private var flights: [String: Flight] = [:]
    /// Internal observability keeps concurrent refresh tests deterministic;
    /// production construction leaves this unset.
    private let onWaiterCountChanged: (@Sendable (Int) -> Void)?

    init(
        onWaiterCountChanged: (@Sendable (Int) -> Void)? = nil
    ) {
        self.onWaiterCountChanged = onWaiterCountChanged
    }

    func refresh(
        credentials: CodexAgentCredentials,
        operation: @escaping @Sendable (CodexAgentCredentials) async throws -> CodexAgentCredentials
    ) async throws -> CodexAgentCredentials {
        try Task.checkCancellation()

        let refreshKey = credentials.refreshToken
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation can race the entry into the continuation.
                // Never install a waiter that has already been cancelled.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                addWaiter(
                    continuation,
                    id: waiterID,
                    credentials: credentials,
                    refreshKey: refreshKey,
                    operation: operation
                )
            }
        } onCancel: {
            Task(name: "ChatGPT authorization background task") {
                await self.cancelWaiter(id: waiterID, for: refreshKey)
            }
        }
    }

    private func addWaiter(
        _ continuation: CheckedContinuation<CodexAgentCredentials, Error>,
        id waiterID: UUID,
        credentials: CodexAgentCredentials,
        refreshKey: String,
        operation: @escaping @Sendable (CodexAgentCredentials) async throws -> CodexAgentCredentials
    ) {
        if var flight = flights[refreshKey] {
            flight.waiters[waiterID] = continuation
            flights[refreshKey] = flight
            onWaiterCountChanged?(flight.waiters.count)
            return
        }

        let flightID = UUID()
        let refreshTask = Task(name: "ChatGPT authorization background task") { [weak self] in
            let result: Result<CodexAgentCredentials, Error>
            do {
                result = .success(try await operation(credentials))
            } catch {
                result = .failure(error)
            }
            await self?.finish(
                id: flightID,
                for: refreshKey,
                with: result
            )
        }
        flights[refreshKey] = Flight(
            id: flightID,
            task: refreshTask,
            waiters: [waiterID: continuation]
        )
        onWaiterCountChanged?(1)
    }

    private func cancelWaiter(id waiterID: UUID, for refreshKey: String) {
        guard var flight = flights[refreshKey],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())

        guard flight.waiters.isEmpty else {
            flights[refreshKey] = flight
            onWaiterCountChanged?(flight.waiters.count)
            return
        }
        flights[refreshKey] = nil
        onWaiterCountChanged?(0)
        flight.task.cancel()
    }

    private func finish(
        id flightID: UUID,
        for refreshKey: String,
        with result: Result<CodexAgentCredentials, Error>
    ) {
        guard let flight = flights[refreshKey], flight.id == flightID else {
            return
        }
        flights[refreshKey] = nil
        onWaiterCountChanged?(0)
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }
}

public struct ChatGPTSubscriptionDeviceCode: Equatable, Sendable {
    public let userCode: String
    public let deviceAuthID: String
    public let verificationURL: URL
    public let pollInterval: Int
}

private struct DeviceCodeResponse: Decodable {
    let userCode: String
    let deviceAuthID: String
    let interval: FlexibleInt?

    private enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case deviceAuthID = "device_auth_id"
        case interval
    }
}

private struct DeviceAuthorizationResponse: Decodable {
    let authorizationCode: String
    let codeVerifier: String

    private enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self) {
            let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmedValue) {
                value = intValue
                return
            }
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an integer or integer string."
            )
        )
    }
}
