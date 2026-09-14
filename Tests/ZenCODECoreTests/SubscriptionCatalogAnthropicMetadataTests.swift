import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct SubscriptionCatalogAnthropicMetadataTests {
    @Test func explicitModesParseAndBuildAuthorizedThinkingPayloads() async throws {
        let client = SubscriptionModelCatalogClient { request in
            let data = Data("""
            {"data":[
              {"id":"entirely-new-adaptive","max_input_tokens":300000,"max_tokens":150000,"capabilities":{
                "thinking":{"supported":true,"types":{"adaptive":{"supported":true}}},
                "effort":{"supported":true,"low":{"supported":true},"max":{"supported":true}}
              }},
              {"id":"entirely-new-manual","capabilities":{
                "thinking":{"supported":true,"types":{"enabled":{"supported":true}}}
              }},
              {"id":"claude-opus-5","max_tokens":150000,"capabilities":{
                "thinking":{"supported":true,"types":{"adaptive":{"supported":true}}},
                "effort":{"supported":true,"high":{"supported":true}}
              }}],"has_more":false}
            """.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        // No scope -> no writes, and the injected transport cannot make live requests.
        let result = try await client.load(provider: .anthropic, accessToken: "fixture")
        #expect(result.models[0].anthropicThinkingMode == "adaptive")
        #expect(result.models[0].thinkingSupport?.availableSelections == [.off, .low, .max])
        #expect(result.models[1].thinkingSupport == .generic)
        #expect(result.models[2].thinkingSupport?.availableSelections == [.off, .high])
        let candidates = try await ZenCODESetupRunner.discoveredSubscriptionCandidates(
            provider: .anthropic, accessToken: "fixture", existingModels: [], client: client
        )
        for (index, selection) in [AgentThinkingSelection.max, .enabled, .high].enumerated() {
            let manifest = ZenCODESetupRunner.subscriptionModelManifest(
                candidate: candidates[index], providerID: AgentRemoteProvider.anthropicSubscriptionProviderID,
                providerName: "Anthropic Subscription", baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                chatEndpoint: .responses
            )
            let settings = AgentSettingsManifest(models: [manifest])
            let restored = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(settings))
            let decoded = try #require(restored.models.first)
            let configuration = AgentRuntimeConfiguration(
                modelID: decoded.modelID, workingDirectory: FileManager.default.temporaryDirectory,
                maxToolRounds: 1, toolAuthorizationHandler: nil
            ).withModelSettings(
                configuredContextWindowLimit: decoded.configuredContextWindowLimit,
                generationParameterOverrides: decoded.generationParameterOverrides
            )
            let runtime = AnthropicSubscriptionGenerationClient(
                configuration: configuration, provider: try #require(decoded.provider),
                thinkingOptions: decoded.thinkingOptions
            )
            #expect(await runtime.resolvedContextWindowTokenLimit() == decoded.configuredContextWindowLimit)
            #expect(await runtime.resolvedMaxOutputTokens() == (index == 1 ? 4096 : 150000))
            let payload = await runtime.configuredThinkingPayloadForTest(selection: selection)
            let thinking = try #require(payload.objectValue?["thinking"]?.objectValue)
            #expect(thinking["type"]?.stringValue == (index == 1 ? "enabled" : "adaptive"))
            if index != 1 {
                #expect(thinking["budget_tokens"] == nil)
                #expect(payload.objectValue?["output_config"]?.objectValue?["effort"]?.stringValue == selection.rawValue)
            }
            await runtime.shutdown()
        }
        let manual = AnthropicSubscriptionGenerationClient.catalogThinkingPayload(
            mode: "enabled", selection: .enabled, options: [.off, .enabled], maxTokens: 4096)
        #expect(manual.thinking?["type"] as? String == "enabled")
        #expect((manual.thinking?["budget_tokens"] as? Int ?? 0) < 4096)
        let unsupported = AnthropicSubscriptionGenerationClient.catalogThinkingPayload(
            mode: "adaptive", selection: .high, options: [.off, .low], maxTokens: 4096)
        #expect(unsupported.thinking == nil)
    }

    @Test func opaqueLineageRoundTripLegacyAndRefresh() async throws {
        let lineage = UUID()
        let credentials = AnthropicSubscriptionCredentials(accessToken: "fixture-access", refreshToken: UUID().uuidString,
            expiresAt: .distantPast, scope: "user:inference", catalogScopeID: lineage)
        let decoded = try JSONDecoder().decode(AnthropicSubscriptionCredentials.self, from: JSONEncoder().encode(credentials))
        #expect(decoded.catalogScopeID == lineage)
        let legacy = try JSONDecoder().decode(AnthropicSubscriptionCredentials.self,
            from: Data("{\"accessToken\":\"a\",\"refreshToken\":\"r\",\"expiresAt\":0}".utf8))
        #expect(legacy.catalogScopeID == nil)
        let refreshed = try await AnthropicSubscriptionAuthService.refresh(credentials: credentials, persist: false) { _ in
            AnthropicSubscriptionCredentials(accessToken: "new-fixture", refreshToken: "new-refresh",
                expiresAt: .distantFuture, catalogScopeID: UUID())
        }
        #expect(refreshed.catalogScopeID == lineage)
        #expect(refreshed.accessToken == "new-fixture")
    }

    @Test func anthropicLastGoodCacheIsLoginScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lineage = UUID()
        let success = SubscriptionModelCatalogClient(directory: directory) { request in
            (Data("{\"data\":[{\"id\":\"new-claude\"}],\"has_more\":false}".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await success.load(provider: .anthropic, accessToken: "fixture-one", catalogScopeID: lineage)
        let offline = SubscriptionModelCatalogClient(directory: directory) { _ in throw URLError(.timedOut) }
        let cached = try await offline.load(provider: .anthropic, accessToken: "fixture-two", catalogScopeID: lineage)
        #expect(cached.isCached)
        #expect(cached.models.first?.id == "new-claude")
        await #expect(throws: SubscriptionModelCatalogClient.CatalogError.self) {
            try await offline.load(provider: .anthropic, accessToken: "fixture-two", catalogScopeID: UUID())
        }
        await #expect(throws: SubscriptionModelCatalogClient.CatalogError.self) {
            try await offline.load(provider: .anthropic, accessToken: "fixture-two")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!text.contains("fixture-one"))
        #expect(!text.contains("fixture-two"))
    }
}

extension SubscriptionCatalogAnthropicMetadataTests {
    @Test func generationOverrideMetadataRoundTripsWithoutBreakingLegacy() throws {
        let legacy = try JSONDecoder().decode(AgentGenerationParameterOverrides.self,
            from: Data("{\"maxTokens\":12000}".utf8))
        #expect(legacy.subscriptionThinkingMode == nil)
        let metadata = AgentGenerationParameterOverrides(maxTokens: 150000, subscriptionThinkingMode: "adaptive")
        let roundTrip = try JSONDecoder().decode(AgentGenerationParameterOverrides.self,
            from: JSONEncoder().encode(metadata.normalized()))
        #expect(roundTrip.subscriptionThinkingMode == "adaptive")
        #expect(roundTrip.maxTokens == 150000)
        let unknown = AnthropicSubscriptionGenerationClient.catalogThinkingPayload(
            mode: "future-wire-mode", selection: .enabled, options: [.enabled], maxTokens: 12000)
        #expect(unknown.thinking == nil)
        #expect(unknown.outputConfig == nil)
    }
}

private extension AnthropicSubscriptionGenerationClient {
    func configuredThinkingPayloadForTest(selection: AgentThinkingSelection) -> JSONValue {
        var body: [String: Any] = [:]
        applyThinkingSelection(selection, to: &body)
        return JSONValue(jsonObject: body)
    }
}
