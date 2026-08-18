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

#if os(macOS)
    @Test
    func chatGPTCallbackServerThrowsWhenPortUnavailable() async throws {
        try await withCallbackPortBlocker { didBlock in
            #expect(didBlock)
            do {
                _ = try await ChatGPTSubscriptionCallbackServer(state: "state").start()
                Issue.record("Expected the callback server to fail when the port is taken")
            } catch ChatGPTSubscriptionAuthError.callbackServerUnavailable {
                // Expected: the listener failure must propagate instead of
                // returning a listener-less server whose waitForCode() hangs.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func chatGPTSignInDegradesToManualCodeWhenCallbackPortIsTaken() async throws {
        try await withCallbackPortBlocker { didBlock in
            #expect(didBlock)
            struct PromptError: Error {}

            let session = try await ChatGPTSubscriptionAuthService.startSignIn { _ in
                throw PromptError()
            }

            #expect(!session.isCallbackServerAvailable)

            // Without the fix, waitForCredentials would suspend forever on
            // waitForCode(); with the fix it reaches the manual prompt path.
            do {
                _ = try await session.waitForCredentials(persist: false)
                Issue.record("Expected the manual authorization prompt to be exercised")
            } catch is PromptError {
                // Expected: the degraded path asked for the authorization code.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func chatGPTManualCodeCompletesDegradedSession() async throws {
        try await withCallbackPortBlocker { didBlock in
            #expect(didBlock)
            let session = try await ChatGPTSubscriptionAuthService.startSignIn { _ in "" }
            #expect(!session.isCallbackServerAvailable)

            let components = try #require(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false))
            let state = try #require(components.queryItems?.first(where: { $0.name == "state" })?.value)

            // The manual path must remain able to deliver the authorization code
            // even when the callback listener never started.
            try session.submitAuthorizationInput("authorization-code#\(state)")
        }
    }

    /// Binds the callback port (1455) with a POSIX socket while `body` runs so
    /// sign-in cannot start its own callback server, then releases the port.
    /// The boolean reports whether the port could actually be blocked.
    private func withCallbackPortBlocker(
        _ body: (_ didBlock: Bool) async throws -> Void
    ) async throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            try await body(false)
            return
        }
        defer { close(fileDescriptor) }

        var yes: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // A listener cancelled by a previous test may still be releasing the
        // port; retry the bind briefly so the blocker reliably owns port 1455.
        var bindResult: Int32 = -1
        for _ in 0..<30 {
            bindResult = withUnsafePointer(to: sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: UInt16(1455).bigEndian,
                sin_addr: in_addr(s_addr: INADDR_ANY),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard bindResult == 0 else {
            try await body(false)
            return
        }
        listen(fileDescriptor, 16)

        // Give the blocking listener a moment to become visible so the
        // production listener cannot sneak in before the port is taken.
        try await Task.sleep(nanoseconds: 100_000_000)

        try await body(true)
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
        #expect(queryItems["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
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

    @Test
    func anthropicManualCodeAcceptsCallbackURLWithFragmentParameters() async throws {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        let components = try #require(URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false))
        let state = try #require(components.queryItems?.first(where: { $0.name == "state" })?.value)

        try session.submitAuthorizationInput(
            "https://platform.claude.com/oauth/code/callback#code=authorization-code&state=\(state)"
        )
    }

    @Test
    func anthropicManualCodeRejectsCallbackFragmentWithWrongState() async throws {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()

        do {
            try session.submitAuthorizationInput(
                "https://platform.claude.com/oauth/code/callback#code=authorization-code&state=wrong-state"
            )
            Issue.record("Expected callback fragment with the wrong state to be rejected")
        } catch AnthropicSubscriptionAuthError.stateMismatch {
            // Expected: fragment callbacks retain the same CSRF validation as query callbacks.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func nonPersistingSubscriptionRefreshLeavesSettingsBytesUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-staged-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            let oldChatGPT = CodexAgentCredentials(
            accessToken: "old-chat-access",
            refreshToken: "old-chat-refresh",
            expiresAt: Date(timeIntervalSince1970: 1),
            accountID: "old-account"
        )
        let oldAnthropic = AnthropicSubscriptionCredentials(
            accessToken: "old-claude-access",
            refreshToken: "old-claude-refresh",
            expiresAt: Date(timeIntervalSince1970: 1),
            scope: "old-scope"
        )
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(
                models: [],
                chatGPTSubscriptionCredentials: oldChatGPT,
                anthropicSubscriptionCredentials: oldAnthropic
            )
        )
        let settingsURL = AgentSettingsManifestStore.settingsURL()
        let originalData = try Data(contentsOf: settingsURL)

        let refreshedChatGPT = try await ChatGPTSubscriptionAuthService.refresh(
            credentials: oldChatGPT,
            persist: false,
            tokenRefresher: { _ in
                CodexAgentCredentials(
                    accessToken: "new-chat-access",
                    refreshToken: "new-chat-refresh",
                    expiresAt: Date(timeIntervalSince1970: 4_000),
                    accountID: "new-account"
                )
            }
        )
        let refreshedAnthropic = try await AnthropicSubscriptionAuthService.refresh(
            credentials: oldAnthropic,
            persist: false,
            tokenRefresher: { _ in
                AnthropicSubscriptionCredentials(
                    accessToken: "new-claude-access",
                    refreshToken: "new-claude-refresh",
                    expiresAt: Date(timeIntervalSince1970: 4_000),
                    scope: "new-scope"
                )
            }
        )

        #expect(refreshedChatGPT.accessToken == "new-chat-access")
        #expect(refreshedAnthropic.accessToken == "new-claude-access")
        #expect(try Data(contentsOf: settingsURL) == originalData)
        }
    }
}
