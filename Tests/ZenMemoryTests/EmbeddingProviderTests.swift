//
//  EmbeddingProviderTests.swift
//  ZenMemoryTests
//

import Foundation
@testable import ZenMemory
import Testing

@Test
func endpointOnlyEmbeddingRequestOmitsModelAndUsesStableEndpointIdentity() throws {
    let endpoint = try #require(URL(string: "https://embeddings.example.test/v1/embeddings"))
    let provider = OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    let equivalentProvider = OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    let differentEndpoint = try #require(URL(string: "https://other.example.test/v1/embeddings"))
    let differentProvider = OpenAICompatibleEmbeddingProvider(endpoint: differentEndpoint)

    let request = try provider.request(for: "hello endpoint-only embeddings")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(request.httpMethod == "POST")
    #expect(request.url == endpoint)
    #expect(json["input"] as? String == "hello endpoint-only embeddings")
    #expect(json["model"] == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(provider.requestModel == nil)
    #expect(provider.modelID == equivalentProvider.modelID)
    #expect(provider.modelID != differentProvider.modelID)
}

@Test
func explicitCompatibilityModelRemainsEncodedWhenProvided() throws {
    let endpoint = try #require(URL(string: "https://embeddings.example.test/v1/embeddings"))
    let provider = OpenAICompatibleEmbeddingProvider(
        endpoint: endpoint,
        model: "server-selected-model"
    )

    let request = try provider.request(for: "hello")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(provider.modelID == "server-selected-model")
    #expect(json["model"] as? String == "server-selected-model")
}

@Test
func modelAndAPIKeyAreSentInRequestWhenProvided() throws {
    let endpoint = try #require(URL(string: "https://openrouter.ai/api/v1/embeddings"))
    let provider = OpenAICompatibleEmbeddingProvider(
        endpoint: endpoint,
        model: "qwen/qwen3-embedding-8b",
        apiKey: "sk-openrouter-test"
    )

    let request = try provider.request(for: "hello")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(request.httpMethod == "POST")
    #expect(request.url == endpoint)
    #expect(json["model"] as? String == "qwen/qwen3-embedding-8b")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openrouter-test")
    #expect(provider.requestModel == "qwen/qwen3-embedding-8b")
    #expect(provider.modelID == "qwen/qwen3-embedding-8b")
}
