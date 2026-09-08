import Foundation
import Testing
@testable import ZenCODECore

@Suite("Anthropic subscription refresh recovery")
struct AnthropicSubscriptionRefreshRecoveryTests {
    private static let credentials = AnthropicSubscriptionCredentials(
        accessToken: "test-access",
        refreshToken: "test-refresh",
        expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
    )

    @Test
    func rejectedRefreshStartsOneNewLogin() async throws {
        let requests = RequestCounter()
        var loginCount = 0
        let result = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
            loadCredentials: {
                try await AnthropicSubscriptionAuthService.tokenRequest(
                    parameters: ["grant_type": "refresh_token"],
                    sendRequest: { request in
                        await requests.increment()
                        #expect(request.method == "POST")
                        return (400, Data(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#.utf8))
                    }
                )
            },
            signIn: {
                loginCount += 1
                return Self.credentials
            }
        )
        #expect(result == Self.credentials)
        #expect(loginCount == 1)
        #expect(await requests.count == 1)
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_client"}"#),
        (400, #"{"error_description":"invalid_grant"}"#),
        (400, #"{"error":{"type":"invalid_grant"}}"#),
        (400, #"{"error":"INVALID_GRANT"}"#),
        (400, "invalid_grant"),
        (400, ""),
        (401, #"{"error":"invalid_grant"}"#),
        (403, #"{"error":"invalid_grant"}"#),
        (429, #"{"error":"invalid_grant"}"#),
        (500, #"{"error":"invalid_grant"}"#),
        (503, #"{"error":"invalid_grant"}"#)
    ])
    func otherHTTPFailuresRemainVisible(status: Int, body: String) async {
        let requests = RequestCounter()
        do {
            _ = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
                loadCredentials: {
                    try await AnthropicSubscriptionAuthService.tokenRequest(
                        parameters: ["grant_type": "refresh_token"],
                        sendRequest: { _ in
                            await requests.increment()
                            return (status, Data(body.utf8))
                        }
                    )
                },
                signIn: {
                    Issue.record("Unexpected login for HTTP/structural failure")
                    return Self.credentials
                }
            )
            Issue.record("Expected token exchange failure")
        } catch let AnthropicSubscriptionAuthError.tokenExchangeFailed(actualStatus, actualBody) {
            #expect(actualStatus == status)
            #expect(actualBody == body)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await requests.count == 2) // Existing endpoint fallback is retained.
    }

    @Test
    func codeExchangeInvalidGrantDoesNotBecomeRefreshRejection() async {
        do {
            _ = try await AnthropicSubscriptionAuthService.tokenRequest(
                parameters: ["grant_type": "authorization_code"],
                sendRequest: { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
            )
            Issue.record("Expected code exchange failure")
        } catch AnthropicSubscriptionAuthError.tokenExchangeFailed(status: 400, body: _) {
            // A bad authorization code must remain visible, not restart login.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [false, true])
    func transportAndCancellationErrorsDoNotStartLogin(cancelled: Bool) async {
        let requests = RequestCounter()
        do {
            _ = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
                loadCredentials: {
                    try await AnthropicSubscriptionAuthService.tokenRequest(
                        parameters: ["grant_type": "refresh_token"],
                        sendRequest: { _ in
                            await requests.increment()
                            if cancelled { throw CancellationError() }
                            throw URLError(.notConnectedToInternet)
                        }
                    )
                },
                signIn: {
                    Issue.record("Unexpected login after transport error/cancellation")
                    return Self.credentials
                }
            )
            Issue.record("Expected error")
        } catch is CancellationError {
            #expect(cancelled)
        } catch let error as URLError {
            #expect(!cancelled)
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await requests.count == 1)
    }

    @Test(arguments: [
        "not JSON",
        #"{"access_token":"","refresh_token":"r","expires_in":3600}"#,
        #"{"access_token":"a","expires_in":3600}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":0}"#
    ])
    func malformedSuccessDoesNotStartLogin(body: String) async {
        do {
            _ = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
                loadCredentials: {
                    try await AnthropicSubscriptionAuthService.tokenRequest(
                        parameters: ["grant_type": "refresh_token"],
                        sendRequest: { _ in (200, Data(body.utf8)) }
                    )
                },
                signIn: {
                    Issue.record("Unexpected login for invalid token response")
                    return Self.credentials
                }
            )
            Issue.record("Expected structural error")
        } catch is DecodingError {
            #expect(body == "not JSON")
        } catch AnthropicSubscriptionAuthError.missingAccessToken {
            #expect(body.contains(#""access_token":"""#))
        } catch AnthropicSubscriptionAuthError.missingRefreshToken {
            #expect(!body.contains("refresh_token"))
        } catch AnthropicSubscriptionAuthError.invalidTokenResponse {
            #expect(body.contains(#""expires_in":0"#))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func validCredentialsSkipLogin() async throws {
        let result = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
            loadCredentials: { Self.credentials },
            signIn: {
                Issue.record("Unexpected login for valid credentials")
                return Self.credentials
            }
        )
        #expect(result == Self.credentials)
    }

    @Test(arguments: [AnthropicSubscriptionAuthError.missingCredentials, .invalidCredentials])
    func existingCredentialRecoveryIsRetained(error: AnthropicSubscriptionAuthError) async throws {
        var loginCount = 0
        let result = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
            loadCredentials: { throw error },
            signIn: {
                loginCount += 1
                return Self.credentials
            }
        )
        #expect(result == Self.credentials)
        #expect(loginCount == 1)
    }

    @Test
    func loginCancellationPropagatesWithoutRetry() async {
        var loginCount = 0
        do {
            _ = try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
                loadCredentials: { throw AnthropicSubscriptionAuthError.refreshTokenRejected },
                signIn: {
                    loginCount += 1
                    throw AnthropicSubscriptionAuthError.callbackCancelled
                }
            )
            Issue.record("Expected login cancellation")
        } catch AnthropicSubscriptionAuthError.callbackCancelled {
            #expect(loginCount == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func cancellationBeforeRecoveryDoesNotOpenLogin() async {
        let task = Task(name: "Cancelled Anthropic setup recovery test") {
            try await ZenCODESetupRunner.ensureAnthropicSubscriptionCredentials(
                loadCredentials: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw AnthropicSubscriptionAuthError.refreshTokenRejected
                },
                signIn: {
                    Issue.record("Unexpected login in cancelled task")
                    return Self.credentials
                }
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Cancellation wins even when the loader reports rejected credentials.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func successfulRefreshRetainsFallbackRefreshToken() async throws {
        let result = try await AnthropicSubscriptionAuthService.tokenRequest(
            parameters: ["grant_type": "refresh_token"],
            fallbackRefreshToken: "old-refresh",
            sendRequest: { _ in (200, Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)) }
        )
        #expect(result.accessToken == "new-access")
        #expect(result.refreshToken == "old-refresh")
        #expect(!result.isExpiredOrNearlyExpired)
    }
}

private actor RequestCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
