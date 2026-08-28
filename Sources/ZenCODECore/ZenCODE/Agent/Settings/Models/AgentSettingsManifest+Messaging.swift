//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentTelegramSettingsManifest: Codable, Equatable, Sendable {
    public static let currentRoutingVersion = 1

    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        // Legacy single-private-chat binding. Kept indefinitely for compatible
        // readers; new runtimes use `routes` as the authorization authority.
        case linkedChatID
        case linkedChatTitle
        case routingVersion
        case groupsEnabled
        case routes
    }

    public let enabled: Bool
    public let botToken: String?
    public let linkedChatID: Int64?
    public let linkedChatTitle: String?
    public let routingVersion: Int
    public let groupsEnabled: Bool
    public let routes: [AgentTelegramRouteManifest]

    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        linkedChatID: Int64? = nil,
        linkedChatTitle: String? = nil,
        routingVersion: Int = Self.currentRoutingVersion,
        groupsEnabled: Bool = false,
        routes: [AgentTelegramRouteManifest] = []
    ) {
        let normalizedToken = botToken?.nilIfBlank
        let normalizedTitle = linkedChatTitle?.nilIfBlank
        let shouldStoreConfiguration = enabled && normalizedToken != nil
        self.enabled = shouldStoreConfiguration
        self.botToken = shouldStoreConfiguration ? normalizedToken : nil
        self.linkedChatID = shouldStoreConfiguration ? linkedChatID : nil
        self.linkedChatTitle = shouldStoreConfiguration ? normalizedTitle : nil
        self.routingVersion = max(1, routingVersion)
        self.groupsEnabled = shouldStoreConfiguration && groupsEnabled
        self.routes = shouldStoreConfiguration ? routes : []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            botToken: try container.decodeIfPresent(String.self, forKey: .botToken),
            linkedChatID: try container.decodeIfPresent(Int64.self, forKey: .linkedChatID),
            linkedChatTitle: try container.decodeIfPresent(String.self, forKey: .linkedChatTitle),
            routingVersion: try container.decodeIfPresent(Int.self, forKey: .routingVersion)
                ?? Self.currentRoutingVersion,
            groupsEnabled: try container.decodeIfPresent(Bool.self, forKey: .groupsEnabled) ?? false,
            routes: try container.decodeIfPresent([AgentTelegramRouteManifest].self, forKey: .routes) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(botToken, forKey: .botToken)
        try container.encodeIfPresent(linkedChatID, forKey: .linkedChatID)
        try container.encodeIfPresent(linkedChatTitle, forKey: .linkedChatTitle)
        try container.encode(routingVersion, forKey: .routingVersion)
        try container.encode(groupsEnabled, forKey: .groupsEnabled)
        try container.encode(routes, forKey: .routes)
    }

    public var isConfigured: Bool {
        enabled && botToken?.nilIfBlank != nil
    }

    public var isRoutingSupported: Bool {
        routingVersion == Self.currentRoutingVersion
    }

    public var isEnabled: Bool {
        isConfigured && isRoutingSupported && (linkedChatID != nil || !routes.isEmpty)
    }

    /// Legacy manifests have no user identity, so they cannot safely authorize a
    /// group and are not silently widened into an ACL. The TUI may claim this
    /// private binding for the first sender and persist an explicit route.
    public var requiresLegacyPrivateRouteClaim: Bool {
        isConfigured && routes.isEmpty && linkedChatID != nil
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
