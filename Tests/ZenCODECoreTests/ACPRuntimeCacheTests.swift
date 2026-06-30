//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

extension ACPCompatibilityTests {
        @Test
    func runtimeCacheIsSavedOnCloseNotPerPrompt() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace"
        ])
        let sessionID = try #require(await bridge.sessionConfigurationsForTesting().first?.sessionID)

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "first prompt"
        ])
        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "second prompt"
        ])

        // Completing prompts must not persist the KV cache to disk.
        #expect(await backend.saveCount() == 0)

        try await bridge.close(id: nil, params: [
            "sessionId": sessionID
        ])

        // Closing the session must persist the KV cache exactly once.
        #expect(await backend.saveCount() == 1)
        #expect(await backend.savedSessionIDs() == [sessionID])
    }

    @Test
    func runtimeCacheIsSavedOnShutdownForOpenSessions() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace"
        ])
        let sessionID = try #require(await bridge.sessionConfigurationsForTesting().first?.sessionID)

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "first prompt"
        ])
        #expect(await backend.saveCount() == 0)

        // A client disconnecting (EOF) without session/close still persists.
        await bridge.shutdown()

        #expect(await backend.saveCount() == 1)
        #expect(await backend.savedSessionIDs() == [sessionID])
    }

    @Test
    func runtimeCacheIsRestoredOnResume() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace"
        ])
        let sessionID = try #require(await bridge.sessionConfigurationsForTesting().first?.sessionID)

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "first prompt"
        ])
        try await bridge.close(id: nil, params: [
            "sessionId": sessionID
        ])
        #expect(await backend.restoreCount() == 0)

        // Reconnecting and resuming the old session restores the disk cache,
        // so the next prompt can continue without re-running the prefill.
        try await bridge.resumeSession(id: nil, params: [
            "sessionId": sessionID,
            "cwd": "/tmp/acp-kv-cache-workspace"
        ])

                #expect(await backend.restoreCount() == 1)
        #expect(await backend.restoredSessionIDs() == [sessionID])
    }

    @Test
    func resumeWithoutSessionIDStillRestoresRuntimeCache() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        // No session_id: a stateless client resumes by resending its history.
        try await bridge.resumeSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace",
            "history": [
                ["role": "user", "content": "Hello"],
                ["role": "assistant", "content": "Hi"]
            ] as [[String: Any]]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        #expect(!configuration.sessionID.isEmpty)
        #expect(await backend.restoreCount() == 1)
        #expect(await backend.restoredSessionIDs() == [configuration.sessionID])
    }

    @Test
    func newSessionRestoresRuntimeCacheWhenHistoryIsProvided() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        // A stateless client that reconnects with session/new and resends the
        // transcript must still recover the KV cache from disk.
        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace",
            "history": [
                ["role": "user", "content": "Hello"],
                ["role": "assistant", "content": "Hi"]
            ] as [[String: Any]]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        #expect(await backend.restoreCount() == 1)
        #expect(await backend.restoredSessionIDs() == [configuration.sessionID])
    }

    @Test
    func newSessionDoesNotRestoreRuntimeCacheWithoutHistory() async throws {
        let backend = RuntimeCacheRecordingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-kv-cache-workspace"
        ])

        #expect(await backend.restoreCount() == 0)
    }
}
