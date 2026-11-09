//
//  ChatGPTSubscriptionAuthService+Credentials.swift
//  ZenCODE
//
//  Credential store of ChatGPT Subscription and JWT/account id decoding.
//

import Foundation
import ToolCore

private enum CodexAgentCredentialError: LocalizedError {
    case missingCredentials
    case invalidCredentials
    case missingAccountID
    case invalidJWT

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "ChatGPT Subscription is not connected. Sign in from Settings, then try again."
        case .invalidCredentials:
            return "ChatGPT Subscription credentials could not be read."
        case .missingAccountID:
            return "ChatGPT Subscription credentials do not contain a ChatGPT account id."
        case .invalidJWT:
            return "ChatGPT Subscription access token could not be decoded."
        }
    }
}

extension ChatGPTSubscriptionAuthService {
    public static func loadCredentials() throws -> CodexAgentCredentials {
        if let environmentToken = ProcessInfo.processInfo.environment["CHATGPT_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            let refreshToken = ProcessInfo.processInfo.environment["CHATGPT_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? environmentToken
            let accountID = ProcessInfo.processInfo.environment["CHATGPT_ACCOUNT_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? (try? chatGPTAccountID(from: environmentToken))
            guard let accountID else {
                throw CodexAgentCredentialError.missingAccountID
            }
            return CodexAgentCredentials(
                accessToken: environmentToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                accountID: accountID
            )
        }

        guard let credentials = AgentSettingsManifestStore.load()?.chatGPTSubscriptionCredentials else {
            throw CodexAgentCredentialError.missingCredentials
        }
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAgentCredentialError.invalidCredentials
        }
        return credentials
    }

    public static func loadValidCredentials() async throws -> CodexAgentCredentials {
        try await loadValidCredentials(persistRefresh: true)
    }

    static func loadValidCredentials(
        persistRefresh: Bool
    ) async throws -> CodexAgentCredentials {
        let credentials = try loadCredentials()
        guard credentials.isExpiredOrNearlyExpired else {
            return credentials
        }
        return try await ChatGPTSubscriptionAuthService.refresh(
            credentials: credentials,
            persist: persistRefresh
        )
    }

    public static func saveCredentials(_ credentials: CodexAgentCredentials) throws {
        try AgentSettingsManifestStore.saveChatGPTSubscriptionCredentials(credentials)
    }

    public static func chatGPTAccountID(from token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw CodexAgentCredentialError.invalidJWT
        }
        guard let payloadData = base64URLDecodedData(String(parts[1])),
              let payload = try JSONDecoder().decode(JSONValue.self, from: payloadData).objectValue,
              let auth = payload["https://api.openai.com/auth"]?.objectValue,
              let accountID = auth["chatgpt_account_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            throw CodexAgentCredentialError.invalidJWT
        }
        return accountID
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
