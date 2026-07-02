//
//  RemoteModelCatalogClientTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct RemoteModelCatalogClientTests {
    @Test
    func detectsThinkingParametersFromMLXServerModelMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "mlx-community/qwen3-test",
                "thinking": [
                    "supports_thinking": true,
                    "supports_reasoning_effort": true,
                    "supports_preserve_thinking": true,
                    "available_selections": ["off", "low", "medium", "high"],
                    "default_selection": "medium"
                ]
            ],
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "mlx-community/qwen3-test"
        )

        #expect(support?.supportsThinking == true)
        #expect(support?.supportsReasoningEffort == true)
        #expect(support?.supportsPreserveThinking == true)
        #expect(support?.availableSelections == [.off, .low, .medium, .high])
        #expect(support?.defaultSelection == .medium)

        let manifest = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Test",
            modelID: "mlx-community/qwen3-test",
            providerID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            providerName: "Modal",
            baseURL: "https://api.us-west-2.modal.direct/v1",
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: support
        )

        #expect(manifest.availableThinkingSelections == [.off, .low, .medium, .high])
        #expect(manifest.resolvedDefaultThinkingSelection == .medium)
    }

    @Test
    func doesNotInferThinkingForSparseNVIDIANemotronCatalogIDsWithoutHuggingFaceMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "nvidia/llama-3.3-nemotron-super-49b-v1"
            ],
            baseURL: "https://integrate.api.nvidia.com/v1",
            modelID: "nvidia/llama-3.3-nemotron-super-49b-v1"
        )

        #expect(support == nil)
    }

    @Test
    func doesNotInferThinkingForSparseNonReasoningNVIDIAModels() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "meta/llama-3.3-70b-instruct"
            ],
            baseURL: "https://integrate.api.nvidia.com/v1",
            modelID: "meta/llama-3.3-70b-instruct"
        )

        #expect(support == nil)
    }

    @Test
    func doesNotFallbackToGenericThinkingForModalDirectModelsWithoutMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "zai-org/GLM-5.1-FP8"
            ],
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "zai-org/GLM-5.1-FP8"
        )

        #expect(support == nil)
    }

    @Test
    func enrichesNonOpenRouterCatalogModelsFromHuggingFace() async throws {
        let session = RemoteModelCatalogURLProtocol.urlSession(
            routes: [
                "https://provider.test/v1/models": .json(
                    """
                    {
                      "object": "list",
                      "data": [
                        {
                          "id": "deepseek-ai/deepseek-v4-flash",
                          "object": "model",
                          "created": 1,
                          "owned_by": "deepseek-ai"
                        }
                      ]
                    }
                    """
                ),
                "https://hf.test/api/models/deepseek-ai/deepseek-v4-flash": .json(
                    """
                    {
                      "id": "deepseek-ai/DeepSeek-V4-Flash",
                      "modelId": "deepseek-ai/DeepSeek-V4-Flash",
                      "siblings": [
                        { "rfilename": "config.json" },
                        { "rfilename": "tokenizer_config.json" },
                        { "rfilename": "README.md" }
                      ]
                    }
                    """
                ),
                "https://hf.test/deepseek-ai/DeepSeek-V4-Flash/raw/main/config.json": .json(
                    """
                    {
                      "model_type": "deepseek_v4",
                      "max_position_embeddings": 1048576
                    }
                    """
                ),
                "https://hf.test/deepseek-ai/DeepSeek-V4-Flash/raw/main/tokenizer_config.json": .json(
                    """
                    {
                      "model_max_length": 1048576
                    }
                    """
                ),
                "https://hf.test/deepseek-ai/DeepSeek-V4-Flash/raw/main/README.md": .text(
                    """
                    DeepSeek-V4-Flash supports three reasoning effort modes:
                    | Reasoning Mode | Response Format |
                    | Non-think | </think> summary |
                    | Think High | <think> thinking </think> summary |
                    | Think Max | special system prompt + <think> thinking </think> summary |
                    """
                )
            ]
        )
        let client = RemoteModelCatalogClient(
            urlSession: session,
            huggingFaceBaseURL: "https://hf.test"
        )

        let models = try await client.fetchModels(
            baseURL: "https://provider.test/v1",
            apiKey: nil
        )

        let model = try #require(models.first)
        #expect(model.contextLength == 1_048_576)
        let thinkingSupport = try #require(model.thinkingSupport)
        #expect(thinkingSupport.supportsThinking)
        #expect(thinkingSupport.supportsReasoningEffort)
        #expect(thinkingSupport.availableSelections == [.off, .high, .xhigh])
        #expect(thinkingSupport.defaultSelection == .high)
    }

    @Test
    func skipsHuggingFaceEnrichmentForOpenRouter() async throws {
        let session = RemoteModelCatalogURLProtocol.urlSession(
            routes: [
                "https://openrouter.ai/api/v1/models": .json(
                    """
                    {
                      "data": [
                        {
                          "id": "deepseek-ai/deepseek-v4-flash",
                          "name": "DeepSeek V4 Flash"
                        }
                      ]
                    }
                    """
                )
            ]
        )
        let client = RemoteModelCatalogClient(
            urlSession: session,
            huggingFaceBaseURL: "https://hf.test"
        )

        let models = try await client.fetchModels(
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: nil
        )

        let model = try #require(models.first)
        #expect(model.contextLength == nil)
        #expect(model.thinkingSupport == nil)
        #expect(!RemoteModelCatalogURLProtocol.capturedURLs().contains { $0.host == "hf.test" })
    }

    @Test
    func modalDirectProvidersRequireAPIKeys() {
        let provider = AgentRemoteProvider(
            name: "Modal",
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "mlx-community/qwen3-test"
        )

        #expect(provider.requiresAPIKey)
    }
}

/// URLProtocol subclasses are invoked by URLSession across threads; static test state is protected by `lock`.
private final class RemoteModelCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let statusCode: Int
        let contentType: String
        let body: Data

        static func json(
            _ string: String,
            statusCode: Int = 200
        ) -> Route {
            Route(
                statusCode: statusCode,
                contentType: "application/json",
                body: Data(string.utf8)
            )
        }

        static func text(
            _ string: String,
            statusCode: Int = 200
        ) -> Route {
            Route(
                statusCode: statusCode,
                contentType: "text/plain",
                body: Data(string.utf8)
            )
        }
    }

    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var urls: [URL] = []
    private static let lock = NSLock()

    static func urlSession(routes: [String: Route]) -> URLSession {
        lock.lock()
        self.routes = routes
        self.urls = []
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteModelCatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func capturedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://unit.test")!
        Self.lock.lock()
        Self.urls.append(url)
        let route = Self.routes[url.absoluteString]
        Self.lock.unlock()

        let resolvedRoute = route ?? Route.text("Not found", statusCode: 404)
        let response = HTTPURLResponse(
            url: url,
            statusCode: resolvedRoute.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": resolvedRoute.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resolvedRoute.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
