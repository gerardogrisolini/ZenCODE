//
//  PersistedContractCompatibilityTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite("Persisted contract compatibility")
struct PersistedContractCompatibilityTests {
    @Test
    func settingsProfileAndPermissionsFixturesRemainReadable() throws {
        let settings = try decode(
            AgentSettingsManifest.self,
            from: #"""
            {
              "version": 10,
              "providers": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "Example Remote",
                "baseURL": "https://example.test/v1/",
                "chatEndpoint": "responses"
              }],
              "models": [{
                "id": "example/model",
                "kind": "remoteAPI",
                "title": "Example Model",
                "llmID": "example/model-v1",
                "modelID": "example/model",
                "providerID": "11111111-1111-1111-1111-111111111111",
                "context": { "configuredWindowLimit": 32768 },
                "thinking": { "options": ["off", "high"], "default": "high" }
              }],
              "selected": { "modelID": "example/model-v1", "thinking": "high" },
              "remoteAPIKeysByProviderID": {
                "11111111-1111-1111-1111-111111111111": "test-token"
              },
              "localExecAllowedCommands": ["swift", "git"]
            }
            """#
        )
        let profiles = try decode(
            AgentProfileManifest.self,
            from: #"""
            {
              "version": 1,
              "agents": [{
                "id": "reviewer",
                "name": "Reviewer",
                "instructions": "Review changes only.",
                "symbolName": "eye",
                "tools": ["files", "git"],
                "skills": [{
                  "id": "review-skill",
                  "canonicalName": "review",
                  "title": "Review",
                  "summary": "Inspect proposed changes.",
                  "symbolName": "checkmark"
                }],
                "modelID": "example/model",
                "modelProvider": "Example Remote",
                "thinkingSelection": "high"
              }]
            }
            """#
        )
        let permissions = try decode(
            AgentPermissionsManifest.self,
            from: #"""
            {
              "version": 1,
              "localExecAllowedCommands": ["swift test --filter Focused", "git status"]
            }
            """#
        )

        #expect(settings.selectedModelID == "example/model")
        #expect(settings.selectedThinkingSelection == .high)
        #expect(settings.providers.first?.baseURL == "https://example.test/v1")
        #expect(settings.models.first?.configuredContextWindowLimit == 32_768)
        #expect(settings.models.first?.defaultThinkingSelection == .high)
        #expect(settings.remoteAPIKeysByProviderID.count == 1)
        #expect(settings.localExecAllowedCommands == ["swift", "git"])
        #expect(profiles.agents.first?.skills.first?.canonicalName == "review")
        #expect(profiles.agents.first?.thinkingSelection == .high)
        #expect(permissions.localExecAllowedCommands == ["swift test --filter Focused", "git status"])

        let reloadedSettings = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(settings)
        )
        let reloadedProfiles = try JSONDecoder().decode(
            AgentProfileManifest.self,
            from: JSONEncoder().encode(profiles)
        )
        let reloadedPermissions = try JSONDecoder().decode(
            AgentPermissionsManifest.self,
            from: JSONEncoder().encode(permissions)
        )
        #expect(reloadedSettings.selectedModelID == settings.selectedModelID)
        #expect(reloadedSettings.selectedThinkingSelection == settings.selectedThinkingSelection)
        #expect(reloadedSettings.models == settings.models)
        #expect(reloadedSettings.remoteAPIKeysByProviderID == settings.remoteAPIKeysByProviderID)
        #expect(reloadedProfiles.agents == profiles.agents)
        #expect(reloadedPermissions == permissions)
    }

    @Test
    func savedSessionSnapshotRoundTripsPersistedTranscriptAndPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let session = TerminalSavedSession(
            name: "Compatibility snapshot",
            sessionID: "session-compatibility",
            cacheKey: "cache-compatibility",
            workingDirectoryPath: workingDirectory.path,
            createdAt: date,
            savedAt: date,
            modelID: "example/model",
            agentID: "reviewer",
            agentName: "Reviewer",
            selectedTools: ["files", "git"],
            selectedSkillIDs: ["review-skill"],
            thinkingSelection: "high",
            contextWindow: TerminalSavedSessionContextWindow(
                usedTokens: 120,
                maxTokens: 1_024,
                modelID: "example/model",
                isApproximate: false
            ),
            systemPrompt: "Review the implementation.",
            history: [
                AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
            ],
            transcriptHistory: [
                AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
            ],
            activePlan: TerminalSessionPlan(
                originalGoal: "Review the implementation",
                consolidatedText: "1. Inspect\n2. Report",
                createdAt: date,
                isApproved: true,
                points: [
                    TerminalSessionPlanPoint(id: "1", text: "Inspect", status: .completed),
                    TerminalSessionPlanPoint(id: "2", text: "Report", status: .inProgress)
                ]
            ),
            checkpointTree: SessionCheckpointTree.fromLinearHistory(
                [
                    AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                    AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
                ],
                sessionID: "persisted-contract"
            )
        )

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: root.appendingPathComponent("storage", isDirectory: true)
        )
        let restored = try TerminalSessionStore.load(from: fileURL)

        #expect(restored == session)
        #expect(restored.displayHistory == session.transcriptHistory)
        #expect(restored.activePlan?.points.map(\.status) == [.completed, .inProgress])
        #expect(restored.contextWindow?.runtimeStatus?.maxTokens == 1_024)
    }

    @Test
    func featureManifestDescriptorEnvelopeSupportsEstablishedAliasesAndRoundTrips() throws {
        let manifest = try decode(
            SwiftFeatureManifest.self,
            from: #"""
            {
              "schema_version": 1,
              "id": "example-feature",
              "name": "Example Feature",
              "description": "A representative generated feature.",
              "binary": "example-feature",
              "enabled": true,
              "tools": [{
                "name": "example.echo",
                "title": "Echo",
                "description": "Returns the supplied text.",
                "input_schema": "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                "output_schema": "{\"type\":\"string\"}"
              }],
              "tool_name_prefixes": ["example.", "example."],
              "tool_name_aliases": ["example.run", "example.run"],
              "discovers_tools_at_runtime": true,
              "invocation_timeout_seconds": 30,
              "build": {
                "system": "swiftpm",
                "package_path": ".",
                "product": "example-feature",
                "configuration": "release",
                "executable_path": ".build/release/example-feature",
                "arguments": ["--verbose"]
              },
              "generated": {
                "by": "feature-builder",
                "created_at": "2026-06-13T12:00:00Z",
                "adopted_from": "legacy-feature"
              }
            }
            """#
        )

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.displayName == "Example Feature")
        #expect(manifest.executable == "example-feature")
        #expect(manifest.tools.first?.inputSchema.contains("\"text\"") == true)
        #expect(manifest.toolNamePrefixes == ["example."])
        #expect(manifest.toolNameAliases == ["example.run"])
        #expect(manifest.discoversToolsAtRuntime)
        #expect(manifest.invocationTimeoutSeconds == 30)
        #expect(manifest.build?.executablePath == ".build/release/example-feature")
        #expect(manifest.generated?.createdAt == "2026-06-13T12:00:00Z")

        let reloaded = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(reloaded.id == manifest.id)
        #expect(reloaded.tools.first?.name == manifest.tools.first?.name)
        #expect(reloaded.toolNamePrefixes == manifest.toolNamePrefixes)
        #expect(reloaded.build?.arguments == ["--verbose"])
        #expect(reloaded.generated?.adoptedFrom == "legacy-feature")
    }

    private func decode<T: Decodable>(_ type: T.Type, from fixture: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(fixture.utf8))
    }
}
