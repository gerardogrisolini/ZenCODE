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

public struct AgentSettingsProviderManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case chatEndpoint
    }

    public let id: UUID
    public let name: String
    public let baseURL: String
    public let chatEndpoint: AgentRemoteChatEndpoint

    public init(
        id: UUID,
        name: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) {
        self.id = id
        self.name = AgentRemoteProvider.normalizedName(name)
        self.baseURL = AgentRemoteProvider.normalizedBaseURL(baseURL)
        self.chatEndpoint = chatEndpoint
    }

    public init(provider: AgentRemoteProvider) {
        self.init(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name)
                ?? AgentRemoteProvider.defaultOpenRouterName,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? AgentRemoteProvider.defaultOpenRouterBaseURL,
            chatEndpoint: try container.decodeIfPresent(
                AgentRemoteChatEndpoint.self,
                forKey: .chatEndpoint
            ) ?? .chatCompletions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(chatEndpoint, forKey: .chatEndpoint)
    }

    public var displayTitle: String {
        AgentRemoteProvider.normalizedName(name)
    }

    public func remoteProvider(modelID: String) -> AgentRemoteProvider {
        AgentRemoteProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint
        )
    }
}

struct AgentSettingsSelectionManifest: Codable, Hashable, Sendable {
    let modelID: String?
    let thinking: AgentThinkingSelection?

    init(
        modelID: String?,
        thinking: AgentThinkingSelection?
    ) {
        self.modelID = modelID?.nilIfBlank
        self.thinking = thinking
    }

    var isEmpty: Bool {
        modelID == nil && thinking == nil
    }
}

