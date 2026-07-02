//
//  RemoteModelCatalogClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class RemoteModelCatalogClient {
    public static let defaultRequestTimeout: TimeInterval = 60 * 60
    public static let defaultResourceTimeout: TimeInterval = 60 * 60 * 8

    let session: URLSession
    let huggingFaceBaseURL: String
    let enrichesHuggingFaceMetadata: Bool

    public init(
        urlSession: URLSession? = nil,
        huggingFaceBaseURL: String = "https://huggingface.co",
        enrichesHuggingFaceMetadata: Bool = true
    ) {
        self.huggingFaceBaseURL = AgentRemoteProvider.normalizedBaseURL(huggingFaceBaseURL)
        self.enrichesHuggingFaceMetadata = enrichesHuggingFaceMetadata
        if let urlSession {
            self.session = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.defaultRequestTimeout
            configuration.timeoutIntervalForResource = Self.defaultResourceTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetchModels(
        baseURL: String,
        apiKey: String?
    ) async throws -> [OpenRouterModelInfo] {
        var request = try URLRequest(url: endpointURL(baseURL: baseURL, path: "models"))
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, apiKey: apiKey)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let catalog = try decodeJSON(RemoteModelCatalogResponse.self, from: data)
        let models = catalog.data.compactMap { entry in
            modelInfo(from: entry, baseURL: baseURL)
        }
        return try await enrichModelsIfNeeded(models, baseURL: baseURL)
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

        return try await fetchModels(baseURL: baseURL, apiKey: apiKey).first {
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

    static func thinkingSupport(
        fromModelMetadata metadata: [String: Any],
        baseURL _: String,
        modelID _: String
    ) -> MLXModelThinkingSupport? {
        MLXModelThinkingSupport.fromModelMetadata(
            metadata.removingSparseIdentifierKeys()
        )
    }
}

public struct OpenRouterModelMetadata: Equatable, Sendable {
    public let id: String
    public let contextLength: Int?
    public let thinkingSupport: MLXModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?

    public init(
        id: String,
        contextLength: Int?,
        thinkingSupport: MLXModelThinkingSupport?,
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
    public let thinkingSupport: MLXModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let installed: Bool?
    public let loaded: Bool?
    public let serverLoaded: Bool?

    public init(
        id: String,
        name: String,
        contextLength: Int?,
        pricing: OpenRouterModelPricing?,
        thinkingSupport: MLXModelThinkingSupport? = nil,
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

    func enrichModelsIfNeeded(
        _ models: [OpenRouterModelInfo],
        baseURL: String
    ) async throws -> [OpenRouterModelInfo] {
        guard shouldEnrichWithHuggingFace(baseURL: baseURL) else {
            return models
        }

        var enrichedModels: [OpenRouterModelInfo] = []
        enrichedModels.reserveCapacity(models.count)
        var metadataByRepositoryID: [String: HuggingFaceModelMetadata] = [:]
        for model in models {
            guard model.needsHuggingFaceMetadataEnrichment,
                  let repositoryID = Self.huggingFaceRepositoryID(from: model.id) else {
                enrichedModels.append(model)
                continue
            }

            let cacheKey = repositoryID.lowercased()
            let metadata: HuggingFaceModelMetadata?
            if let cachedMetadata = metadataByRepositoryID[cacheKey] {
                metadata = cachedMetadata
            } else {
                metadata = try await fetchHuggingFaceModelMetadata(repositoryID: repositoryID)
                if let metadata {
                    metadataByRepositoryID[cacheKey] = metadata
                }
            }
            enrichedModels.append(model.enriched(with: metadata))
        }
        return enrichedModels
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

    func applyCommonHeaders(
        to request: inout URLRequest,
        apiKey: String?
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = apiKey?.nilIfBlank {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("ZenCODE", forHTTPHeaderField: "X-Title")
    }

    func validateHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelCatalogClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw RemoteModelCatalogClientError.serverError(
                httpResponse.statusCode,
                decodedServerMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
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
