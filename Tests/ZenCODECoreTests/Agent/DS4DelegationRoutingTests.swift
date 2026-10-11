//
//  DS4DelegationRoutingTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("DS4 delegation routing", .serialized)
struct DS4DelegationRoutingTests {
    @Test
    func nonDS4SelectionDoesNotBorrowRootSupervisorOrEndpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try AgentDS4RuntimeManifest(rootDirectory: root.path)
        let rootProvider = AgentRemoteProvider(
            name: "DS4 root",
            baseURL: "https://root-provider.invalid/v1",
            modelID: "ds4-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: runtime
        )
        let rootSelection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: rootProvider.modelID,
            remoteProvider: rootProvider,
            apiKey: nil,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
        let rootEndpoint = DS4ServerEndpoint(
            baseURL: URL(string: "http://127.0.0.1:43129/v1")!,
            modelsURL: URL(string: "http://127.0.0.1:43129/v1/models")!,
            host: "127.0.0.1",
            port: 43129,
            modelID: rootProvider.modelID
        )
        let missingExecutable = root.appendingPathComponent("missing-ds4")
        let supervisor = DS4ServerSupervisor(
            manifest: runtime,
            executableURL: missingExecutable,
            modelAlias: rootProvider.modelID,
            readinessTimeout: .milliseconds(100)
        )
        let rootClient = try #require(
            (try AgentRemoteBackendFactory.makeRemoteBackend(
                configuration: Self.configuration(root: root, modelID: rootProvider.modelID),
                mcpRuntime: DirectMCPToolRuntime(),
                resolvedModelSelection: rootSelection,
                ds4Supervisor: supervisor,
                ds4Endpoint: rootEndpoint
            )) as? RemoteGenerationClient
        )

        let executor = await rootClient.toolExecutor
        let subAgentRuntime = await executor.subAgentRuntime
        let factory = await subAgentRuntime.backendFactory

        let remoteProvider = AgentRemoteProvider(
            name: "Ordinary remote",
            baseURL: "https://ordinary-provider.invalid/v1",
            modelID: "remote-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyRequired
        )
        let remoteSelection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: remoteProvider.modelID,
            remoteProvider: remoteProvider,
            apiKey: "ordinary-remote-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
        let remoteContext = DirectSubAgentRuntime.BackendContext(
            requestedName: "ordinary-child",
            requestedRole: "worker",
            profile: nil,
            modelBinding: nil,
            modelSelection: remoteSelection,
            modelID: remoteSelection.modelID
        )
        let child = try #require(try factory(remoteContext) as? RemoteGenerationClient)

        #expect(await child.provider.id == remoteProvider.id)
        #expect(await child.provider.baseURL == remoteProvider.baseURL)
        #expect(await child.provider.modelID == remoteProvider.modelID)
        #expect(await child.apiKey == "ordinary-remote-key")
        #expect(await child.streamEndpointBaseURLOverride == nil)
        #expect(await child.usesLocalDS4Endpoint == false)
        #expect(await rootClient.streamEndpointBaseURLOverride == rootEndpoint.baseURL)

        await child.shutdown()
        // The borrower does not own the root supervisor: closing it leaves the
        // root's endpoint and supervisor lifecycle untouched.
        #expect(await rootClient.streamEndpointBaseURLOverride == rootEndpoint.baseURL)
        await #expect(throws: DS4ServerSupervisorError.executableNotFound(missingExecutable.path)) {
            try await supervisor.start()
        }

        await rootClient.shutdown()
        await #expect(throws: DS4ServerSupervisorError.shutdown) {
            try await supervisor.start()
        }
    }

    private static func configuration(root: URL, modelID: String) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: root,
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
    }
}
