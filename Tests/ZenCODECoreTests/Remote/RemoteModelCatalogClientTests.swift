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
    func providerModelCatalogRequestTargetsConfiguredProvider() throws {
        let request = try RemoteModelCatalogClient().modelsRequest(
            baseURL: "https://integrate.api.nvidia.com/v1",
            apiKey: "nvidia-secret"
        )
        let expectedURL = try #require(URL(string: "https://integrate.api.nvidia.com/v1/models"))
        let providerGenerationURL = try #require(
            URL(string: "https://openrouter.ai/api/v1/models")
        )
        let headers = RemoteHTTPHeaders(request.headers)

        #expect(request.method == "GET")
        #expect(request.url == expectedURL)
        #expect(request.url != providerGenerationURL)
        #expect(headers.firstValue(for: "Authorization") == "Bearer nvidia-secret")
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
    func anthropicCatalogRequestMergesLimitWithExistingBaseQuery() throws {
        let request = try RemoteModelCatalogClient().modelsRequest(
            baseURL: "https://api.anthropic.com/custom/v1?region=eu",
            apiKey: "anthropic-secret"
        )
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        )

        #expect(components.path == "/custom/v1/models")
        #expect(components.queryItems == [
            URLQueryItem(name: "region", value: "eu"),
            URLQueryItem(name: "limit", value: "1000")
        ])
        #expect(
            RemoteHTTPHeaders(request.headers).firstValue(for: "x-api-key")
                == "anthropic-secret"
        )
    }

    @Test
    func enrichingOpenRouterMetadataMergesCatalogContextWithoutReplacingProviderFields() async throws {
        let providerModel = OpenRouterModelInfo(
            id: "provider/model",
            name: "Provider Model",
            contextLength: nil,
            pricing: OpenRouterModelPricing(prompt: 0.001, completion: 0.002),
            thinkingSupport: nil,
            generationParameterOverrides: AgentGenerationParameterOverrides(maxTokens: 321),
            installed: true,
            loaded: false,
            serverLoaded: true
        )
        let catalogModel = OpenRouterModelInfo(
            id: "provider/model",
            name: "Catalog Model",
            contextLength: 131_072,
            pricing: OpenRouterModelPricing(prompt: 0.003, completion: 0.004),
            thinkingSupport: .generic,
            generationParameterOverrides: AgentGenerationParameterOverrides(maxTokens: 123),
            installed: false,
            loaded: true,
            serverLoaded: false
        )

        let enriched = try await ZenCODESetupRunner.enrichModelsWithOpenRouterMetadata(
            [providerModel],
            providerBaseURL: "https://provider.example/v1",
            apiKey: nil,
            catalogLoader: { [catalogModel] in
                [catalogModel]
            }
        )

        let merged = try #require(enriched.first)
        #expect(merged.contextLength == catalogModel.contextLength)
        #expect(merged.thinkingSupport == catalogModel.thinkingSupport)
        #expect(merged.pricing == providerModel.pricing)
        #expect(merged.generationParameterOverrides == providerModel.generationParameterOverrides)
        #expect(merged.installed == providerModel.installed)
        #expect(merged.loaded == providerModel.loaded)
        #expect(merged.serverLoaded == providerModel.serverLoaded)
    }

    @Test
    func deepSeekEnrichmentPreservesDiscoveryAndDoesNotImportRoutedThinking() async throws {
        let modelIDs = ["deepseek-flash", "deepseek-v4-pro", "deepseek-future"]
        let discovered = modelIDs.map {
            OpenRouterModelInfo(id: $0, name: $0, contextLength: nil, pricing: nil)
        }
        let catalog = (modelIDs + ["not-discovered"]).map {
            OpenRouterModelInfo(
                id: "deepseek/\($0)", name: $0, contextLength: 131_072, pricing: nil,
                thinkingSupport: .effort(levels: [.medium, .xhigh], defaultSelection: .medium)
            )
        }
        for baseURL in ["https://api.deepseek.com", "https://api.deepseek.com/v1"] {
            let enriched = try await ZenCODESetupRunner.enrichModelsWithOpenRouterMetadata(
                discovered, providerBaseURL: baseURL, apiKey: nil, catalogLoader: { catalog }
            )
            #expect(enriched.map(\.id) == modelIDs)
            #expect(enriched.allSatisfy { $0.contextLength == 131_072 })
            #expect(enriched.allSatisfy { $0.thinkingSupport == nil })
            let manifests = enriched.map {
                ZenCODESetupRunner.remoteModelManifest(
                    from: $0, providerID: "deepseek", providerName: "DeepSeek",
                    baseURL: baseURL, chatEndpoint: .chatCompletions
                )
            }
            #expect(manifests.map(\.modelID) == modelIDs)
            #expect(manifests[0].thinkingOptions == [.off, .low, .high, .max])
            #expect(manifests[1].defaultThinkingSelection == .high)
            #expect(manifests[2].thinkingOptions == nil)
            #expect(manifests[2].defaultThinkingSelection == nil)
        }
        let other = try await ZenCODESetupRunner.enrichModelsWithOpenRouterMetadata(
            discovered, providerBaseURL: "https://other.example/v1", apiKey: nil,
            catalogLoader: { catalog }
        )
        #expect(other.allSatisfy { $0.thinkingSupport?.availableSelections == [.off, .medium, .xhigh] })
    }

    @Test
    func enrichingUnqualifiedZAIModelsUsesUniqueOpenRouterSuffixMetadata() async throws {
        let providerModels = [
            OpenRouterModelInfo(id: "glm-5-turbo", name: "GLM 5 Turbo", contextLength: nil, pricing: nil),
            OpenRouterModelInfo(id: "glm-5.2", name: "GLM 5.2", contextLength: nil, pricing: nil)
        ]
        let turboThinking = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "reasoning": ["mandatory": false, "default_enabled": true] as [String: Any]
            ],
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "z-ai/glm-5-turbo"
        )
        let glm52Thinking = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "reasoning": [
                    "mandatory": false,
                    "default_enabled": true,
                    "supported_efforts": ["xhigh", "high"],
                    "default_effort": "high"
                ] as [String: Any]
            ],
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "z-ai/glm-5.2"
        )
        let catalog = [
            OpenRouterModelInfo(id: "z-ai/glm-5-turbo", name: "GLM 5 Turbo", contextLength: 202_752, pricing: nil, thinkingSupport: turboThinking),
            OpenRouterModelInfo(id: "z-ai/glm-5.2", name: "GLM 5.2", contextLength: 1_048_576, pricing: nil, thinkingSupport: glm52Thinking)
        ]

        let enriched = try await ZenCODESetupRunner.enrichModelsWithOpenRouterMetadata(
            providerModels,
            providerBaseURL: "https://api.z.ai/v1",
            apiKey: nil,
            catalogLoader: { catalog }
        )

        #expect(enriched.map(\.id) == ["glm-5-turbo", "glm-5.2"])
        #expect(enriched.map(\.contextLength) == [202_752, 1_048_576])
        #expect(enriched[0].thinkingSupport?.availableSelections == [.enabled, .off])
        #expect(enriched[0].thinkingSupport?.defaultSelection == .enabled)
        #expect(enriched[1].thinkingSupport?.availableSelections == [.off, .high, .xhigh])
        #expect(enriched[1].thinkingSupport?.defaultSelection == .high)
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
            providerID: "modal",
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

    @Test(arguments: [
        ("https://integrate.api.nvidia.com/v1", "nvidia/llama-3.3-nemotron-super-49b-v1"),
        ("https://integrate.api.nvidia.com/v1", "meta/llama-3.3-70b-instruct"),
        ("https://api.us-west-2.modal.direct/v1", "zai-org/GLM-5.1-FP8"),
        ("https://openrouter.ai/api/v1", "meta-llama/llama-3.3-70b-instruct")
    ])
    func modelWithoutReasoningDataHasNoThinkingSupport(baseURL: String, modelID: String) {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": modelID
            ],
            baseURL: baseURL,
            modelID: modelID
        )

        #expect(support == nil)
    }
}

extension RemoteModelCatalogClientTests {
    @Test
    func authPolicyGatesCatalogAuthorizationWithoutDiscardingAPIKey() throws {
        let residualKey = "residual-secret"
        let noAuthRequest = try RemoteModelCatalogClient().modelsRequest(
            baseURL: "https://catalog.example.test/v1",
            apiKey: AgentProviderAuthPolicy.noAuthentication.effectiveAPIKey(residualKey)
        )
        #expect(
            RemoteHTTPHeaders(noAuthRequest.headers).firstValue(for: "Authorization") == nil
        )

        for policy in [AgentProviderAuthPolicy.apiKeyOptional, .apiKeyRequired] {
            let request = try RemoteModelCatalogClient().modelsRequest(
                baseURL: "https://catalog.example.test/v1",
                apiKey: policy.effectiveAPIKey(residualKey)
            )
            #expect(
                RemoteHTTPHeaders(request.headers).firstValue(for: "Authorization")
                    == "Bearer \(residualKey)"
            )
        }
        #expect(residualKey == "residual-secret")
    }

    @Test
    func anthropicCatalogDialectRequiresTheExactOfficialHost() throws {
        let client = RemoteModelCatalogClient()
        let anthropic = try client.modelsRequest(
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "anthropic-key"
        )
        let anthropicHeaders = RemoteHTTPHeaders(anthropic.headers)
        #expect(anthropic.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(anthropicHeaders.firstValue(for: "x-api-key") == "anthropic-key")
        #expect(anthropicHeaders.firstValue(for: "anthropic-version") == "2023-06-01")
        #expect(anthropicHeaders.firstValue(for: "Authorization") == nil)

        let custom = try client.modelsRequest(
            baseURL: "https://catalog.example.test/api.anthropic.com/v1",
            apiKey: "custom-key"
        )
        let customHeaders = RemoteHTTPHeaders(custom.headers)
        #expect(custom.url.absoluteString == "https://catalog.example.test/api.anthropic.com/v1/models")
        #expect(customHeaders.firstValue(for: "Authorization") == "Bearer custom-key")
        #expect(customHeaders.firstValue(for: "x-api-key") == nil)
        #expect(customHeaders.firstValue(for: "anthropic-version") == nil)
    }
}
