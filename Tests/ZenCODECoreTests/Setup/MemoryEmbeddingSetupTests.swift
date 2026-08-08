//
//  MemoryEmbeddingSetupTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing
import ZenMemory

@Suite("Memory embedding setup")
struct MemoryEmbeddingSetupTests {
    @Test
    func settingsManifestDecodesV10AndRoundTripsV11EndpointOnlyConfiguration() throws {
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

        #expect(json["version"] as? Int == 11)
        #expect(Set(embedding.keys) == Set(["endpoint"]))
        #expect(embedding["endpoint"] as? String == "https://embeddings.example.test/v1/embeddings")
        #expect(embedding["model"] == nil)
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
    func memoryEmbeddingSetupSectionIsOptionalAndAvailableWithoutModels() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        #expect(options.contains { $0.section == .memoryEmbedding })
        #expect(!SetupSection.memoryEmbedding.requiresConfiguredModels)
        #expect(SetupSection.memoryEmbedding.category == .optional)
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
}
