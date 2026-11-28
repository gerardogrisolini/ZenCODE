//
//  ChatStatusModelTests.swift
//  ZenCODE
//
//  What a status bar shows of the model before the runtime reports its
//  context window (``ChatSessionController/statusModel()``): the provider's
//  model id, not the manifest's id, and the configured window with no tokens
//  used. The hosted models and the configured catalog resolve it by their own
//  paths, each over a throwaway support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@ChatSessionActor
@Suite("Chat status model", .timeLimit(.minutes(1)))
struct ChatStatusModelTests {
    private typealias Fixtures = ChatTestFixtures

    /// The window the status model configures for `modelID`.
    private static func initialWindow(
        _ modelID: String,
        maxTokens: Int
    ) -> DirectAgentContextWindowStatus {
        DirectAgentContextWindowStatus(
            usedTokens: nil,
            maxTokens: maxTokens,
            modelID: modelID,
            isApproximate: true
        )
    }

    /// A hosted model whose manifest id differs from its provider id.
    private static func hostedModel(limit: Int?) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: "status-hosted",
            kind: .remoteAPI,
            title: "Status Hosted",
            modelID: "provider/status-model",
            configuredContextWindowLimit: limit
        )
    }

    /// A model of the configured catalog whose manifest id differs from its
    /// provider id.
    private static func configuredModel(limit: Int?) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: "status-configured",
            kind: .remoteAPI,
            title: "Status Configured",
            modelID: "provider-status-model",
            provider: AgentRemoteProvider(
                name: "remote-server",
                baseURL: "http://127.0.0.1",
                modelID: "provider-status-model"
            ),
            configuredContextWindowLimit: limit
        )
    }

    // MARK: - Hosted models

    @Test
    func aHostedModelIsNamedByItsProviderIDWithItsConfiguredWindow() async throws {
        let model = Self.hostedModel(limit: 200_000)
        try await withChatHarness(catalog: .hosted(models: [model])) { harness in
            let status = harness.controller.statusModel()

            #expect(status.modelID == "provider/status-model")
            #expect(status.modelID != model.id)
            let window = try #require(status.contextWindow)
            #expect(window.usedTokens == nil)
            #expect(window.maxTokens == 200_000)
            #expect(window.modelID == "provider/status-model")
            #expect(window.isApproximate)
            #expect(status.contextWindow == Self.initialWindow("provider/status-model", maxTokens: 200_000))
        }
    }

    @Test
    func aHostedModelWithoutALimitHasNoWindow() async throws {
        try await withChatHarness(catalog: .hosted(models: [Self.hostedModel(limit: nil)])) { harness in
            let status = harness.controller.statusModel()

            #expect(status.modelID == "provider/status-model")
            #expect(status.contextWindow == nil)
        }
    }

    @Test
    func theModelChosenInTheSessionIsTheOneShown() async throws {
        let other = AgentSettingsModelManifest(
            id: "status-other",
            kind: .remoteAPI,
            modelID: "provider/other-model",
            configuredContextWindowLimit: 64_000
        )
        try await withChatHarness(
            catalog: .hosted(models: [Self.hostedModel(limit: 200_000), other])
        ) { harness in
            let controller = harness.controller
            #expect(controller.statusModel().modelID == "provider/status-model")

            controller.selection.modelIDOverride = other.id

            let status = controller.statusModel()
            #expect(status.modelID == "provider/other-model")
            #expect(status.contextWindow == Self.initialWindow("provider/other-model", maxTokens: 64_000))
        }
    }

    // MARK: - Configured catalog

    @Test
    func aConfiguredModelIsNamedByItsProviderIDWithItsConfiguredWindow() async throws {
        let model = Self.configuredModel(limit: 1_048_576)
        try await withChatHarness(
            catalog: .configured(models: [model], selectedModelID: model.id)
        ) { harness in
            let status = harness.controller.statusModel()

            #expect(status.modelID == "provider-status-model")
            #expect(status.modelID != model.id)
            let window = try #require(status.contextWindow)
            #expect(window.usedTokens == nil)
            #expect(window.maxTokens == 1_048_576)
            #expect(window.modelID == "provider-status-model")
            #expect(window.isApproximate)
        }
    }

    @Test
    func aConfiguredModelWithoutALimitHasNoWindow() async throws {
        let model = Self.configuredModel(limit: nil)
        try await withChatHarness(
            catalog: .configured(models: [model], selectedModelID: model.id)
        ) { harness in
            let status = harness.controller.statusModel()

            #expect(status.modelID == "provider-status-model")
            #expect(status.contextWindow == nil)
        }
    }
}
