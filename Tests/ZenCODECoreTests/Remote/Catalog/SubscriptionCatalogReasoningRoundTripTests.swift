import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct SubscriptionCatalogReasoningRoundTripTests {
    @Test(arguments: ["none", "off", "minimal", "low", "high"])
    func catalogManifestAndPayloadPreserveWireEffort(wire: String) async throws {
        let client = SubscriptionModelCatalogClient { request in
            (Data("""
            {"models":[{"slug":"discovered-new-model","visibility":"list","context_window":345678,
              "supported_reasoning_levels":[{"effort":"\(wire == "off" ? "off" : "none")"},{"effort":"minimal"},{"effort":"low"},{"effort":"high"}],
              "default_reasoning_level":"\(wire)"}]}
            """.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let candidates = try await ZenCODESetupRunner.discoveredSubscriptionCandidates(
            provider: .chatGPT, accessToken: "fixture", existingModels: [], client: client)
        let candidate = try #require(candidates.first)
        let selection = try #require(AgentThinkingSelection(rawValue: wire == "none" ? "off" : wire))
        let manifest = ZenCODESetupRunner.subscriptionModelManifest(candidate: candidate,
            providerID: AgentRemoteProvider.chatGPTSubscriptionProviderID, providerName: "ChatGPT",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL, chatEndpoint: .responses)
        let settings = AgentSettingsManifest(models: [manifest])
        let restored = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(settings))
        let decoded = try #require(restored.models.first)
        let copied = ZenCODESetupRunner.modelWithMetadata(decoded,
            configuredContextWindowLimit: decoded.configuredContextWindowLimit,
            thinkingOptions: decoded.thinkingOptions, defaultThinkingSelection: decoded.defaultThinkingSelection)
        #expect(copied.defaultThinkingSelection == selection)
        #expect(copied.thinkingOptions?.contains(.minimal) == true)
        let catalog = AgentDelegationCatalogSnapshot.catalogOnly(
            AgentSettingsManifest(providers: restored.providers, models: [copied])
        )
        let delegated = try #require(catalog.modelSelection(for: ResolvedAgentModelBinding(
            binding: AgentModelBinding(modelID: copied.id, thinkingSelection: selection), model: copied
        )))
        #expect(delegated.configuredContextWindowLimit == 345678)
        let runtimeConfiguration = AgentRuntimeConfiguration(
            modelID: copied.modelID, workingDirectory: FileManager.default.temporaryDirectory,
            maxToolRounds: 1, toolAuthorizationHandler: nil
        ).withModelSettings(
            configuredContextWindowLimit: delegated.configuredContextWindowLimit,
            generationParameterOverrides: delegated.generationParameterOverrides
        )
        let runtime = ChatGPTSubscriptionGenerationClient(configuration: runtimeConfiguration)
        #expect(await runtime.resolvedContextWindowTokenLimit() == 345678)
        await runtime.shutdown()
        let overrides = try #require(copied.generationParameterOverrides).normalized()
        #expect(overrides.subscriptionReasoningLevels == candidate.subscriptionReasoningLevels)
        let effort = ChatGPTSubscriptionGenerationClient.chatGPTReasoningEffort(
            for: selection, catalogLevels: overrides.subscriptionReasoningLevels)
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(input: .array([]), model: copied.modelID,
            instructions: "fixture", reasoningEffort: effort,
            preservesCatalogReasoningEffort: overrides.subscriptionReasoningLevels != nil,
            textVerbosity: "medium", sessionID: "fixture")
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == wire)
        if selection == .off { #expect(reasoning["summary"] == nil) }
    }

    @Test(arguments: ["none", "off"])
    func onlyOffIsNoThinkingAndExplicitOnWire(wire: String) async throws {
        let client = SubscriptionModelCatalogClient { request in
            (Data("""
            {"models":[{"slug":"off-only-model","visibility":"list",
              "supported_reasoning_levels":[{"effort":"\(wire)"}],"default_reasoning_level":"\(wire)"}]}
            """.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let candidates = try await ZenCODESetupRunner.discoveredSubscriptionCandidates(
            provider: .chatGPT, accessToken: "fixture", existingModels: [], client: client)
        let candidate = try #require(candidates.first)
        #expect(candidate.thinkingSupport?.supportsThinking == false)
        let manifest = ZenCODESetupRunner.subscriptionModelManifest(candidate: candidate,
            providerID: AgentRemoteProvider.chatGPTSubscriptionProviderID, providerName: "ChatGPT",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL, chatEndpoint: .responses)
        let settings = AgentSettingsManifest(models: [manifest])
        let restored = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(settings))
        let decoded = try #require(restored.models.first)
        #expect(decoded.thinkingOptions == [.off])
        #expect(decoded.defaultThinkingSelection == .off)
        let overrides = try #require(decoded.generationParameterOverrides).normalized()
        let effort = ChatGPTSubscriptionGenerationClient.chatGPTReasoningEffort(
            for: try #require(decoded.defaultThinkingSelection), catalogLevels: overrides.subscriptionReasoningLevels)
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(input: .array([]), model: decoded.modelID,
            instructions: "fixture", reasoningEffort: effort, preservesCatalogReasoningEffort: true,
            textVerbosity: "medium", sessionID: "fixture")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == wire)
    }

    @Test func legacyMetadataAndEffortRemainCompatible() throws {
        let legacy = try JSONDecoder().decode(AgentGenerationParameterOverrides.self, from: Data("{}".utf8))
        #expect(legacy.subscriptionReasoningLevels == nil)
        #expect(legacy.normalized().nilIfEmpty == nil)
        #expect(ChatGPTSubscriptionGenerationClient.chatGPTReasoningEffort(for: .minimal) == "low")
        #expect(ChatGPTSubscriptionGenerationClient.chatGPTReasoningEffort(for: .off) == nil)
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(input: .array([]), model: "legacy",
            instructions: "fixture", reasoningEffort: "none", textVerbosity: "medium", sessionID: "fixture")
        #expect(body["reasoning"] == nil)
    }
}
