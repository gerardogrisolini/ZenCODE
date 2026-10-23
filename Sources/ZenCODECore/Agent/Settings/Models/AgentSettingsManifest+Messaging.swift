//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentTelegramSettingsManifest: Codable, Equatable, Sendable {
    public static let currentRoutingVersion = 2

    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case linkedChatID
        case linkedChatTitle
        case ownerUserID
        case routingVersion
        case routes
    }

    public let enabled: Bool
    public let botToken: String?
    public let linkedChatID: Int64?
    public let linkedChatTitle: String?
    public let ownerUserID: Int64?
    public let routingVersion: Int
    public let routes: [AgentTelegramRouteManifest]

    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        linkedChatID: Int64? = nil,
        linkedChatTitle: String? = nil,
        ownerUserID: Int64? = nil,
        routingVersion: Int = Self.currentRoutingVersion,
        routes: [AgentTelegramRouteManifest] = []
    ) {
        let normalizedToken = botToken?.nilIfBlank
        let normalizedTitle = linkedChatTitle?.nilIfBlank
        let shouldStoreConfiguration = enabled && normalizedToken != nil
        self.enabled = shouldStoreConfiguration
        self.botToken = shouldStoreConfiguration ? normalizedToken : nil
        self.linkedChatID = shouldStoreConfiguration ? linkedChatID : nil
        self.linkedChatTitle = shouldStoreConfiguration ? normalizedTitle : nil
        self.ownerUserID = shouldStoreConfiguration ? ownerUserID : nil
        self.routingVersion = routingVersion
        self.routes = shouldStoreConfiguration ? (Self.validatedRoutes(routes) ?? []) : []
    }

    public init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try header.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            botToken: try header.decodeIfPresent(String.self, forKey: .botToken),
            linkedChatID: try header.decodeIfPresent(Int64.self, forKey: .linkedChatID),
            linkedChatTitle: try header.decodeIfPresent(String.self, forKey: .linkedChatTitle),
            ownerUserID: try header.decodeIfPresent(Int64.self, forKey: .ownerUserID),
            routingVersion: try header.decodeIfPresent(Int.self, forKey: .routingVersion) ?? 0,
            routes: try header.decodeIfPresent([AgentTelegramRouteManifest].self, forKey: .routes) ?? []
        )
    }

    public var isConfigured: Bool { enabled && botToken?.nilIfBlank != nil }
    public var isRoutingSupported: Bool { routingVersion == Self.currentRoutingVersion }

    public var isEnabled: Bool {
        isConfigured && isRoutingSupported && linkedChatID != nil && ownerUserID != nil && !routes.isEmpty
    }

    private static func validatedRoutes(
        _ routes: [AgentTelegramRouteManifest]
    ) -> [AgentTelegramRouteManifest]? {
        var topics = Set<Int?>()
        for route in routes {
            guard route.roomID.nilIfBlank != nil, topics.insert(route.topicID).inserted else { return nil }
        }
        return routes.sorted { ($0.topicID ?? Int.min, $0.roomID) < ($1.topicID ?? Int.min, $1.roomID) }
    }

}

public struct AgentVoiceSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case language
        case macOSVoiceIdentifier
    }

    public static let defaultLanguage = "it"

    /// Telegram voice-message transcription.
    public let enabled: Bool
    public let language: String?
    /// The `AVSpeechSynthesisVoice` identifier chosen in `/setup` > Voice mode
    /// on macOS to read answers aloud; nil selects the best installed voice.
    /// Independent of `enabled`, and inert on Linux.
    public let macOSVoiceIdentifier: String?

    public init(
        enabled: Bool = false,
        language: String? = Self.defaultLanguage,
        macOSVoiceIdentifier: String? = nil
    ) {
        let normalizedLanguage = language?.nilIfBlank
        self.enabled = enabled
        self.language = enabled ? normalizedLanguage : nil
        self.macOSVoiceIdentifier = macOSVoiceIdentifier?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            language: try container.decodeIfPresent(String.self, forKey: .language),
            macOSVoiceIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .macOSVoiceIdentifier
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        if let language {
            try container.encode(language, forKey: .language)
        }
        if let macOSVoiceIdentifier {
            try container.encode(macOSVoiceIdentifier, forKey: .macOSVoiceIdentifier)
        }
    }

    /// Whether Telegram voice-message transcription is on.
    public var isConfigured: Bool {
        enabled
    }

    /// Nothing worth storing: transcription is off and no reading voice is
    /// chosen.
    public var isEmpty: Bool {
        !enabled && macOSVoiceIdentifier == nil
    }
}
