//
//  AgentDelegationLiveCatalogTests.swift
//  ZenCODE
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension AgentProfileBindingReconcilerTests {
    @Test
    func liveSnapshotDistinguishesMissingInvalidAndAuthoritativeEmptySettings() throws {
        try Self.withLiveCatalogTemporarySupportDirectory { directory in
            let missing = AgentDelegationCatalog.liveSnapshot()
            #expect(!missing.isAvailable)
            #expect(missing.unavailableReason?.contains("not configured") == true)

            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            try Data("not-json".utf8).write(to: settingsURL)
            let invalid = AgentDelegationCatalog.liveSnapshot()
            #expect(!invalid.isAvailable)
            #expect(invalid.unavailableReason?.contains("could not be loaded") == true)

            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: []),
                to: settingsURL
            )
            let empty = AgentDelegationCatalog.liveSnapshot()
            #expect(empty.isAvailable)
            #expect(empty.models.isEmpty)
        }
    }

    @Test
    func publicRuntimeDefaultFailsClosedWhenSettingsAreUnavailable() async throws {
        try await Self.withLiveCatalogTemporarySupportDirectory { _ in
            let profile = AgentProfile(
                id: "developer",
                name: "Developer",
                modelBindings: [
                    AgentModelBinding(id: "bound", modelID: "missing-model", capability: 5)
                ]
            )
            let backend = LiveCatalogProbeBackend()
            let runtime = DirectSubAgentRuntime(
                contextualBackendFactory: { _ in backend },
                profileResolver: { payload in
                    DirectSubAgentRuntime.agentProfile(matching: payload, in: [profile])
                }
            )

            do {
                _ = try await runtime.createAgents(
                    arguments: [
                        "agents": .array([
                            .object([
                                "profile": .string("Developer"),
                                "model": .string("binding:bound"),
                            ]),
                        ]),
                    ],
                    workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                    parentAllowedToolNames: nil
                )
                Issue.record("Expected the default live catalog provider to fail closed.")
            } catch let DirectSubAgentRuntimeError.modelBindingUnavailable(_, _, reason) {
                #expect(reason.contains("settings.json is not configured"))
            }

            #expect(await backend.createdSessionCount == 0)
            await runtime.shutdown()
        }
    }

    @Test
    func publicRuntimeProfileResolverFailsClosedWhenAgentsManifestIsMissing() async throws {
        try await Self.withLiveCatalogTemporarySupportDirectory { _ in
            let backend = LiveCatalogProbeBackend()
            let runtime = DirectSubAgentRuntime(
                contextualBackendFactory: { _ in backend }
            )

            do {
                _ = try await runtime.createAgents(
                    arguments: [
                        "agents": .array([
                            .object([
                                "profile": .string("Developer"),
                                "model": .string("binding:any"),
                            ]),
                        ]),
                    ],
                    workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                    parentAllowedToolNames: nil
                )
                Issue.record("Expected the public profile resolver default to fail closed.")
            } catch let DirectSubAgentRuntimeError.agentProfileNotFound(reference) {
                #expect(reference == "Developer")
            }

            #expect(await backend.createdSessionCount == 0)
            await runtime.shutdown()
        }
    }

    @Test
    func persistedAmbiguousProfileReferencesAreRejected() throws {
        try Self.withLiveCatalogTemporarySupportDirectory { directory in
            let profiles = [
                AgentProfile(id: "first", name: "Shared"),
                AgentProfile(id: "second", name: "Shared"),
            ]
            #expect(throws: AgentProfileStoreError.self) {
                try AgentProfileStore.save(profiles)
            }

            let data = try JSONEncoder().encode(AgentProfileManifest(agents: profiles))
            let url = directory.appendingPathComponent(AgentProfileStore.manifestFilename)
            try SensitiveFilePermissions.write(data, to: url)
            #expect(throws: AgentProfileStoreError.self) {
                try AgentProfileStore.loadRequired()
            }
        }
    }

    @Test
    func legacyDefaultProfileResolverStillUsesPersistedProfiles() throws {
        try Self.withLiveCatalogTemporarySupportDirectory { _ in
            try AgentProfileStore.save([
                AgentProfile(id: "persisted", name: "Persisted")
            ])
            let payload = DirectSubAgentRuntime.RequestedAgentPayload(
                name: "child",
                role: "role",
                profileReference: "Persisted"
            )

            #expect(
                DirectSubAgentRuntime.defaultProfileResolver(for: payload)?.id
                    == "persisted"
            )
        }
    }

    private static func withLiveCatalogTemporarySupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-live-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AppStorageDirectory.withSupportDirectoryURL(directory) {
            try body(directory)
        }
    }

    private static func withLiveCatalogTemporarySupportDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-live-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try await body(directory)
        }
    }
}

private actor LiveCatalogProbeBackend: AgentRuntimeBackend {
    private(set) var createdSessionCount = 0

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) async {}
    func updateToolProviders(_ providers: [AgentToolProvider], sessionID: String?) async {}
    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) { createdSessionCount += 1 }
    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) { createdSessionCount += 1 }
    func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String { "live-catalog-probe" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "ok", stopReason: "stop", modelID: "probe")
    }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { nil }
}
