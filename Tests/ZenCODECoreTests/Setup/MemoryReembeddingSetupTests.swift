//
//  MemoryReembeddingSetupTests.swift
//  ZenCODECoreTests
//
//  The pure parts of the memory re-embedding offered by setup and by Data
//  management › Rebuild memory embeddings: the trigger, the list, the
//  progress line and the summary. No terminal, no network, no real graph.
//

import Foundation
import Testing
@testable import ZenCODECore

private struct NamedEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    func embed(_ text: String) async throws -> [Float] { [1] }
}

@Suite
struct MemoryReembeddingSetupTests {
    private typealias Runner = ZenCODESetupRunner

    private static let endpoint = "https://embeddings.example.test/v1/embeddings"

    private static func manifest(_ settings: AgentMemoryEmbeddingSettingsManifest?) -> AgentSettingsManifest {
        AgentSettingsManifest(models: [], memoryEmbedding: settings)
    }

    private static func settings(model: String?) -> AgentMemoryEmbeddingSettingsManifest {
        AgentMemoryEmbeddingSettingsManifest(endpoint: endpoint, model: model)
    }

    // MARK: - Trigger

    @Test
    func reembeddingIsOfferedOnlyAfterACompletedSetupThatChangedTheModel() throws {
        let previous = Self.settings(model: "qwen/qwen3-embedding-8b")
        let next = Self.settings(model: "qwen/qwen3-embedding-4b")

        let offered = try #require(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: previous,
            finalManifest: Self.manifest(next),
            environment: [:]
        ))
        #expect(offered.modelID == "qwen/qwen3-embedding-4b")

        // Cancelled, reset or replaced: no graph is touched.
        for outcome in [SetupOutcome.cancelled, .reset, .dataReplaced] {
            #expect(Runner.memoryReembeddingProvider(
                setupOutcome: outcome,
                originalSettings: previous,
                finalManifest: Self.manifest(next),
                environment: [:]
            ) == nil)
        }
        // Unchanged configuration.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: next,
            finalManifest: Self.manifest(next),
            environment: [:]
        ) == nil)
        // Switching to BM25 resolves no provider, even with the legacy variable set.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: next,
            finalManifest: Self.manifest(.disabled),
            environment: [MemoryEmbedding.environmentEndpointKey: Self.endpoint]
        ) == nil)
        // Enabling embeddings for the first time is a change too.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: .disabled,
            finalManifest: Self.manifest(next),
            environment: [:]
        )?.modelID == "qwen/qwen3-embedding-4b")
    }

    @Test
    func modelDescriptionNeverShowsTheEndpointURL() {
        let withModel = OpenAICompatibleEmbeddingProvider(
            endpoint: URL(string: "https://openrouter.ai/api/v1/embeddings")!,
            model: "qwen/qwen3-embedding-4b"
        )
        #expect(Runner.memoryReembeddingModelDescription(withModel) == "qwen/qwen3-embedding-4b")

        let endpointOnly = OpenAICompatibleEmbeddingProvider(
            endpoint: URL(string: "https://embeddings.example.test/v1/embeddings?token=secret-token")!
        )
        let description = Runner.memoryReembeddingModelDescription(endpointOnly)
        #expect(description == "the default model of embeddings.example.test")
        #expect(!description.contains("secret-token"))

        #expect(Runner.memoryReembeddingModelDescription(NamedEmbeddingProvider(modelID: "local-model")) == "local-model")
    }

    // MARK: - Default model

    @Test
    func openRouterProposalDefaultsToTheFourBillionModel() throws {
        #expect(AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel == "qwen/qwen3-embedding-4b")
        let ids = Runner.openRouterEmbeddingModelsFallback.map(\.id)
        #expect(ids.contains("qwen/qwen3-embedding-4b"))
        #expect(ids.contains("qwen/qwen3-embedding-8b"))

        let models: [Runner.MemoryEmbeddingModelOption] = [
            .init(id: "qwen/qwen3-embedding-4b", name: "Qwen 4B", contextLength: 32_768, promptPricePerToken: 0.00000002),
            .init(id: "qwen/qwen3-embedding-8b", name: "Qwen 8B", contextLength: 40_960, promptPricePerToken: 0.00000001),
        ]
        let fresh = Runner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: nil,
            defaultModel: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel
        )
        #expect(fresh.defaultChoice == "qwen/qwen3-embedding-4b")

        // An 8B already saved stays the preselected model.
        let configured = Runner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: AgentMemoryEmbeddingSettingsManifest(
                endpoint: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsEndpoint,
                model: "qwen/qwen3-embedding-8b",
                providerID: "openrouter"
            ),
            defaultModel: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel
        )
        #expect(configured.defaultChoice == "qwen/qwen3-embedding-8b")
    }
}
