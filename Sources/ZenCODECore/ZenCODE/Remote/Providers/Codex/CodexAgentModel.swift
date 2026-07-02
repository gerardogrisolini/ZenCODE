//
//  CodexAgentModel.swift
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

private enum CodexAgentCredentialError: LocalizedError {
    case missingCredentials
    case invalidCredentials
    case missingAccessToken
    case missingRefreshToken
    case missingAccountID
    case invalidJWT

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "ChatGPT Subscription is not connected. Sign in from Settings, then try again."
        case .invalidCredentials:
            return "ChatGPT Subscription credentials could not be read."
        case .missingAccessToken:
            return "ChatGPT Subscription credentials do not contain an access token."
        case .missingRefreshToken:
            return "ChatGPT Subscription credentials do not contain a refresh token."
        case .missingAccountID:
            return "ChatGPT Subscription credentials do not contain a ChatGPT account id."
        case .invalidJWT:
            return "ChatGPT Subscription access token could not be decoded."
        }
    }
}

public nonisolated enum CodexAgentModel {
    public struct ModelOption: Identifiable, Hashable, Sendable {
        public let modelID: String
        public let title: String
        public let subtitle: String
        public let contextWindowTokenLimit: Int?

        public var id: String { modelID }
        public var llmID: String {
            CodexAgentModel.selectionID(forModelID: modelID)
        }
    }

    public static let llmID = "chatgpt"
    public static let defaultModelID = "gpt-5.5"
    public static var defaultLLMID: String {
        selectionID(forModelID: defaultModelID)
    }
    public static let modelID = defaultModelID
    public static let legacyContextWindowTokenLimit = 272_000
    public static let contextWindowTokenLimit = 1_000_000
    public static let displayTitle = "ChatGPT Subscription"
    public static let displaySubtitle = "ChatGPT Plus/Pro"
    public static let availableModels: [ModelOption] = [
        ModelOption(
            modelID: "gpt-5.5",
            title: "GPT-5.5",
            subtitle: "Frontier model",
            contextWindowTokenLimit: contextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.4",
            title: "GPT-5.4",
            subtitle: "Everyday coding",
            contextWindowTokenLimit: legacyContextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.4-mini",
            title: "GPT-5.4 Mini",
            subtitle: "Fast small model",
            contextWindowTokenLimit: legacyContextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.3-codex",
            title: "GPT-5.3 Codex",
            subtitle: "Coding-optimized",
            contextWindowTokenLimit: legacyContextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.3-codex-spark",
            title: "GPT-5.3 Codex Spark",
            subtitle: "Ultra-fast coding",
            contextWindowTokenLimit: 128_000
        )
    ]
    public static let thinkingSupport = MLXModelThinkingSupport.effort(
        levels: [.low, .medium, .high, .xhigh]
    )

    public static func isCodexLLMID(_ value: String?) -> Bool {
        guard let normalizedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedValue.isEmpty else {
            return false
        }

        return isSubscriptionPrefix(normalizedValue, prefix: llmID)
    }

    public static func canonicalLLMID(_ value: String?) -> String {
        guard isCodexLLMID(value) else {
            return ""
        }
        return selectionID(forModelID: modelID(fromLLMID: value))
    }

    public static func selectionID(forModelID modelID: String) -> String {
        "\(llmID):\(normalizedModelID(modelID))"
    }

    public static func modelID(fromLLMID value: String?) -> String {
        guard let value else {
            return defaultModelID
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return defaultModelID
        }

        let lowercasedValue = trimmedValue.lowercased()
        if lowercasedValue == llmID {
            return defaultModelID
        }
        for separator in [":", "/"] where lowercasedValue.hasPrefix(llmID + separator) {
            let rawModelID = String(trimmedValue.dropFirst(llmID.count + separator.count))
            return normalizedModelID(rawModelID)
        }
        return normalizedModelID(trimmedValue)
    }

    public static func option(forLLMID value: String?) -> ModelOption {
        option(forModelID: modelID(fromLLMID: value))
    }

    public static func option(forModelID modelID: String) -> ModelOption {
        let normalizedModelID = normalizedModelID(modelID)
        if let option = availableModels.first(where: { $0.modelID == normalizedModelID }) {
            return option
        }
        return ModelOption(
            modelID: normalizedModelID,
            title: normalizedModelID,
            subtitle: displaySubtitle,
            contextWindowTokenLimit: nil
        )
    }

    public static func selectionTitle(forLLMID value: String?) -> String {
        "\(displayTitle) · \(option(forLLMID: value).title)"
    }

    public static func contextWindowTokenLimit(forLLMID value: String?) -> Int? {
        option(forLLMID: value).contextWindowTokenLimit
    }

    private static func normalizedModelID(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultModelID : trimmedValue
    }

    private static func isSubscriptionPrefix(_ value: String, prefix: String) -> Bool {
        value == prefix
            || value.hasPrefix(prefix + ":")
            || value.hasPrefix(prefix + "/")
    }

    public static var isAvailable: Bool {
        isAuthenticated
    }

    public static var isAuthenticated: Bool {
#if os(macOS)
        (try? loadCredentials()) != nil
#else
        false
#endif
    }

    public static var isReady: Bool {
        isAuthenticated
    }

#if os(macOS)
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
        let credentials = try loadCredentials()
        guard credentials.isExpiredOrNearlyExpired else {
            return credentials
        }
        return try await ChatGPTSubscriptionAuthService.refresh(credentials: credentials)
    }

    public static func saveCredentials(_ credentials: CodexAgentCredentials) throws {
        try AgentSettingsManifestStore.saveChatGPTSubscriptionCredentials(credentials)
    }

    public static func removeCredentials() {
        try? AgentSettingsManifestStore.saveChatGPTSubscriptionCredentials(nil)
    }

    public static func chatGPTAccountID(from token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw CodexAgentCredentialError.invalidJWT
        }
        guard let payloadData = base64URLDecodedData(String(parts[1])),
              let payload = try JSONDecoder().decode(JSONValue.self, from: payloadData).mlxObjectValue,
              let auth = payload["https://api.openai.com/auth"]?.mlxObjectValue,
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

#endif
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
