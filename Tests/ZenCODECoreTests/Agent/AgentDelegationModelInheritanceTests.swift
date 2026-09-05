//
//  AgentDelegationModelInheritanceTests.swift
//  ZenCODE
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension AgentDelegationRoutingTests {
    @Test(arguments: [false, true])
    func delegatedBackendInheritsTheSelectedProviderUnlessExplicitlyBound(hasBinding: Bool) async throws {
        let selectedProvider = try #require(Self.betaModel.provider)
        let configuration = AgentRuntimeConfiguration(
            modelID: Self.betaModelID,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let rootBackend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: Self.sharedSlug,
                remoteProvider: selectedProvider,
                apiKey: "beta-key",
                configuredContextWindowLimit: 16_384,
                generationParameterOverrides: nil,
                thinkingOptions: [.low, .high],
                thinkingSelection: nil
            )
        )
        let rootClient = try #require(rootBackend as? RemoteGenerationClient)
        let executor = await rootClient.toolExecutor
        let runtime = await executor.subAgentRuntime
        let factory = await runtime.backendFactory
        let profile = Self.profile(bindings: hasBinding ? [
            AgentModelBinding(id: "alpha", modelID: Self.alphaModelID, capability: 5)
        ] : [])
        let snapshot: AgentDelegationCatalogSnapshot = hasBinding
            ? .available(AgentSettingsManifest(
                models: [Self.alphaModel],
                remoteAPIKeysByProviderID: [
                    Self.alphaProviderID.uuidString.lowercased(): "alpha-key"
                ]
            ))
            : .unavailable("the live catalog is no longer available")
        let payload = try DirectSubAgentRuntime.resolvingModelBinding(
            for: DirectSubAgentRuntime.RequestedAgentPayload(
                name: "worker",
                role: "worker",
                profileReference: profile.displayName,
                modelID: hasBinding ? "binding:alpha" : nil
            ),
            profile: profile,
            snapshot: snapshot
        )
        let childBackend = try factory(DirectSubAgentRuntime.backendContext(
            for: payload,
            profile: profile
        ))
        let childClient = try #require(childBackend as? RemoteGenerationClient)

        let childProvider = await childClient.provider
        let childConfiguration = await childClient.configuration
        #expect(childProvider.id == (hasBinding ? Self.alphaProviderID : Self.betaProviderID))
        #expect(childProvider.modelID == Self.sharedSlug)
        #expect(childProvider.baseURL == (hasBinding ? Self.alphaModel.provider?.baseURL : selectedProvider.baseURL))
        #expect(await childClient.apiKey == (hasBinding ? "alpha-key" : "beta-key"))
        #expect(childConfiguration.modelID == Self.sharedSlug)
        #expect(childConfiguration.configuredContextWindowLimit == (hasBinding ? nil : 16_384))
        if !hasBinding {
            #expect(await childClient.thinkingOptions == [.low, .high])
        }

        await childClient.shutdown()
        await rootClient.shutdown()
    }

    @Test
    func unboundProfileCannotSelectAnArbitraryModel() {
        let profile = Self.profile(bindings: [])
        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.resolvingModelBinding(
                for: DirectSubAgentRuntime.RequestedAgentPayload(
                    name: "worker",
                    role: "worker",
                    profileReference: profile.displayName,
                    modelID: "binding:beta"
                ),
                profile: profile,
                snapshot: .available(models: [Self.betaModel])
            )
        }
    }
}
