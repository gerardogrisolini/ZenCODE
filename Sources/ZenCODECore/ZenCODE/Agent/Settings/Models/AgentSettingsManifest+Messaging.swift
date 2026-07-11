//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

public struct AgentTelegramSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case linkedChatID
        case linkedChatTitle
    }

    public let enabled: Bool
    public let botToken: String?
    public let linkedChatID: Int64?
    public let linkedChatTitle: String?

    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        linkedChatID: Int64? = nil,
        linkedChatTitle: String? = nil
    ) {
        let normalizedToken = botToken?.nilIfBlank
        let normalizedTitle = linkedChatTitle?.nilIfBlank
        let shouldStoreConfiguration = enabled && normalizedToken != nil
        self.enabled = shouldStoreConfiguration
        self.botToken = shouldStoreConfiguration ? normalizedToken : nil
        self.linkedChatID = shouldStoreConfiguration ? linkedChatID : nil
        self.linkedChatTitle = shouldStoreConfiguration ? normalizedTitle : nil
    }

    public var isConfigured: Bool {
        enabled && botToken?.nilIfBlank != nil
    }

    public var isEnabled: Bool {
        isConfigured && linkedChatID != nil
    }
}

public struct AgentVoiceSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case language
    }

    public static let defaultLanguage = "it"

    public let enabled: Bool
    public let language: String?

    public init(
        enabled: Bool = false,
        language: String? = Self.defaultLanguage
    ) {
        let normalizedLanguage = language?.nilIfBlank
        self.enabled = enabled
        self.language = enabled ? normalizedLanguage : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            language: try container.decodeIfPresent(String.self, forKey: .language)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        if let language {
            try container.encode(language, forKey: .language)
        }
    }

    public var isConfigured: Bool {
        enabled
    }
}

