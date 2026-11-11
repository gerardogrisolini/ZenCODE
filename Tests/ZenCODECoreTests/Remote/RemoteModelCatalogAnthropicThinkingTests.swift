//
//  RemoteModelCatalogAnthropicThinkingTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

/// Anthropic API-key setup: `/v1/models` `capabilities` must produce the wire
/// thinking mode and levels, so adaptive-only models never get `enabled`.
@Suite(.serialized)
struct RemoteModelCatalogAnthropicThinkingTests {
    private static let anthropicBaseURL = "https://api.anthropic.com/v1"
    private static let nonAnthropicBaseURL = "https://catalog.example.test/api.anthropic.com/v1"

    private static let catalogJSON = """
    {"data":[
      {"type":"model","id":"claude-adaptive-only","display_name":"Adaptive Only","max_input_tokens":1000000,"max_tokens":128000,
       "capabilities":{"image_input":{"supported":true},"pdf_input":{"supported":true},
         "thinking":{"supported":true,"types":{"adaptive":{"supported":true},"enabled":{"supported":false}}},
         "effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"max":{"supported":true}}}},
      {"type":"model","id":"claude-adaptive-off","display_name":"Adaptive With Off","max_input_tokens":200000,
       "capabilities":{"thinking":{"supported":true,"types":{"adaptive":{"supported":true},"disabled":{"supported":true}}},
         "effort":{"supported":true,"low":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true}}}},
      {"type":"model","id":"claude-manual","display_name":"Manual","max_input_tokens":200000,
       "capabilities":{"thinking":{"supported":true,"types":{"enabled":{"supported":true}}}}},
      {"type":"model","id":"claude-plain","display_name":"Plain","max_input_tokens":200000,
       "capabilities":{"thinking":{"supported":false,"types":{"enabled":{"supported":false}}}}},
      {"type":"model","id":"claude-legacy","display_name":"No Capabilities","max_input_tokens":200000},
      {"type":"model","id":"claude-merged","display_name":"Merged","max_input_tokens":200000,
       "generation_parameter_overrides":{"max_tokens":4096},
       "capabilities":{"thinking":{"supported":true,"types":{"adaptive":{"supported":true}}},
         "effort":{"supported":true,"medium":{"supported":true}}}}
    ],"has_more":false,"first_id":"claude-adaptive-only","last_id":"claude-merged"}
    """

    private static func catalogEntries() throws -> [RemoteModelCatalogEntry] {
        try JSONDecoder().decode(
            RemoteModelCatalogResponse.self,
            from: Data(catalogJSON.utf8)
        ).data
    }

    private static func models(baseURL: String) throws -> [String: OpenRouterModelInfo] {
        let client = RemoteModelCatalogClient()
        return Dictionary(
            uniqueKeysWithValues: try catalogEntries().compactMap {
                client.modelInfo(from: $0, baseURL: baseURL)
            }.map { ($0.id, $0) }
        )
    }

    private static func model(
        _ id: String,
        baseURL: String = anthropicBaseURL
    ) throws -> OpenRouterModelInfo {
        try #require(models(baseURL: baseURL)[id])
    }

    @Test
    func adaptiveWithoutDisabledSupportOffersEffortLevelsWithoutOff() throws {
        let model = try Self.model("claude-adaptive-only")

        #expect(model.generationParameterOverrides?.subscriptionThinkingMode == "adaptive")
        #expect(model.thinkingSupport?.availableSelections == [.low, .medium, .high, .max])
        #expect(model.thinkingSupport?.defaultSelection == .low)
        #expect(model.thinkingSupport?.supportsReasoningEffort == true)
        #expect(model.contextLength == 1_000_000)
    }

    @Test
    func adaptiveWithDisabledSupportIncludesOff() throws {
        let model = try Self.model("claude-adaptive-off")

        #expect(model.generationParameterOverrides?.subscriptionThinkingMode == "adaptive")
        #expect(model.thinkingSupport?.availableSelections == [.off, .low, .high, .xhigh])
        #expect(model.thinkingSupport?.defaultSelection == .low)
    }

    @Test
    func manualOnlyModelUsesGenericThinkingWithEnabledMode() throws {
        let model = try Self.model("claude-manual")

        #expect(model.generationParameterOverrides?.subscriptionThinkingMode == "enabled")
        #expect(model.thinkingSupport == .generic)
    }

    @Test
    func modelWithoutThinkingSupportIsMarkedDisabledWithoutThinkingSupport() throws {
        let model = try Self.model("claude-plain")

        #expect(model.generationParameterOverrides?.subscriptionThinkingMode == "disabled")
        #expect(model.thinkingSupport == nil)
    }

    @Test
    func entryWithoutCapabilitiesKeepsGenericBehavior() throws {
        let entry = try #require(
            Self.catalogEntries().first { stringValue($0.values, "id") == "claude-legacy" }
        )
        let model = try Self.model("claude-legacy")

        #expect(model.generationParameterOverrides == nil)
        #expect(
            model.thinkingSupport == RemoteModelCatalogClient.thinkingSupport(
                fromModelMetadata: modelMetadata(from: entry),
                baseURL: Self.anthropicBaseURL,
                modelID: "claude-legacy"
            )
        )
    }

    @Test
    func capabilitiesMergeWithExistingGenerationOverrides() throws {
        let model = try Self.model("claude-merged")

        #expect(
            model.generationParameterOverrides
                == AgentGenerationParameterOverrides(maxTokens: 4096, subscriptionThinkingMode: "adaptive")
        )
        #expect(model.thinkingSupport?.availableSelections == [.medium])
    }

    @Test
    func nonAnthropicBaseURLIgnoresCapabilities() throws {
        let entries = try Self.catalogEntries()
        let models = try Self.models(baseURL: Self.nonAnthropicBaseURL)

        #expect(models.count == entries.count)
        for entry in entries {
            let id = try #require(stringValue(entry.values, "id"))
            let model = try #require(models[id])
            #expect(model.generationParameterOverrides?.subscriptionThinkingMode == nil)
            #expect(
                model.thinkingSupport == RemoteModelCatalogClient.thinkingSupport(
                    fromModelMetadata: modelMetadata(from: entry),
                    baseURL: Self.nonAnthropicBaseURL,
                    modelID: id
                )
            )
        }
    }

    @Test
    func capabilityParsingKeepsSubscriptionEdgeCases() {
        // Adaptive advertised without any supported effort level is not adaptive.
        let noLevels = AnthropicModelCapabilities(entry: ["capabilities": [
            "thinking": ["supported": true, "types": [
                "adaptive": ["supported": true], "enabled": ["supported": true]
            ]],
            "effort": ["supported": true]
        ] as [String: Any]])
        #expect(noLevels.thinkingMode == "disabled")
        #expect(noLevels.effortLevels.isEmpty)
        #expect(noLevels.thinkingSupport == nil)

        // Adaptive without effort controls falls back to manual thinking.
        let manual = AnthropicModelCapabilities(entry: ["capabilities": [
            "thinking": ["supported": true, "types": [
                "adaptive": ["supported": true], "enabled": ["supported": true]
            ]]
        ] as [String: Any]])
        #expect(manual.thinkingMode == "enabled")
        #expect(manual.thinkingSupport == .generic)

        // A missing or non-boolean flag is unsupported.
        let missing = AnthropicModelCapabilities(entry: [:])
        #expect(missing.thinkingMode == "disabled")
        #expect(!missing.supportsDisabledThinking)
        #expect(!AnthropicModelCapabilities.supported(["supported": 1]))
    }

    // MARK: Setup manifest round trip

    private static func restoredManifest(
        for model: OpenRouterModelInfo
    ) throws -> AgentSettingsModelManifest {
        let manifest = ZenCODESetupRunner.remoteModelManifest(
            from: model,
            providerID: "anthropic-api",
            providerName: "Anthropic API",
            baseURL: anthropicBaseURL,
            chatEndpoint: .chatCompletions
        )
        let settings = AgentSettingsManifest(models: [manifest])
        let restored = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(settings)
        )
        return try #require(restored.models.first)
    }

    private static func requestBody(
        for decoded: AgentSettingsModelManifest,
        selection: AgentThinkingSelection?
    ) throws -> [String: Any] {
        try RemoteGenerationClient.anthropicMessagesRequestBody(
            modelID: decoded.modelID,
            messages: [["role": "user", "content": "hello"]],
            toolCatalog: RemoteToolWireCatalog(descriptors: []),
            maxTokens: 8192,
            thinkingSelection: selection,
            thinkingMode: decoded.generationParameterOverrides?.subscriptionThinkingMode,
            thinkingOptions: decoded.thinkingOptions ?? []
        )
    }

    @Test(arguments: [
        ("claude-adaptive-only", AgentThinkingSelection.high),
        ("claude-adaptive-only", AgentThinkingSelection.max),
        ("claude-adaptive-off", AgentThinkingSelection.xhigh)
    ])
    func adaptiveModelRoundTripsToAdaptiveRequest(
        modelID: String,
        selection: AgentThinkingSelection
    ) throws {
        let decoded = try Self.restoredManifest(for: Self.model(modelID))
        #expect(decoded.generationParameterOverrides?.subscriptionThinkingMode == "adaptive")
        #expect(decoded.thinkingOptions?.contains(selection) == true)

        let body = try Self.requestBody(for: decoded, selection: selection)
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == selection.rawValue)
    }

    @Test
    func adaptiveOffIsSentOnlyWhenTheCatalogConfirmsDisabledThinking() throws {
        let withOff = try Self.restoredManifest(for: Self.model("claude-adaptive-off"))
        let offBody = try Self.requestBody(for: withOff, selection: .off)
        #expect((offBody["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(offBody["output_config"] == nil)

        let withoutOff = try Self.restoredManifest(for: Self.model("claude-adaptive-only"))
        #expect(withoutOff.thinkingOptions?.contains(.off) == false)
        let body = try Self.requestBody(for: withoutOff, selection: .off)
        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
    }

    @Test
    func manualModelRoundTripsToBudgetTokensRequest() throws {
        let decoded = try Self.restoredManifest(for: Self.model("claude-manual"))
        #expect(decoded.generationParameterOverrides?.subscriptionThinkingMode == "enabled")

        let body = try Self.requestBody(for: decoded, selection: .enabled)
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        let budget = try #require(thinking["budget_tokens"] as? Int)
        #expect(budget >= AnthropicSubscriptionGenerationClient.minimumThinkingBudgetTokens)
        #expect(budget < 8192)
        #expect(body["output_config"] == nil)
    }

    @Test
    func modelWithoutThinkingRoundTripsToRequestWithoutThinking() throws {
        let decoded = try Self.restoredManifest(for: Self.model("claude-plain"))
        #expect(decoded.generationParameterOverrides?.subscriptionThinkingMode == "disabled")
        #expect(decoded.thinkingOptions == nil)

        let body = try Self.requestBody(for: decoded, selection: .high)
        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
    }

    // MARK: OpenRouter enrichment

    @Test
    func openRouterEnrichmentKeepsNativeAnthropicThinking() async throws {
        let adaptive = try Self.model("claude-adaptive-only")
        let legacy = try Self.model("claude-legacy")
        let routed = ["claude-adaptive-only", "claude-legacy"].map {
            OpenRouterModelInfo(
                id: "anthropic/\($0)", name: $0, contextLength: 500_000, pricing: nil,
                thinkingSupport: .effort(levels: [.minimal, .medium], defaultSelection: .medium)
            )
        }

        let enriched = try await ZenCODESetupRunner.enrichModelsWithOpenRouterMetadata(
            [adaptive, legacy],
            providerBaseURL: Self.anthropicBaseURL,
            apiKey: nil,
            catalogLoader: { routed }
        )

        let native = try #require(enriched.first { $0.id == "claude-adaptive-only" })
        #expect(native.thinkingSupport == adaptive.thinkingSupport)
        #expect(native.generationParameterOverrides == adaptive.generationParameterOverrides)
        #expect(native.contextLength == 500_000)

        // Without a native mode the existing OpenRouter merge still applies.
        let unmarked = try #require(enriched.first { $0.id == "claude-legacy" })
        #expect(unmarked.thinkingSupport?.availableSelections == [.off, .minimal, .medium])
    }
}
