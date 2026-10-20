//
//  MemoryEmbeddingSetupTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite("Memory embedding setup")
struct MemoryEmbeddingSetupTests {
    @Test
    func settingsManifestDecodesV10AndRoundTripsV12EndpointOnlyConfiguration() throws {
        let v10 = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(
                #"""
                {
                  "version": 10,
                  "models": []
                }
                """#.utf8
            )
        )
        #expect(v10.version == 10)
        #expect(v10.memoryEmbedding == nil)

        let configured = AgentSettingsManifest(
            models: [],
            memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://embeddings.example.test/v1/embeddings"
            )
        )
        let encoded = try JSONEncoder().encode(configured)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let embedding = try #require(json["memoryEmbedding"] as? [String: Any])

        #expect(json["version"] as? Int == AgentSettingsManifest.currentVersion)
        #expect(Set(embedding.keys) == Set(["endpoint"]))
        #expect(embedding["endpoint"] as? String == "https://embeddings.example.test/v1/embeddings")
        #expect(embedding["model"] == nil)
        #expect(embedding["providerID"] == nil)
        #expect(embedding["apiKey"] == nil)

        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: encoded)
        #expect(reloaded.memoryEmbedding == configured.memoryEmbedding)
        #expect(reloaded.version == AgentSettingsManifest.currentVersion)
    }

    @Test
    func disabledRoundTripsThroughEncodeDecode() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            memoryEmbedding: .disabled
        )
        #expect(manifest.memoryEmbedding != nil)
        #expect(manifest.memoryEmbedding?.isExplicitlyDisabled == true)
        #expect(manifest.memoryEmbedding?.endpoint == nil)

        let encoded = try JSONEncoder().encode(manifest)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let embedding = try #require(json["memoryEmbedding"] as? [String: Any])
        #expect(embedding["endpoint"] == nil)

        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: encoded)
        #expect(reloaded.memoryEmbedding == manifest.memoryEmbedding)
        #expect(reloaded.memoryEmbedding?.isExplicitlyDisabled == true)
    }

    @Test
    func setupEnablesChangesAndRemovesEndpointWithoutNetworkWork() throws {
        let initial = AgentSettingsManifest(
            models: [],
            responseLanguage: "it"
        )

        let enabled = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            initial,
            endpoint: " https://first.example.test/v1/embeddings "
        )
        #expect(enabled.memoryEmbedding?.endpoint == "https://first.example.test/v1/embeddings")
        #expect(enabled.responseLanguage == "it")

        let changed = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            enabled,
            endpoint: "https://second.example.test/v1/embeddings"
        )
        #expect(changed.memoryEmbedding?.endpoint == "https://second.example.test/v1/embeddings")
        #expect(changed.responseLanguage == "it")

        let removed = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            changed,
            endpoint: nil
        )
        // Removing persists an explicit disabled marker, not absence.
        #expect(removed.memoryEmbedding == .disabled)
        #expect(removed.memoryEmbedding?.isExplicitlyDisabled == true)
        #expect(removed.responseLanguage == "it")
        #expect(ZenCODESetupRunner.memoryEmbeddingSetupDetail(removed) == "BM25 only")

        #expect(throws: ZenCODESetupError.self) {
            _ = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
                initial,
                endpoint: "ftp://embeddings.example.test"
            )
        }
        #expect(throws: ZenCODESetupError.self) {
            _ = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
                initial,
                endpoint: "   "
            )
        }
    }

    @Test
    func setupTransitionsFromDisabledToEnabledAndBack() throws {
        let initial = AgentSettingsManifest(models: [])

        // First setup: choose BM25 only.
        let disabled = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            initial,
            endpoint: nil
        )
        #expect(disabled.memoryEmbedding == .disabled)

        // Re-enable with an endpoint.
        let enabled = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            disabled,
            endpoint: "https://embed.example.test/v1/embeddings"
        )
        #expect(enabled.memoryEmbedding?.isConfigured == true)
        #expect(enabled.memoryEmbedding?.endpoint == "https://embed.example.test/v1/embeddings")

        // Disable again.
        let disabledAgain = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            enabled,
            endpoint: nil
        )
        #expect(disabledAgain.memoryEmbedding == .disabled)
    }

    @Test
    func memoryEmbeddingDisclosureNoticeStatesTextIsSentToEndpoint() {
        let notice = ZenCODESetupRunner.memoryEmbeddingDisclosureNotice

        #expect(notice.contains("sent to that endpoint"))
        #expect(notice.contains("prompt"))
        #expect(notice.hasSuffix("\n"))
    }

    @Test
    func setupDetailReflectsThreeStates() {
        let absent = AgentSettingsManifest(models: [])
        #expect(ZenCODESetupRunner.memoryEmbeddingSetupDetail(absent) == "not configured")

        let disabled = AgentSettingsManifest(models: [], memoryEmbedding: .disabled)
        #expect(ZenCODESetupRunner.memoryEmbeddingSetupDetail(disabled) == "BM25 only")

        let endpoint = AgentSettingsManifest(
            models: [],
            memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://embed.example.test/v1/embeddings"
            )
        )
        #expect(
            ZenCODESetupRunner.memoryEmbeddingSetupDetail(endpoint)
                == "https://embed.example.test/v1/embeddings"
        )
    }

    @Test
    func memoryEmbeddingSetupSectionIsRecommendedAndAvailableWithoutModels() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        #expect(options.contains { $0.section == .memoryEmbedding })
        #expect(!SetupSection.memoryEmbedding.requiresConfiguredModels)
        #expect(SetupSection.memoryEmbedding.category == .recommended)
        #expect(SetupSection.memoryEmbedding.title == "Memory embeddings")
    }

    @Test
    func resolverPrecedenceIsTaskLocalThenManifestThenLegacyEndpointThenBM25() async throws {
        let manifest = AgentSettingsManifest(
            models: [],
            memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://manifest.example.test/v1/embeddings"
            )
        )
        let legacyEndpoint = "https://legacy.example.test/v1/embeddings"

        let manifestProvider = try #require(
            MemoryEmbedding.provider(
                manifest: manifest,
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(manifestProvider.endpoint.absoluteString == "https://manifest.example.test/v1/embeddings")

        let legacyProvider = try #require(
            MemoryEmbedding.provider(
                manifest: AgentSettingsManifest(models: []),
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(legacyProvider.endpoint.absoluteString == legacyEndpoint)

        #expect(
            MemoryEmbedding.provider(
                manifest: AgentSettingsManifest(models: []),
                environment: [:]
            ) == nil
        )

        let injected = DeterministicHashEmbeddingProvider(modelID: "task-local")
        let taskLocalProvider = await MemoryEmbedding.withProvider(injected) {
            MemoryEmbedding.provider(
                manifest: manifest,
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            )
        }
        #expect(taskLocalProvider?.modelID == "task-local")

        let forcedBM25 = await MemoryEmbedding.withProvider(nil) {
            MemoryEmbedding.provider(
                manifest: manifest,
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            )
        }
        #expect(forcedBM25 == nil)
    }

    @Test
    func explicitDisabledSuppressesLegacyEnvironmentFallback() {
        let disabled = AgentSettingsManifest(
            models: [],
            memoryEmbedding: .disabled
        )
        let legacyEndpoint = "https://legacy.example.test/v1/embeddings"

        // Even with the environment variable set, an explicitly disabled
        // manifest yields no provider and no env fallback.
        #expect(
            MemoryEmbedding.provider(
                manifest: disabled,
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            ) == nil
        )
    }

    @Test
    func absentManifestFallsBackToLegacyEnvironment() throws {
        let legacyEndpoint = "https://legacy.example.test/v1/embeddings"

        // An absent memoryEmbedding field (nil) preserves the legacy env fallback.
        let provider = try #require(
            MemoryEmbedding.provider(
                manifest: AgentSettingsManifest(models: []),
                environment: [MemoryEmbedding.environmentEndpointKey: legacyEndpoint]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(provider.endpoint.absoluteString == legacyEndpoint)
    }

    // MARK: - OpenRouter embedding preset

    @Test
    func legacyV11EndpointOnlyManifestDecodesWithNilModelAndProviderID() throws {
        let v11 = try JSONDecoder().decode(
            AgentMemoryEmbeddingSettingsManifest.self,
            from: Data(
                #"""
                {
                  "endpoint": "https://embeddings.example.test/v1/embeddings"
                }
                """#.utf8
            )
        )
        #expect(v11.endpoint == "https://embeddings.example.test/v1/embeddings")
        #expect(v11.model == nil)
        #expect(v11.providerID == nil)
        #expect(v11.isConfigured == true)

        // Re-encoding a legacy value stays byte-compatible: no model/providerID.
        let encoded = try JSONEncoder().encode(v11)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(json.keys) == Set(["endpoint"]))
    }

    @Test
    func openRouterProposalRequiresConfiguredOpenRouterProvider() throws {
        // No manifest: no proposal.
        #expect(ZenCODESetupRunner.openRouterEmbeddingProposal(in: nil) == nil)

        // Manifest without providers: no proposal.
        #expect(
            ZenCODESetupRunner.openRouterEmbeddingProposal(
                in: AgentSettingsManifest(models: [])
            ) == nil
        )

        // Only a non-OpenRouter provider: no proposal.
        let localProvider = AgentSettingsProviderManifest(
            id: UUID(),
            name: "Local",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .chatCompletions
        )
        #expect(
            ZenCODESetupRunner.openRouterEmbeddingProposal(
                in: AgentSettingsManifest(
                    providers: [localProvider],
                    models: []
                )
            ) == nil
        )

        // OpenRouter provider configured: proposal precompiles endpoint+model
        // and pins the provider ID.
        let openRouterID = UUID()
        let openRouterProvider = AgentSettingsProviderManifest(
            id: openRouterID,
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            chatEndpoint: .chatCompletions
        )
        let proposal = try #require(
            ZenCODESetupRunner.openRouterEmbeddingProposal(
                in: AgentSettingsManifest(
                    providers: [localProvider, openRouterProvider],
                    models: []
                )
            )
        )
        #expect(proposal.endpoint == "https://openrouter.ai/api/v1/embeddings")
        #expect(proposal.model == "qwen/qwen3-embedding-8b")
        #expect(proposal.providerID == openRouterID)
    }

    @Test
    func setupMenuProposesOpenRouterOnlyWhenConfigured() throws {
        let proposal = ZenCODESetupRunner.MemoryEmbeddingOpenRouterProposal(
            endpoint: "https://openrouter.ai/api/v1/embeddings",
            model: "qwen/qwen3-embedding-8b",
            providerID: UUID()
        )

        // Without a proposal the menu is the classic endpoint-only set and the
        // default stays BM25-only when nothing is configured.
        let classic = ZenCODESetupRunner.memoryEmbeddingSetupMenu(
            existingSettings: nil,
            openRouterProposal: nil
        )
        #expect(!classic.items.contains { $0.value == .openRouter })
        #expect(classic.defaultChoice == .bm25Only)
        #expect(classic.items.map(\.value) == [.bm25Only, .configureEndpoint])

        // With a proposal the OpenRouter choice is proposed immediately
        // (right after the BM25 default), precompiling endpoint and model.
        let proposed = ZenCODESetupRunner.memoryEmbeddingSetupMenu(
            existingSettings: nil,
            openRouterProposal: proposal
        )
        let openRouterItem = try #require(
            proposed.items.first { $0.value == .openRouter }
        )
        #expect(openRouterItem.title == "Use OpenRouter embeddings")
        #expect(
            openRouterItem.detail
                == "https://openrouter.ai/api/v1/embeddings · choose a model"
        )
        #expect(proposed.items.map(\.value) == [.bm25Only, .openRouter, .configureEndpoint])
        // Existing UX preserved: enabling still defaults to BM25 only.
        #expect(proposed.defaultChoice == .bm25Only)

        // Change flow: proposal visible, default remains "change endpoint".
        let existing = AgentMemoryEmbeddingSettingsManifest(
            endpoint: "https://embeddings.example.test/v1/embeddings"
        )
        let changed = ZenCODESetupRunner.memoryEmbeddingSetupMenu(
            existingSettings: existing,
            openRouterProposal: proposal
        )
        #expect(changed.items.contains { $0.value == .openRouter })
        #expect(changed.defaultChoice == .configureEndpoint)
        #expect(
            changed.items.map(\.value)
                == [.bm25Only, .openRouter, .configureEndpoint, .removeConfiguration]
        )
    }

    @Test
    func setupPersistsOpenRouterProposalEndpointModelAndProviderID() throws {
        let providerID = UUID()
        let initial = AgentSettingsManifest(
            providers: [
                AgentSettingsProviderManifest(
                    id: providerID,
                    name: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    chatEndpoint: .chatCompletions
                )
            ],
            models: [],
            responseLanguage: "it"
        )

        let enabled = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            initial,
            endpoint: "https://openrouter.ai/api/v1/embeddings",
            model: "qwen/qwen3-embedding-8b",
            providerID: providerID
        )
        #expect(
            enabled.memoryEmbedding?.endpoint == "https://openrouter.ai/api/v1/embeddings"
        )
        #expect(enabled.memoryEmbedding?.model == "qwen/qwen3-embedding-8b")
        #expect(enabled.memoryEmbedding?.providerID == providerID)
        #expect(enabled.responseLanguage == "it")

        // Round-trip survives encode/decode.
        let reloaded = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(enabled)
        )
        #expect(reloaded.memoryEmbedding == enabled.memoryEmbedding)
        #expect(reloaded.memoryEmbedding?.model == "qwen/qwen3-embedding-8b")
        #expect(reloaded.memoryEmbedding?.providerID == providerID)

        // Detail line surfaces the model alongside the endpoint.
        #expect(
            ZenCODESetupRunner.memoryEmbeddingSetupDetail(enabled)
                == "https://openrouter.ai/api/v1/embeddings · qwen/qwen3-embedding-8b"
        )

        // Disabling drops endpoint, model and provider reference.
        let removed = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            enabled,
            endpoint: nil
        )
        #expect(removed.memoryEmbedding == .disabled)
        #expect(removed.memoryEmbedding?.model == nil)
        #expect(removed.memoryEmbedding?.providerID == nil)

        // A manual endpoint-only update (what the "change endpoint" path
        // produces) drops the preset model/provider reference: the referenced
        // provider's API key can never be forwarded to a different endpoint.
        let manualChange = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
            enabled,
            endpoint: "https://embeddings.example.test/v1/embeddings"
        )
        #expect(
            manualChange.memoryEmbedding?.endpoint
                == "https://embeddings.example.test/v1/embeddings"
        )
        #expect(manualChange.memoryEmbedding?.model == nil)
        #expect(manualChange.memoryEmbedding?.providerID == nil)
    }

    @Test
    func providerResolverPassesModelAndReusesReferencedProviderAPIKey() throws {
        let providerID = UUID()
        let manifest = AgentSettingsManifest(
            providers: [
                AgentSettingsProviderManifest(
                    id: providerID,
                    name: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    chatEndpoint: .chatCompletions
                )
            ],
            models: [],
            remoteAPIKeysByProviderID: [
                providerID.uuidString.lowercased(): "sk-openrouter-test"
            ],
            memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://openrouter.ai/api/v1/embeddings",
                model: "qwen/qwen3-embedding-8b",
                providerID: providerID
            )
        )

        let provider = try #require(
            MemoryEmbedding.provider(
                manifest: manifest,
                environment: [:]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(provider.endpoint.absoluteString == "https://openrouter.ai/api/v1/embeddings")
        #expect(provider.requestModel == "qwen/qwen3-embedding-8b")
        #expect(provider.modelID == "qwen/qwen3-embedding-8b")
        // The key is derived from the referenced provider, not duplicated in
        // the embeddings manifest.
        #expect(provider.apiKey == "sk-openrouter-test")

        // A provider reference with no stored key yields no Authorization.
        let keyless = try #require(
            MemoryEmbedding.provider(
                manifest: AgentSettingsManifest(
                    providers: [
                        AgentSettingsProviderManifest(
                            id: providerID,
                            name: "OpenRouter",
                            baseURL: "https://openrouter.ai/api/v1",
                            chatEndpoint: .chatCompletions
                        )
                    ],
                    models: [],
                    memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                        endpoint: "https://openrouter.ai/api/v1/embeddings",
                        model: "qwen/qwen3-embedding-8b",
                        providerID: providerID
                    )
                ),
                environment: [:]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(keyless.apiKey == nil)
        #expect(keyless.requestModel == "qwen/qwen3-embedding-8b")

        // Custom endpoint-only configuration (no providerID, no model): the
        // legacy behavior is unchanged.
        let custom = try #require(
            MemoryEmbedding.provider(
                manifest: AgentSettingsManifest(
                    models: [],
                    memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                        endpoint: "https://embeddings.example.test/v1/embeddings"
                    )
                ),
                environment: [:]
            ) as? OpenAICompatibleEmbeddingProvider
        )
        #expect(custom.apiKey == nil)
        #expect(custom.requestModel == nil)
    }

    @Test
    func providerAPIKeyRequiresMatchingOpenRouterProviderAndEndpoint() throws {
        let providerID = UUID()
        let openRouterProvider = AgentSettingsProviderManifest(
            id: providerID,
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            chatEndpoint: .chatCompletions
        )
        let apiKeys = [providerID.uuidString.lowercased(): "sk-openrouter-test"]

        func resolved(
            providers: [AgentSettingsProviderManifest],
            embeddingEndpoint: String
        ) throws -> OpenAICompatibleEmbeddingProvider {
            try #require(
                MemoryEmbedding.provider(
                    manifest: AgentSettingsManifest(
                        providers: providers,
                        models: [],
                        remoteAPIKeysByProviderID: apiKeys,
                        memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                            endpoint: embeddingEndpoint,
                            model: "qwen/qwen3-embedding-8b",
                            providerID: providerID
                        )
                    ),
                    environment: [:]
                ) as? OpenAICompatibleEmbeddingProvider
            )
        }

        // OpenRouter provider + OpenRouter endpoint: key reused.
        #expect(
            try resolved(
                providers: [openRouterProvider],
                embeddingEndpoint: "https://openrouter.ai/api/v1/embeddings"
            ).apiKey == "sk-openrouter-test"
        )

        // OpenRouter provider but non-OpenRouter endpoint: no key — a
        // manipulated settings.json must never forward the OpenRouter key to an
        // arbitrary host.
        #expect(
            try resolved(
                providers: [openRouterProvider],
                embeddingEndpoint: "https://embeddings.example.test/v1/embeddings"
            ).apiKey == nil
        )

        // Non-OpenRouter provider but OpenRouter endpoint: no key.
        let localProvider = AgentSettingsProviderManifest(
            id: providerID,
            name: "Local",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .chatCompletions
        )
        #expect(
            try resolved(
                providers: [localProvider],
                embeddingEndpoint: "https://openrouter.ai/api/v1/embeddings"
            ).apiKey == nil
        )

        // providerID that no longer resolves to any configured provider: no key.
        #expect(
            try resolved(
                providers: [],
                embeddingEndpoint: "https://openrouter.ai/api/v1/embeddings"
            ).apiKey == nil
        )
    }
}


extension MemoryEmbeddingSetupTests {
    @Test
    func noAuthenticationSuppressesReferencedEmbeddingBearerWithoutMutatingStoredKey() throws {
        let providerID = UUID()
        let persistedKey = "residual-secret"
        let manifest = AgentSettingsManifest(
            providers: [
                AgentSettingsProviderManifest(
                    id: providerID,
                    name: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    chatEndpoint: .chatCompletions,
                    providerProfileID: .openRouter,
                    protocolProfileID: .openAIChatCompletions,
                    authPolicy: .noAuthentication
                )
            ],
            models: [],
            remoteAPIKeysByProviderID: [providerID.uuidString.lowercased(): persistedKey],
            memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://openrouter.ai/api/v1/embeddings",
                providerID: providerID
            )
        )
        let provider = try #require(
            MemoryEmbedding.provider(manifest: manifest, environment: [:])
                as? OpenAICompatibleEmbeddingProvider
        )
        let request = try provider.streamingRequest(for: "hello")

        #expect(RemoteHTTPHeaders(request.headers).firstValue(for: "Authorization") == nil)
        #expect(manifest.remoteAPIKeysByProviderID[providerID.uuidString.lowercased()] == persistedKey)
    }

    @Test
    func keyedAuthenticationPoliciesStillSendEmbeddingBearer() throws {
        let providerID = UUID()
        for policy in [AgentProviderAuthPolicy.apiKeyOptional, .apiKeyRequired] {
            let manifest = AgentSettingsManifest(
                providers: [
                    AgentSettingsProviderManifest(
                        id: providerID,
                        name: "OpenRouter",
                        baseURL: "https://openrouter.ai/api/v1",
                        chatEndpoint: .chatCompletions,
                        providerProfileID: .openRouter,
                        protocolProfileID: .openAIChatCompletions,
                        authPolicy: policy
                    )
                ],
                models: [],
                remoteAPIKeysByProviderID: [providerID.uuidString.lowercased(): "embedding-secret"],
                memoryEmbedding: AgentMemoryEmbeddingSettingsManifest(
                    endpoint: "https://openrouter.ai/api/v1/embeddings",
                    providerID: providerID
                )
            )
            let provider = try #require(
                MemoryEmbedding.provider(manifest: manifest, environment: [:])
                    as? OpenAICompatibleEmbeddingProvider
            )
            let request = try provider.streamingRequest(for: "hello")
            #expect(
                RemoteHTTPHeaders(request.headers).firstValue(for: "Authorization")
                    == "Bearer embedding-secret"
            )
        }
    }

    // MARK: - OpenRouter embedding model catalog

    @Test
    func openRouterEmbeddingCatalogDecodesStringAndNumericPrices() throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id": "openai/text-embedding-3-small", "name": "OpenAI: Text Embedding 3 Small", "context_length": 8192, "pricing": {"prompt": "0.00000002"}},
                {"id": "qwen/qwen3-embedding-8b", "context_length": 40960, "pricing": {"prompt": 0.00000001}},
                {"id": "  ", "name": "blank id"},
                {"name": "missing id"}
              ]
            }
            """#.utf8
        )
        let models = try ZenCODESetupRunner.decodeOpenRouterEmbeddingModels(from: data)

        #expect(models.map(\.id) == ["openai/text-embedding-3-small", "qwen/qwen3-embedding-8b"])
        #expect(models[0].name == "OpenAI: Text Embedding 3 Small")
        #expect(models[0].contextLength == 8192)
        #expect(models[0].promptPricePerToken == 0.00000002)
        // A missing name falls back to the identifier.
        #expect(models[1].name == "qwen/qwen3-embedding-8b")
        #expect(models[1].promptPricePerToken == 0.00000001)

        #expect(throws: RemoteModelCatalogClientError.self) {
            _ = try ZenCODESetupRunner.decodeOpenRouterEmbeddingModels(from: Data("nope".utf8))
        }
    }

    @Test
    func openRouterEmbeddingCatalogUsesLiveModelsAndFallsBackWhenUnavailable() async {
        let live = await ZenCODESetupRunner.loadOpenRouterEmbeddingModels {
            [
                .init(id: "z/model", name: "Z", contextLength: nil, promptPricePerToken: nil),
                .init(id: "a/model", name: "A", contextLength: nil, promptPricePerToken: nil)
            ]
        }
        #expect(!live.isFallback)
        #expect(live.models.map(\.id) == ["a/model", "z/model"])

        struct Offline: Error {}
        let failed = await ZenCODESetupRunner.loadOpenRouterEmbeddingModels {
            throw Offline()
        }
        #expect(failed.isFallback)
        #expect(failed.models == ZenCODESetupRunner.openRouterEmbeddingModelsFallback)

        let empty = await ZenCODESetupRunner.loadOpenRouterEmbeddingModels { [] }
        #expect(empty.isFallback)
    }

    @Test
    func builtInEmbeddingCatalogIncludesOpenAIAndDefaultModels() {
        let ids = ZenCODESetupRunner.openRouterEmbeddingModelsFallback.map(\.id)

        #expect(ids.contains(AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel))
        #expect(ids.contains("openai/text-embedding-3-small"))
        #expect(ids.contains("openai/text-embedding-3-large"))
        #expect(ids.contains("openai/text-embedding-ada-002"))
        #expect(Set(ids).count == ids.count)
        #expect(ids == ids.sorted())
    }

    @Test
    func openRouterEmbeddingModelMenuPreselectsCurrentThenDefaultThenFirst() {
        let models: [ZenCODESetupRunner.MemoryEmbeddingModelOption] = [
            .init(id: "a/first", name: "First", contextLength: 512, promptPricePerToken: 0),
            .init(id: "openai/text-embedding-3-small", name: "Small", contextLength: 8192, promptPricePerToken: 0.00000002),
            .init(id: "qwen/qwen3-embedding-8b", name: "Qwen", contextLength: 40960, promptPricePerToken: 0.00000001)
        ]
        let defaultModel = "qwen/qwen3-embedding-8b"

        // Nothing configured: the preset default is preselected.
        let fresh = ZenCODESetupRunner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: nil,
            defaultModel: defaultModel
        )
        #expect(fresh.items.map(\.value) == models.map(\.id))
        #expect(fresh.defaultChoice == defaultModel)
        #expect(fresh.items[0].detail == "First · free · 512 input tokens")
        #expect(fresh.items[1].detail == "Small · $0.02/M tokens · 8192 input tokens")

        // The configured OpenRouter model is preselected.
        let current = ZenCODESetupRunner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://openrouter.ai/api/v1/embeddings",
                model: "openai/text-embedding-3-small",
                providerID: UUID()
            ),
            defaultModel: defaultModel
        )
        #expect(current.defaultChoice == "openai/text-embedding-3-small")

        // A model on a non-OpenRouter endpoint is not a preselection hint.
        let foreign = ZenCODESetupRunner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: AgentMemoryEmbeddingSettingsManifest(
                endpoint: "https://embeddings.example.test/v1/embeddings",
                model: "openai/text-embedding-3-small"
            ),
            defaultModel: defaultModel
        )
        #expect(foreign.defaultChoice == defaultModel)

        // Default not listed: the first model is preselected.
        let missingDefault = ZenCODESetupRunner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: nil,
            defaultModel: "missing/model"
        )
        #expect(missingDefault.defaultChoice == "a/first")

        let none = ZenCODESetupRunner.openRouterEmbeddingModelMenu(
            models: [],
            existingSettings: nil,
            defaultModel: defaultModel
        )
        #expect(none.defaultChoice == nil)
    }

    @Test
    func embeddingPriceFormatsPerMillionTokens() {
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(0.00000002) == "$0.02/M tokens")
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(0.00000013) == "$0.13/M tokens")
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(0.000000004) == "$0.004/M tokens")
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(0.000001) == "$1/M tokens")
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(0) == "free")
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(nil) == nil)
        #expect(ZenCODESetupRunner.formattedEmbeddingPrice(-1) == nil)
    }
}
