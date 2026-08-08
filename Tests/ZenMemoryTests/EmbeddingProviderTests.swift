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

// MARK: - URLSession transport round-trip

/// Proves that `embed()` drives an actual POST through the URL loading
/// system to the configured path (here `/v1/embeddings`) and decodes the
/// response — not just that the in-memory `URLRequest` has the right shape.
///
/// The transport is intercepted by a `URLProtocol` recorder, so this test
/// never touches the network: it validates the request/response contract
/// (method, path, headers, body, decoding) that `request(for:)`-only tests
/// leave unexercised.
@Test
func embedPerformsPOSTToConfiguredEmbeddingsPathThroughURLSession() async throws {
    final class EmbeddingTransportRecorder: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var capturedRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.capturedRequest = request
            let body = Data(#"{"data":[{"embedding":[0.25,0.5,0.75],"index":0}]}"#.utf8)
            let response = HTTPURLResponse(
                url: try! #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EmbeddingTransportRecorder.self]
    let session = URLSession(configuration: configuration)

    let endpoint = try #require(URL(string: "http://127.0.0.1:8123/v1/embeddings"))
    let provider = OpenAICompatibleEmbeddingProvider(
        endpoint: endpoint,
        model: "qwen/qwen3-embedding-8b",
        apiKey: "sk-transport-test",
        session: session
    )

    let vector = try await provider.embed("runtime transport check")

    let captured = try #require(EmbeddingTransportRecorder.capturedRequest)
    #expect(captured.httpMethod == "POST")
    #expect(captured.url?.path(percentEncoded: false) == "/v1/embeddings")
    #expect(captured.url?.host == "127.0.0.1")
    #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer sk-transport-test")
    // URLSession may turn `httpBody` into a body stream on the wire; read
    // whichever form the intercepted request carries.
    let body = try #require(bodyData(from: captured))
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["input"] as? String == "runtime transport check")
    #expect(json["model"] as? String == "qwen/qwen3-embedding-8b")
    #expect(vector == [0.25, 0.5, 0.75])
}

/// Reads the request body regardless of whether the URL loading system kept it
/// as `httpBody` or materialized it as an `httpBodyStream`.
private func bodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody { return httpBody }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
