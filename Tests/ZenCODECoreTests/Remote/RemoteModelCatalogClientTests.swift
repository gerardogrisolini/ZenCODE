//
//  RemoteModelCatalogClientTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct RemoteModelCatalogClientTests {
    @Test
    func modelCatalogRequestAlwaysTargetsOpenRouter() throws {
        let request = try RemoteModelCatalogClient().modelsRequest(
            apiKey: "sk-openrouter-test"
        )
        let expectedURL = try #require(
            URL(string: "https://openrouter.ai/api/v1/models")
        )
        let providerGenerationURL = try #require(
            URL(string: "https://integrate.api.nvidia.com/v1/models")
        )
        let headers = RemoteHTTPHeaders(request.headers)

        #expect(request.method == "GET")
        #expect(request.url == expectedURL)
        #expect(request.url != providerGenerationURL)
        #expect(headers.firstValue(for: "Authorization") == "Bearer sk-openrouter-test")
        #expect(
            RemoteModelCatalogClient.openRouterAPIKey(
                providerBaseURL: "https://integrate.api.nvidia.com/v1",
                apiKey: "nvidia-secret"
            ) == nil
        )
        #expect(
            RemoteModelCatalogClient.openRouterAPIKey(
                providerBaseURL: AgentRemoteProvider.defaultOpenRouterBaseURL,
                apiKey: "sk-openrouter-test"
            ) == "sk-openrouter-test"
        )
    }

    @Test
    func detectsThinkingParametersFromRemoteServerModelMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "remote-community/qwen3-test",
                "thinking": [
                    "supports_thinking": true,
                    "supports_reasoning_effort": true,
                    "supports_preserve_thinking": true,
                    "available_selections": ["off", "low", "medium", "high"],
                    "default_selection": "medium"
                ]
            ],
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "remote-community/qwen3-test"
        )

        #expect(support?.supportsThinking == true)
        #expect(support?.supportsReasoningEffort == true)
        #expect(support?.supportsPreserveThinking == true)
        #expect(support?.availableSelections == [.off, .low, .medium, .high])
        #expect(support?.defaultSelection == .medium)

        let manifest = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Test",
            modelID: "remote-community/qwen3-test",
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
    func doesNotInferThinkingForSparseNVIDIANemotronCatalogIDsWithoutMetadata() {
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
    func parsesOpenRouterReasoningSupportedEffortsFromMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "deepseek/deepseek-v4-pro",
                "supported_parameters": ["reasoning", "reasoning_effort"],
                "reasoning": [
                    "mandatory": false,
                    "supported_efforts": ["max", "high", "low"],
                    "default_effort": "high"
                ] as [String: Any]
            ],
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "deepseek/deepseek-v4-pro"
        )

        guard let thinkingSupport = support else {
            Issue.record("thinking support expected")
            return
        }
        #expect(thinkingSupport.supportsThinking)
        #expect(thinkingSupport.supportsReasoningEffort)
        #expect(thinkingSupport.availableSelections == [.off, .low, .high, .max])
        #expect(thinkingSupport.defaultSelection == .high)
    }

    @Test
    func modelWithoutReasoningDataHasNoThinkingSupport() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "meta-llama/llama-3.3-70b-instruct",
                "name": "Llama 3.3 70B Instruct"
            ],
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "meta-llama/llama-3.3-70b-instruct"
        )

        #expect(support == nil)
    }

    @Test
    func modalDirectProvidersRequireAPIKeys() {
        let provider = AgentRemoteProvider(
            name: "Modal",
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "remote-community/qwen3-test"
        )

        #expect(provider.requiresAPIKey)
    }
}
