//
//  RemoteModelCatalogClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public final class RemoteModelCatalogClient {
    let transport: RemoteTransportCore

    /// The model catalog is authoritative at OpenRouter, independently of the
    /// provider endpoint used later for generation.
    public static let openRouterCatalogBaseURL = AgentRemoteProvider.defaultOpenRouterBaseURL

    public init(transport: RemoteTransportCore = RemoteTransportCore()) {
        self.transport = transport
    }

    /// Fetches the authoritative OpenRouter model catalog.
    public func fetchModels(
        apiKey: String?
    ) async throws -> [OpenRouterModelInfo] {
        try await fetchModels(baseURL: Self.openRouterCatalogBaseURL, apiKey: apiKey)
    }

    /// Fetches the model list exposed by the configured OpenAI-compatible
    /// provider. OpenRouter remains a separate metadata catalog.
    public func fetchModels(
        baseURL: String,
        apiKey: String?
    ) async throws -> [OpenRouterModelInfo] {
        let request = try modelsRequest(baseURL: baseURL, apiKey: apiKey)
        let response = try await transport.sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw RemoteModelCatalogClientError.serverError(
                response.status,
                decodedServerMessage(from: response.body)
                    ?? "HTTP \(response.status)"
            )
        }

        let catalog = try decodeJSON(RemoteModelCatalogResponse.self, from: response.body)
        return catalog.data.compactMap { entry in
            modelInfo(from: entry, baseURL: baseURL)
        }
    }

    public func fetchModelMetadata(
        baseURL: String,
        modelID: String,
        apiKey: String?
    ) async throws -> OpenRouterModelMetadata? {
        let normalizedModelID = AgentRemoteProvider.normalizedModelID(modelID).lowercased()
        guard !normalizedModelID.isEmpty else {
            return nil
        }

        return try await fetchModels(
            apiKey: Self.openRouterAPIKey(
                providerBaseURL: baseURL,
                apiKey: apiKey
            )
        ).first {
            AgentRemoteProvider.normalizedModelID($0.id).lowercased() == normalizedModelID
        }.map { model in
            OpenRouterModelMetadata(
                id: model.id,
                contextLength: model.contextLength,
                thinkingSupport: model.thinkingSupport,
                generationParameterOverrides: model.generationParameterOverrides
            )
        }
    }

    static func openRouterAPIKey(
        providerBaseURL: String,
        apiKey: String?
    ) -> String? {
        AgentRemoteProvider.isOpenRouterBaseURL(providerBaseURL) ? apiKey : nil
    }

    func modelsRequest(apiKey: String?) throws -> RemoteHTTPStreamingRequest {
        try modelsRequest(
            baseURL: Self.openRouterCatalogBaseURL,
            apiKey: apiKey
        )
    }

    func modelsRequest(
        baseURL: String,
        apiKey: String?
    ) throws -> RemoteHTTPStreamingRequest {
        RemoteHTTPStreamingRequest(
            url: try endpointURL(
                baseURL: baseURL,
                path: isAnthropicAPIBaseURL(baseURL)
                    ? "models?limit=1000"
                    : "models"
            ),
            method: "GET",
            headers: commonHeaders(baseURL: baseURL, apiKey: apiKey),
            timeout: .seconds(60 * 60)
        )
    }

    static func thinkingSupport(
        fromModelMetadata metadata: [String: Any],
        baseURL _: String,
        modelID _: String
    ) -> ModelThinkingSupport? {
        ModelThinkingSupport.fromModelMetadata(
            metadata.removingSparseIdentifierKeys()
        )
    }
}

public struct OpenRouterModelMetadata: Equatable, Sendable {
    public let id: String
    public let contextLength: Int?
    public let thinkingSupport: ModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?

    public init(
        id: String,
        contextLength: Int?,
        thinkingSupport: ModelThinkingSupport?,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil
    ) {
        self.id = id
        self.contextLength = contextLength
        self.thinkingSupport = thinkingSupport
        self.generationParameterOverrides = generationParameterOverrides
    }
}

public struct OpenRouterModelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?
    public let pricing: OpenRouterModelPricing?
    public let thinkingSupport: ModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let installed: Bool?
    public let loaded: Bool?
    public let serverLoaded: Bool?

    public init(
        id: String,
        name: String,
        contextLength: Int?,
        pricing: OpenRouterModelPricing?,
        thinkingSupport: ModelThinkingSupport? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil,
        installed: Bool? = nil,
        loaded: Bool? = nil,
        serverLoaded: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.pricing = pricing
        self.thinkingSupport = thinkingSupport
        self.generationParameterOverrides = generationParameterOverrides
        self.installed = installed
        self.loaded = loaded
        self.serverLoaded = serverLoaded
    }
}

public struct OpenRouterModelPricing: Equatable, Sendable {
    public let prompt: Double?
    public let completion: Double?

    public init(
        prompt: Double?,
        completion: Double?
    ) {
        self.prompt = prompt
        self.completion = completion
    }
}

public enum RemoteModelCatalogClientError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case serverError(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "RemoteAPI base URL is not valid: \(value)"
        case .invalidResponse:
            return "RemoteAPI returned an invalid response."
        case let .serverError(code, message):
            return "RemoteAPI error \(code): \(message)"
        }
    }
}

extension RemoteModelCatalogClient {
    func modelInfo(
        from entry: RemoteModelCatalogEntry,
        baseURL: String
    ) -> OpenRouterModelInfo? {
        guard let id = stringValue(entry.values, "id")?.nilIfBlank else {
            return nil
        }

        let metadata = modelMetadata(from: entry)
        return OpenRouterModelInfo(
            id: id,
            name: stringValue(entry.values, "name")
                ?? stringValue(entry.values, "display_name")
                ?? id,
            contextLength: contextLength(from: entry.values),
            pricing: pricing(from: entry.values),
            thinkingSupport: Self.thinkingSupport(
                fromModelMetadata: metadata,
                baseURL: baseURL,
                modelID: id
            ),
            generationParameterOverrides: generationParameterOverrides(from: entry.values),
            installed: boolValue(entry.values, "installed"),
            loaded: boolValue(entry.values, "loaded"),
            serverLoaded: boolValue(entry.values, "server_loaded")
        )
    }

    func endpointURL(
        baseURL: String,
        path: String
    ) throws -> URL {
        let normalizedBaseURL = AgentRemoteProvider.normalizedBaseURL(baseURL)
        guard let url = URL(string: "\(normalizedBaseURL)/\(path)") else {
            throw RemoteModelCatalogClientError.invalidURL(baseURL)
        }
        return url
    }

    private func isAnthropicAPIBaseURL(_ baseURL: String) -> Bool {
        URL(string: AgentRemoteProvider.normalizedBaseURL(baseURL))?
            .host?
            .lowercased() == "api.anthropic.com"
    }

    private func commonHeaders(baseURL: String, apiKey: String?) -> [RemoteHTTPHeader] {
        var headers = [RemoteHTTPHeader(name: "Accept", value: "application/json")]
        if isAnthropicAPIBaseURL(baseURL) {
            if let apiKey = apiKey?.nilIfBlank {
                headers.append(RemoteHTTPHeader(name: "x-api-key", value: apiKey))
            }
            headers.append(RemoteHTTPHeader(name: "anthropic-version", value: "2023-06-01"))
        } else {
            headers.append(RemoteHTTPHeader(name: "X-Title", value: "ZenCODE"))
            if let apiKey = apiKey?.nilIfBlank {
                headers.append(RemoteHTTPHeader(name: "Authorization", value: "Bearer \(apiKey)"))
            }
        }
        return headers
    }

    func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RemoteModelCatalogClientError.invalidResponse
        }
    }

    func decodedServerMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        if let envelope = try? JSONDecoder().decode(RemoteModelCatalogErrorEnvelope.self, from: data),
           let message = envelope.error?.message?.nilIfBlank {
            return message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}
