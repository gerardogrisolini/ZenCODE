//
//  AgentCoreSessionIdentityTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentCoreSessionIdentityTests {
    @Test(arguments: [false, true])
    func configurationSnapshotRoundTripPreservesProfileIdentity(hasProfile: Bool) {
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "profile-round-trip",
            modelID: "test-model",
            agentID: hasProfile ? "developer-profile" : nil,
            agentName: hasProfile ? "Developer" : nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "System prompt",
            dynamicContext: "Session context",
            cacheKey: "profile-cache",
            sessionRevision: 7,
            history: [AgentRuntimeMessage(role: .user, content: "Inspect the project")],
            allowedToolNames: ["local.readFile", "external.sessionAddition"],
            configuredContextWindowLimit: 16_384,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                maxTokens: 321,
                temperature: 0.25
            ),
            maxToolRounds: 4,
            maxOutputTokens: 512,
            appMode: true,
            thinkingSelection: .high,
            preserveThinking: true
        )
        let snapshot = AgentRuntimeSessionSnapshot(configuration: configuration)
        let restored = configuration.replacingRuntimeState(with: snapshot)

        #expect(restored == configuration)
        #expect(restored.history == configuration.history)
        #expect(restored.agentID == configuration.agentID)
        #expect(restored.agentName == configuration.agentName)
        #expect(restored.runtimeConfiguration.agentID == configuration.agentID)
        #expect(restored.runtimeConfiguration.agentName == configuration.agentName)
        #expect(restored.runtimeConfiguration.profileID == configuration.agentID)
        #expect(restored.runtimeConfiguration.profileName == configuration.agentName)
    }

    @Test(arguments: [false, true])
    func replacingRuntimeStateKeepsProfileAndSessionSettings(hasSnapshotModel: Bool) {
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "profile-replacement",
            modelID: "original-model",
            agentID: "developer-profile",
            agentName: "Developer",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "Original prompt",
            cacheKey: "original-cache",
            sessionRevision: 7,
            history: [],
            allowedToolNames: ["local.writeFile"],
            configuredContextWindowLimit: 16_384,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                maxTokens: 321,
                temperature: 0.25
            ),
            maxToolRounds: 4,
            maxOutputTokens: 512,
            appMode: true
        )
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            modelID: hasSnapshotModel ? "restored-model" : nil,
            workingDirectoryPath: "/tmp/profile-recovered",
            systemPrompt: "Recovered prompt",
            dynamicContext: "Recovered context",
            cacheKey: "recovered-cache",
            history: [AgentRuntimeMessage(role: .assistant, content: "Recovered answer")],
            allowedToolNames: ["local.readFile"],
            thinkingSelection: .high,
            preserveThinking: true
        )
        let restored = configuration.replacingRuntimeState(with: snapshot)

        #expect(restored.agentID == configuration.agentID)
        #expect(restored.agentName == configuration.agentName)
        #expect(restored.runtimeConfiguration.profileID == configuration.agentID)
        #expect(restored.runtimeConfiguration.profileName == configuration.agentName)
        #expect(restored.sessionRevision == configuration.sessionRevision)
        #expect(restored.configuredContextWindowLimit == configuration.configuredContextWindowLimit)
        #expect(restored.generationParameterOverrides == configuration.generationParameterOverrides)
        #expect(restored.maxToolRounds == configuration.maxToolRounds)
        #expect(restored.maxOutputTokens == configuration.maxOutputTokens)
        #expect(restored.appMode == configuration.appMode)
        #expect(restored.modelID == (snapshot.modelID ?? configuration.modelID))
        #expect(restored.workingDirectoryPath == snapshot.workingDirectoryPath)
        #expect(restored.systemPrompt == snapshot.systemPrompt)
        #expect(restored.dynamicContext == snapshot.dynamicContext)
        #expect(restored.cacheKey == snapshot.cacheKey)
        #expect(restored.history == snapshot.history)
        #expect(restored.allowedToolNames == snapshot.allowedToolNames)
        #expect(restored.thinkingSelection == snapshot.thinkingSelection)
        #expect(restored.preserveThinking == snapshot.preserveThinking)
    }

    @Test
    func snapshotCacheAndCompactionPreserveProfileIdentity() throws {
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "profile-snapshot-cache",
            modelID: "test-model",
            agentID: "developer-profile",
            agentName: "Developer",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.readFile"]
        )
        var store = AgentCoreSessionSnapshotStore()
        let generation = store.begin(configuration)
        let snapshot = AgentRuntimeSessionSnapshot(configuration: configuration)
            .replacingHistory([AgentRuntimeMessage(role: .assistant, content: "Recovered answer")])
        store.cache(snapshot, baseConfiguration: configuration, generation: generation)

        let cached = try #require(store.configurations[configuration.sessionID])
        #expect(cached.agentID == configuration.agentID)
        #expect(cached.agentName == configuration.agentName)
        #expect(cached.history == snapshot.history)

        let compactedSnapshot = snapshot.replacingHistory([
            AgentRuntimeMessage(role: .assistant, content: "Compacted answer")
        ])
        store.cacheCompacted(compactedSnapshot)

        let compacted = try #require(store.configurations[configuration.sessionID])
        #expect(compacted.agentID == configuration.agentID)
        #expect(compacted.agentName == configuration.agentName)
        #expect(compacted.runtimeConfiguration.profileID == configuration.agentID)
        #expect(compacted.runtimeConfiguration.profileName == configuration.agentName)
        #expect(compacted.history == compactedSnapshot.history)
    }
}
