//
//  RemoteGenerationClientDS4Tests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("RemoteGenerationClient DS4 integration", .serialized)
struct RemoteGenerationClientDS4Tests {
    @Test
    func injectedEndpointIsUsedWithoutStartingAProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-client-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = Self.provider()
        let endpoint = DS4ServerEndpoint(
            baseURL: URL(string: "http://127.0.0.1:43127/v1")!,
            modelsURL: URL(string: "http://127.0.0.1:43127/v1/models")!,
            host: "127.0.0.1",
            port: 43127,
            modelID: provider.modelID
        )
        let client = RemoteGenerationClient(
            configuration: Self.configuration(root: root, modelID: provider.modelID),
            provider: provider,
            apiKey: nil,
            ds4Endpoint: endpoint
        )

        #expect(await client.ds4Endpoint == endpoint)
        #expect(await client.streamEndpointBaseURLOverride == endpoint.baseURL)
        let loadedModel = try await client.preloadModel(onEvent: { _ in })
        #expect(loadedModel == provider.modelID)
        #expect(await client.streamEndpointBaseURLOverride == endpoint.baseURL)
        await client.shutdown()
    }

    @Test
    func endpointOnlyClientIsFencedAfterShutdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-endpoint-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = Self.provider()
        let endpoint = DS4ServerEndpoint(
            baseURL: URL(string: "http://127.0.0.1:43127/v1")!,
            modelsURL: URL(string: "http://127.0.0.1:43127/v1/models")!,
            host: "127.0.0.1",
            port: 43127,
            modelID: provider.modelID
        )
        let client = RemoteGenerationClient(
            configuration: Self.configuration(root: root, modelID: provider.modelID),
            provider: provider,
            apiKey: nil,
            ds4Endpoint: endpoint
        )

        await client.shutdown()
        #expect(await client.streamEndpointBaseURLOverride == nil)
        #expect(await client.ds4Endpoint == nil)
        await #expect(throws: DS4ServerSupervisorError.shutdown) {
            try await client.preloadModel(onEvent: { _ in })
        }
        await #expect(throws: DS4ServerSupervisorError.shutdown) {
            try await client.streamRequest(
                path: "chat/completions",
                body: [:],
                onEvent: { _ in },
                eventParser: { _ in [] }
            )
        }
    }

    @Test
    func localDS4SuppressesPersistedCredentialsButRemoteKeepsBearer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-credential-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try AgentDS4RuntimeManifest(rootDirectory: root.path)
        let provider = AgentRemoteProvider(
            name: "DS4 credential fixture",
            baseURL: "https://provider.invalid/v1",
            modelID: "fixture-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyRequired,
            ds4Runtime: runtime
        )
        let loopback = URL(string: "http://127.0.0.1:43127/v1")!
        let local = try RemoteStreamTransport.streamRequestComponents(
            path: "chat/completions",
            body: [:],
            provider: provider,
            apiKey: "must-not-cross-loopback",
            endpointBaseURLOverride: loopback,
            suppressAPIKey: true
        )
        #expect(local.headers.contains { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame } == false)
        #expect(local.headers.contains { $0.name.caseInsensitiveCompare("x-api-key") == .orderedSame } == false)

        let remote = try RemoteStreamTransport.streamRequestComponents(
            path: "chat/completions",
            body: [:],
            provider: provider,
            apiKey: "remote-secret"
        )
        #expect(remote.headers.first(where: {
            $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
        })?.value == "Bearer remote-secret")

        // A required remote auth policy is still valid for a local DS4 client:
        // validation must not reject it merely because no key is supplied.
        let endpoint = DS4ServerEndpoint(
            baseURL: loopback,
            modelsURL: loopback.appendingPathComponent("models"),
            host: "127.0.0.1",
            port: 43127,
            modelID: provider.modelID
        )
        let client = RemoteGenerationClient(
            configuration: Self.configuration(root: root, modelID: provider.modelID),
            provider: provider,
            apiKey: nil,
            ds4Endpoint: endpoint
        )
        _ = try await client.preloadModel(onEvent: { _ in })
        await client.shutdown()
    }

    @Test
    func factoryOwnedSupervisorStartsLazilyAndIsStoppedByBackendShutdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-client-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try AgentDS4RuntimeManifest(rootDirectory: root.path)
        let missingExecutable = root.appendingPathComponent("missing-ds4")
        let supervisor = DS4ServerSupervisor(
            manifest: manifest,
            executableURL: missingExecutable,
            modelAlias: "fixture-model",
            readinessTimeout: .milliseconds(250)
        )
        let provider = Self.provider(modelID: "fixture-model")
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: Self.configuration(root: root, modelID: provider.modelID),
            mcpRuntime: DirectMCPToolRuntime(),
            fallbackProvider: provider,
            ds4Supervisor: supervisor
        )
        let client = try #require(backend as? RemoteGenerationClient)

        #expect(!(await supervisor.isRunning))
        await #expect(throws: DS4ServerSupervisorError.executableNotFound(missingExecutable.path)) {
            try await client.preloadModel(onEvent: { _ in })
        }
        #expect(!(await supervisor.isRunning))

        await client.shutdown()
        await #expect(throws: DS4ServerSupervisorError.shutdown) {
            try await supervisor.start()
        }
    }

    private static func provider(modelID: String = "fixture-model") -> AgentRemoteProvider {
        AgentRemoteProvider(
            name: "DS4 fixture",
            baseURL: "https://provider.invalid/v1",
            modelID: modelID,
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication
        )
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
