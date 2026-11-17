//
//  LeasedSessionRuntimeBackendTests.swift
//  ZenCODE
//
//  The session lookups the three direct-tool clients share through
//  `LeasedSessionRuntimeBackend`, reached as the runner reaches them: through
//  `any AgentRuntimeBackend`.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct LeasedSessionRuntimeBackendTests {
    @Test(arguments: ClientKind.allCases)
    func sessionLookupsAnswerForTheSessionAndItsAllowedTools(kind: ClientKind) async throws {
        try await Self.withTemporarySupportDirectory { workspace in
            let backend = Self.makeBackend(kind, workspace: workspace)
            let runtime: any AgentRuntimeBackend = backend

            // No session: no descriptors, whichever the id.
            #expect(await runtime.activeToolDescriptors(sessionID: "session").isEmpty)
            #expect(await runtime.knownToolDescriptors(sessionID: nil).isEmpty)

            await runtime.createSessionIfNeeded(
                id: "session",
                cwd: workspace.path,
                systemPrompt: "First prompt.",
                history: [],
                cacheKey: nil,
                allowedToolNames: ["local.readFile"],
                thinkingSelection: nil,
                preserveThinking: false
            )
            // A second call keeps the session it found.
            await runtime.createSessionIfNeeded(
                id: "session",
                cwd: workspace.path,
                systemPrompt: "Second prompt.",
                history: [],
                cacheKey: nil,
                allowedToolNames: ["local.exec"],
                thinkingSelection: nil,
                preserveThinking: false
            )
            #expect(await runtime.snapshotSession(id: "session")?.allowedToolNames == ["local.readFile"])

            let known = await runtime.knownToolDescriptors(sessionID: "session").map(\.name)
            let active = await runtime.activeToolDescriptors(sessionID: "session").map(\.name)
            let anySession = await runtime.knownToolDescriptors(sessionID: nil).map(\.name)
            // The session's allowlist decides: its tool is listed, the one
            // of the call that found the session is not.
            #expect(known.contains("local.readFile"))
            #expect(!known.contains("local.exec"))
            #expect(active == known)
            #expect(anySession == known)
            #expect(await runtime.activeToolDescriptors(sessionID: "other").isEmpty)

            await Self.shutdown(backend)
        }
    }

    @Test(arguments: ClientKind.allCases)
    func aLeaseReachesOnlyTheIncarnationItWasTakenFor(kind: ClientKind) async throws {
        try await Self.withTemporarySupportDirectory { workspace in
            let backend = Self.makeBackend(kind, workspace: workspace)
            try await Self.checkLeases(of: backend, workspace: workspace)
            await Self.shutdown(backend)
        }
    }

    // MARK: - Support

    enum ClientKind: CaseIterable, Sendable {
        case remote
        case anthropicSubscription
        case chatGPTSubscription
    }

    private static func makeBackend(_ kind: ClientKind, workspace: URL) -> any AgentRuntimeBackend {
        let configuration = AgentRuntimeConfiguration(
            modelID: "unit-model",
            workingDirectory: workspace,
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
        switch kind {
        case .remote:
            return RemoteGenerationClient(
                configuration: configuration,
                provider: AgentRemoteProvider(
                    name: "Unit Test",
                    baseURL: "https://unit.test/v1",
                    modelID: "unit-model",
                    chatEndpoint: .responses
                ),
                apiKey: nil
            )
        case .anthropicSubscription:
            return AnthropicSubscriptionGenerationClient(
                configuration: configuration,
                provider: AgentRemoteProvider(
                    name: "Anthropic Subscription",
                    baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                    modelID: "unit-model",
                    chatEndpoint: .responses
                )
            )
        case .chatGPTSubscription:
            return ChatGPTSubscriptionGenerationClient(configuration: configuration)
        }
    }

    private static func checkLeases(of backend: any AgentRuntimeBackend, workspace: URL) async throws {
        switch backend {
        case let client as RemoteGenerationClient:
            try await checkLeasesOfClient(client, workspace: workspace)
        case let client as AnthropicSubscriptionGenerationClient:
            try await checkLeasesOfClient(client, workspace: workspace)
        case let client as ChatGPTSubscriptionGenerationClient:
            try await checkLeasesOfClient(client, workspace: workspace)
        default:
            Issue.record("Unexpected backend \(type(of: backend))")
        }
    }

    private static func checkLeasesOfClient<Client: LeasedSessionRuntimeBackend>(
        _ client: Client,
        workspace: URL
    ) async throws {
        await client.createSessionIfNeeded(id: "session", cwd: workspace.path, allowedToolNames: ["local.readFile"])
        let lease = try #require(await client.sessionLease(for: "session"))
        #expect(await client.sessionLease(for: "missing") == nil)

        let mutated = await client.mutateSession(for: lease) { $0.allowedToolNames = ["local.exec"] }
        #expect(mutated)
        #expect(await client.snapshotSession(id: "session")?.allowedToolNames == ["local.exec"])

        // Closing and recreating the id installs a new incarnation: the old
        // lease reaches nothing and changes nothing.
        await client.closeSession(id: "session")
        await client.createSessionIfNeeded(id: "session", cwd: workspace.path, allowedToolNames: ["local.readFile"])
        let staleMutation = await client.mutateSession(for: lease) { $0.allowedToolNames = ["local.exec"] }
        #expect(!staleMutation)
        #expect(await client.snapshotSession(id: "session")?.allowedToolNames == ["local.readFile"])
        let renewed = try #require(await client.sessionLease(for: "session"))
        #expect(renewed.generation != lease.generation)
        let renewedMutation = await client.mutateSession(for: renewed) { $0.allowedToolNames = nil }
        #expect(renewedMutation)
        #expect(await client.snapshotSession(id: "session")?.allowedToolNames == nil)
    }

    private static func shutdown(_ backend: any AgentRuntimeBackend) async {
        switch backend {
        case let client as AnthropicSubscriptionGenerationClient:
            await client.shutdown()
        case let client as ChatGPTSubscriptionGenerationClient:
            await client.shutdown()
        default:
            break
        }
    }

    /// Runs `body` with a throwaway support directory and workspace.
    private static func withTemporarySupportDirectory(
        _ body: @Sendable (_ workspace: URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leased-session-backend-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [support, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(workspace)
        }
    }
}
