//
//  AgentSettingsManifestStoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 13/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct SubscriptionAuthFlowTests {
#if os(macOS)
    @Test
    func chatGPTSignInUsesBrowserOAuthCallback() async throws {
        let session = try await ChatGPTSubscriptionAuthService.startSignIn()
        defer {
            session.cancel()
        }

        let components = try #require(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/oauth/authorize")
        #expect(queryItems["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["codex_cli_simplified_flow"] == "true")
        #expect(queryItems["state"] != nil)
    }
#endif

    @Test
    func chatGPTDeviceCodeResponseAcceptsStringInterval() throws {
        let data = Data(
            """
            {
              "device_auth_id": "deviceauth_test",
              "user_code": "X7T6-6XKDP",
              "interval": "5",
              "expires_at": "2026-06-20T08:20:30.679277+00:00"
            }
            """.utf8
        )

        let deviceCode = try ChatGPTSubscriptionAuthService.testDecodeDeviceCodeResponse(data)

        #expect(deviceCode.deviceAuthID == "deviceauth_test")
        #expect(deviceCode.userCode == "X7T6-6XKDP")
        #expect(deviceCode.verificationURL.absoluteString == "https://auth.openai.com/codex/device")
        #expect(deviceCode.pollInterval == 5)
    }

    @Test
    func anthropicSignInUsesHostedCodeCallback() async throws {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        let components = try #require(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "claude.ai")
        #expect(components.path == "/oauth/authorize")
        #expect(queryItems["redirect_uri"] == "https://console.anthropic.com/oauth/code/callback")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["state"] != nil)
    }

    @Test
    func anthropicManualCodeRequiresState() async throws {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()

        do {
            try session.submitAuthorizationInput("authorization-code-only")
            Issue.record("Expected bare authorization code to be rejected")
        } catch AnthropicSubscriptionAuthError.missingOAuthState {
            // Expected: hosted callback paste should include the state suffix.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func anthropicManualCodeAcceptsCodeStatePair() async throws {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        let components = try #require(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false))
        let state = try #require(components.queryItems?.first(where: { $0.name == "state" })?.value)

        try session.submitAuthorizationInput("authorization-code#\(state)")
    }
}
