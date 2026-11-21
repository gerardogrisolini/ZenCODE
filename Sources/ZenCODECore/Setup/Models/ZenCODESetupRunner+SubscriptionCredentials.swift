//
//  ZenCODESetupRunner+SubscriptionCredentials.swift
//  ZenCODE
//
//  Detection of the ChatGPT and Claude subscription providers and the sign-in
//  that provides their credentials during setup.
//

import Foundation
import ZenCODERuntime

extension ZenCODESetupRunner {
    static func isChatGPTSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.chatGPTSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.chatGPTSubscriptionBaseURL
    }

    static func isAnthropicSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.anthropicSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.anthropicSubscriptionBaseURL
    }

    static func ensureChatGPTSubscriptionCredentials() async throws -> CodexAgentCredentials {
        do {
            return try await ChatGPTSubscriptionAuthService.loadValidCredentials(
                persistRefresh: false
            )
        } catch is CancellationError {
            // A cooperative cancellation must not be mistaken for "not signed
            // in"; propagate it so the surrounding setup task unwinds.
            throw CancellationError()
        } catch {
            AgentOutput.standardError.writeString(
                "ChatGPT Subscription is not connected. Opening ChatGPT login in the browser.\n"
            )
        }

        #if os(macOS)
        let session = try await ChatGPTSubscriptionAuthService.startSignIn(
            promptAuthorizationInput: { label in
                try promptSecret(label, allowEmpty: false)
            }
        )
        if session.isCallbackServerAvailable {
            AgentOutput.standardError.writeString(
                """
                Complete ChatGPT login in the browser.

                If the browser does not open, open this URL:
                \(session.authorizationURL.absoluteString)

                Waiting for sign-in...

                """
            )
        } else {
            AgentOutput.standardError.writeString(
                """
                The local ChatGPT sign-in callback server could not start (the
                port may already be in use); the browser will not redirect back
                automatically.

                After completing the login, paste the authorization code below.

                If the browser does not open, open this URL:
                \(session.authorizationURL.absoluteString)

                """
            )
        }
        let didOpen = await ChatGPTSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        if !didOpen {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }
        let credentials = try await session.waitForCredentials(persist: false)
        #else
        let credentials = try await ChatGPTSubscriptionAuthService.signInWithDeviceCode(
            persist: false
        ) {
            url,
            code in
            AgentOutput.standardError.writeString(
                """
                Complete ChatGPT login at:
                \(url.absoluteString)

                Enter this code: \(code)

                Waiting for sign-in...

                """
            )
            _ = await ChatGPTSubscriptionAuthService.openAuthorizationURL(url)
        }
        #endif
        AgentOutput.standardError.writeString("ChatGPT Subscription connected.\n")
        return credentials
    }

    static func ensureAnthropicSubscriptionCredentials(
        loadCredentials: () async throws -> AnthropicSubscriptionCredentials = {
            try await AnthropicSubscriptionAuthService.loadValidCredentials(persistRefresh: false)
        },
        signIn: () async throws -> AnthropicSubscriptionCredentials = {
            try await signInAnthropicSubscription()
        }
    ) async throws -> AnthropicSubscriptionCredentials {
        try Task.checkCancellation()
        do {
            return try await loadCredentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AnthropicSubscriptionAuthError {
            // Missing credentials and explicitly rejected refresh grants need
            // a new sign-in; structural or transport errors surface unchanged.
            switch error {
            case .missingCredentials, .invalidCredentials, .refreshTokenRejected:
                try Task.checkCancellation()
                AgentOutput.standardError.writeString(
                    "Claude Subscription is not connected. Opening Claude login in the browser.\n"
                )
            default:
                throw error
            }
        } catch {
            throw error
        }

        try Task.checkCancellation()
        return try await signIn()
    }

    private static func signInAnthropicSubscription() async throws -> AnthropicSubscriptionCredentials {
        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        AgentOutput.standardError.writeString(
            """
            Complete Claude login in the browser.

            If the browser does not open automatically, open this URL:
            \(session.authorizationURL.absoluteString)

            """
        )
        let didOpen = await AnthropicSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        if !didOpen {
            AgentOutput.standardError.writeString(
                "No browser launcher was found; open the URL above manually.\n"
            )
        }

        let authorizationInput = try promptSecret(
            "Authorization code",
            allowEmpty: false
        )
        try session.submitAuthorizationInput(authorizationInput)

        let credentials = try await session.waitForCredentials(persist: false)
        AgentOutput.standardError.writeString("Claude Subscription connected.\n")
        return credentials
    }
}
