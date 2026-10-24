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

/// Voice settings. The language of voice transcription and voice mode is not
/// stored here: it follows the response language (`responseLanguage`), else
/// the system language. A `language` key written by earlier versions and a
/// `maximumSpokenCharacters` key written by v2.4.0 (voice mode now always
/// reads an answer whole) are ignored when decoding and dropped on the next
/// save.
public struct AgentVoiceSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case macOSVoiceIdentifier
        case utteranceSilenceSeconds
        case sendMode
        case sendKeyword
    }

    /// How voice mode decides that an utterance is complete and sends it.
    public enum SendMode: String, Codable, Sendable {
        /// After the silence of `utteranceSilenceSeconds`.
        case pause
        /// When the utterance ends with `sendKeyword`; silence never sends.
        case keyword
    }

    /// Telegram voice-message transcription.
    public let enabled: Bool
    /// The `AVSpeechSynthesisVoice` identifier chosen in `/setup` > Voice mode
    /// on macOS to read answers aloud; nil selects the best installed voice.
    /// Independent of `enabled`, and inert on Linux.
    public let macOSVoiceIdentifier: String?
    /// Whole seconds of silence that end a spoken utterance in voice mode,
    /// chosen in `/setup` > Voice mode; nil applies the built-in default.
    public let utteranceSilenceSeconds: Int?
    /// How an utterance is sent, chosen in `/setup` > Voice mode; nil means
    /// `.pause`. `.keyword` applies only while `sendKeyword` is set.
    public let sendMode: SendMode?
    /// The spoken word that ends and sends an utterance in `.keyword` mode,
    /// kept when the mode goes back to `.pause`.
    public let sendKeyword: String?

    public init(
        enabled: Bool = false,
        macOSVoiceIdentifier: String? = nil,
        utteranceSilenceSeconds: Int? = nil,
        sendMode: SendMode? = nil,
        sendKeyword: String? = nil
    ) {
        self.enabled = enabled
        self.macOSVoiceIdentifier = macOSVoiceIdentifier?.nilIfBlank
        self.utteranceSilenceSeconds = utteranceSilenceSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.sendMode = sendMode
        self.sendKeyword = sendKeyword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            macOSVoiceIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .macOSVoiceIdentifier
            ),
            utteranceSilenceSeconds: try container.decodeIfPresent(
                Int.self,
                forKey: .utteranceSilenceSeconds
            ),
            // An unknown mode written by a newer version falls back to pause.
            sendMode: try container.decodeIfPresent(String.self, forKey: .sendMode)
                .flatMap(SendMode.init(rawValue:)),
            sendKeyword: try container.decodeIfPresent(String.self, forKey: .sendKeyword)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        if let macOSVoiceIdentifier {
            try container.encode(macOSVoiceIdentifier, forKey: .macOSVoiceIdentifier)
        }
        if let utteranceSilenceSeconds {
            try container.encode(utteranceSilenceSeconds, forKey: .utteranceSilenceSeconds)
        }
        if let sendMode {
            try container.encode(sendMode, forKey: .sendMode)
        }
        if let sendKeyword {
            try container.encode(sendKeyword, forKey: .sendKeyword)
        }
    }

    /// Whether Telegram voice-message transcription is on.
    public var isConfigured: Bool {
        enabled
    }

    /// Nothing worth storing: transcription is off and no reading voice or
    /// voice mode option is chosen.
    public var isEmpty: Bool {
        !enabled
            && macOSVoiceIdentifier == nil
            && utteranceSilenceSeconds == nil
            && sendMode == nil
            && sendKeyword == nil
    }
}
