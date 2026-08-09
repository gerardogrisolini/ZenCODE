//
//  EmbeddingProviderTests.swift
//  ZenCODECoreTests (memory engine)
//

import Foundation
@testable import ZenCODECore
import Testing

@Test
func endpointOnlyEmbeddingRequestOmitsModelAndUsesStableEndpointIdentity() throws {
    let endpoint = try #require(URL(string: "https://embeddings.example.test/v1/embeddings"))
    let provider = OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    let equivalentProvider = OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    let differentEndpoint = try #require(URL(string: "https://other.example.test/v1/embeddings"))
    let differentProvider = OpenAICompatibleEmbeddingProvider(endpoint: differentEndpoint)

    let request = try provider.streamingRequest(for: "hello endpoint-only embeddings")
    let body = try #require(request.body)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let headers = RemoteHTTPHeaders(request.headers)

    #expect(request.method == "POST")
    #expect(request.url == endpoint)
    #expect(json["input"] as? String == "hello endpoint-only embeddings")
    #expect(json["model"] == nil)
    #expect(headers.firstValue(for: "Authorization") == nil)
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

    let request = try provider.streamingRequest(for: "hello")
    let body = try #require(request.body)
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

    let request = try provider.streamingRequest(for: "hello")
    let body = try #require(request.body)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let headers = RemoteHTTPHeaders(request.headers)

    #expect(request.method == "POST")
    #expect(request.url == endpoint)
    #expect(json["model"] as? String == "qwen/qwen3-embedding-8b")
    #expect(headers.firstValue(for: "Authorization") == "Bearer sk-openrouter-test")
    #expect(provider.requestModel == "qwen/qwen3-embedding-8b")
    #expect(provider.modelID == "qwen/qwen3-embedding-8b")
}

// MARK: - SwiftNIO transport round-trip

/// Proves that `embed()` drives an actual POST through the shared SwiftNIO
/// transport (``RemoteTransportCore``) to the configured path and decodes the
/// response — not just that the in-memory request has the right shape.
///
/// The transport is exercised against a local loopback NIO server
/// (``RemoteNIOStreamingFixture``), so this test never leaves the process: it
/// validates the request/response contract (method, path, headers, body,
/// decoding) that `streamingRequest(for:)`-only tests leave unexercised.
@Test
func embedPerformsPOSTThroughSharedSwiftNIOTransport() async throws {
    let responseBody = Data(
        #"{"data":[{"embedding":[0.25,0.5,0.75],"index":0}]}"#.utf8
    )
    let fixture = try await RemoteNIOStreamingFixture.start(
        responseBody: responseBody,
        responseStatus: 200,
        responseHeaders: [
            RemoteHTTPHeader(name: "content-type", value: "application/json")
        ]
    )

    let endpoint = fixture.baseURL.appendingPathComponent("embeddings")
    let provider = OpenAICompatibleEmbeddingProvider(
        endpoint: endpoint,
        model: "qwen/qwen3-embedding-8b",
        apiKey: "sk-transport-test",
        transport: fixture.transport
    )

    do {
        let vector = try await provider.embed("runtime transport check")

        let captured = try #require(fixture.capturedRequests().first)
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.url?.path == "/v1/embeddings")
        let authHeaders = RemoteHTTPHeaders(captured.headerEntries)
        #expect(authHeaders.firstValue(for: "Authorization") == "Bearer sk-transport-test")
        let json = try #require(
            JSONSerialization.jsonObject(with: captured.body) as? [String: Any]
        )
        #expect(json["input"] as? String == "runtime transport check")
        #expect(json["model"] as? String == "qwen/qwen3-embedding-8b")
        #expect(vector == [0.25, 0.5, 0.75])
    } catch {
        await fixture.shutdown()
        throw error
    }

    await fixture.shutdown()
}
