//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentSettingsProviderManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case chatEndpoint
        case providerProfileID
        case protocolProfileID
        case authPolicy
    }

    public let id: UUID
    public let name: String
    public let baseURL: String
    public let chatEndpoint: AgentRemoteChatEndpoint
    public let providerProfileID: AgentProviderProfileID
    public let protocolProfileID: AgentProtocolProfileID
    public let authPolicy: AgentProviderAuthPolicy

    public init(
        id: UUID,
        name: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil
    ) {
        self.id = id
        self.name = AgentRemoteProvider.normalizedName(name)
        self.baseURL = AgentRemoteProvider.normalizedBaseURL(baseURL)
        let legacyProfiles = AgentRemoteProvider.legacyProfiles(
            id: id,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint
        )
        self.providerProfileID = providerProfileID ?? legacyProfiles.provider
        let resolvedProtocolProfileID = protocolProfileID ?? legacyProfiles.protocolProfile
        self.protocolProfileID = resolvedProtocolProfileID
        self.authPolicy = authPolicy ?? legacyProfiles.auth
        self.chatEndpoint = resolvedProtocolProfileID.chatEndpoint ?? chatEndpoint
    }

    public init(provider: AgentRemoteProvider) {
        self.init(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint,
            providerProfileID: provider.providerProfileID,
            protocolProfileID: provider.protocolProfileID,
            authPolicy: provider.authPolicy
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
            ) ?? .chatCompletions,
            providerProfileID: try container.decodeIfPresent(AgentProviderProfileID.self, forKey: .providerProfileID),
            protocolProfileID: try container.decodeIfPresent(AgentProtocolProfileID.self, forKey: .protocolProfileID),
            authPolicy: try container.decodeIfPresent(AgentProviderAuthPolicy.self, forKey: .authPolicy)
        )
        guard remoteProvider(modelID: "validation").hasCompatibleProfiles else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolProfileID,
                in: container,
                debugDescription: "The provider, protocol and authentication profiles are incompatible."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(chatEndpoint, forKey: .chatEndpoint)
        try container.encode(providerProfileID, forKey: .providerProfileID)
        try container.encode(protocolProfileID, forKey: .protocolProfileID)
        try container.encode(authPolicy, forKey: .authPolicy)
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
            chatEndpoint: chatEndpoint,
            providerProfileID: providerProfileID,
            protocolProfileID: protocolProfileID,
            authPolicy: authPolicy
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

