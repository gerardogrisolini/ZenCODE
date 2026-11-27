//
//  ChatSessionRuntimeFactoryTests.swift
//  ZenCODE
//
//  The public construction point of the session runtime: the production
//  backend and the session runner every channel builds.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Chat session runtime factory")
struct ChatSessionRuntimeFactoryTests {
    @Test("The production factory builds the remote backend of the configured model without the network")
    func productionFactoryBuildsTheRemoteBackend() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatSessionRuntimeFactoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let backend = try AppStorageDirectory.withSupportDirectoryURL(support) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(models: [
                AgentSettingsModelManifest(
                    id: "factory-model",
                    kind: .remoteAPI,
                    modelID: "factory-model",
                    provider: AgentRemoteProvider(
                        name: "Factory test",
                        baseURL: "https://example.invalid/v1",
                        modelID: "factory-model",
                        chatEndpoint: .chatCompletions,
                        providerProfileID: .openAI,
                        protocolProfileID: .openAIChatCompletions,
                        authPolicy: .noAuthentication
                    )
                ),
            ]))
            let configuration = AgentRuntimeConfiguration(
                modelID: nil,
                workingDirectory: support,
                maxToolRounds: 1,
                toolAuthorizationHandler: nil
            )
            return try ChatSessionRuntimeFactory.productionBackendFactory(
                configuration,
                DirectMCPToolRuntime()
            )
        }

        #expect(backend is RemoteGenerationClient)
    }

    @Test("The production factory hands the session feature runtime of the configuration to the remote client")
    func productionFactoryForwardsTheSessionFeatureRuntime() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatSessionRuntimeFactoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let sessionRuntime = SwiftFeatureRuntime()

        let backend = try AppStorageDirectory.withSupportDirectoryURL(support) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(models: [
                AgentSettingsModelManifest(
                    id: "factory-model",
                    kind: .remoteAPI,
                    modelID: "factory-model",
                    provider: AgentRemoteProvider(
                        name: "Factory test",
                        baseURL: "https://example.invalid/v1",
                        modelID: "factory-model",
                        chatEndpoint: .chatCompletions,
                        providerProfileID: .openAI,
                        protocolProfileID: .openAIChatCompletions,
                        authPolicy: .noAuthentication
                    )
                ),
            ]))
            let configuration = AgentRuntimeConfiguration(
                modelID: nil,
                workingDirectory: support,
                maxToolRounds: 1,
                toolAuthorizationHandler: nil
            ).withSwiftFeatureRuntime(sessionRuntime)
            return try ChatSessionRuntimeFactory.productionBackendFactory(
                configuration,
                DirectMCPToolRuntime()
            )
        }

        let client = try #require(backend as? RemoteGenerationClient)
        let toolExecutor = await client.toolExecutor
        let executorRuntime = await toolExecutor.swiftFeatureRuntime
        #expect(executorRuntime === sessionRuntime)
    }
}
