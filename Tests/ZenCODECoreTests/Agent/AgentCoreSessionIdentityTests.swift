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

    // MARK: - Profile role

    private func sessionConfiguration(
        agentRole: AgentProfileRole?,
        workingDirectory: URL = URL(fileURLWithPath: "/tmp/role-workspace", isDirectory: true)
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: "profile-role",
            modelID: "test-model",
            agentID: agentRole?.rawValue,
            agentName: agentRole?.title,
            agentRole: agentRole,
            workingDirectory: workingDirectory,
            systemPrompt: "System prompt",
            cacheKey: "role-cache",
            history: [],
            allowedToolNames: ["local.readFile"]
        )
    }

    @Test
    func memoryGraphTargetIsGlobalOnlyForTheOrganizerRole() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/role-workspace", isDirectory: true)

        #expect(
            sessionConfiguration(agentRole: .organizer, workingDirectory: workingDirectory)
                .memoryGraphTarget == .global
        )
        #expect(
            sessionConfiguration(agentRole: nil, workingDirectory: workingDirectory)
                .memoryGraphTarget == .workspace(workingDirectory)
        )
        for role in AgentProfileRole.allCases where role != .organizer {
            #expect(
                sessionConfiguration(agentRole: role, workingDirectory: workingDirectory)
                    .memoryGraphTarget == .workspace(workingDirectory)
            )
        }
    }

    @Test
    func stringWorkingDirectoryInitializerKeepsTheProfileRole() {
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "profile-role-string-directory",
            modelID: nil,
            agentRole: .organizer,
            workingDirectory: "/tmp/role-workspace",
            systemPrompt: nil,
            cacheKey: nil,
            history: []
        )

        #expect(configuration.agentRole == .organizer)
        #expect(configuration.memoryGraphTarget == .global)
    }

    @Test
    func runtimeConfigurationCarriesTheProfileRole() {
        #expect(sessionConfiguration(agentRole: .organizer).runtimeConfiguration.profileRole == .organizer)
        #expect(sessionConfiguration(agentRole: .developer).runtimeConfiguration.profileRole == .developer)
        #expect(sessionConfiguration(agentRole: nil).runtimeConfiguration.profileRole == nil)
    }

    @Test
    func configurationCopiesAndRuntimeReplacementKeepTheProfileRole() {
        let configuration = sessionConfiguration(agentRole: .organizer)
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            modelID: "restored-model",
            workingDirectoryPath: "/tmp/role-recovered",
            systemPrompt: "Recovered prompt",
            dynamicContext: nil,
            cacheKey: "recovered-cache",
            history: [],
            allowedToolNames: ["local.readFile"],
            thinkingSelection: nil,
            preserveThinking: false
        )

        let withModel = configuration.withModelID("other-model")
        let withThinking = configuration.withThinkingSelection(.high)
        let replaced = configuration.replacingRuntimeState(with: snapshot)

        for copy in [withModel, withThinking, replaced] {
            #expect(copy.agentRole == .organizer)
            #expect(copy.runtimeConfiguration.profileRole == .organizer)
            #expect(copy.memoryGraphTarget == .global)
        }
        // Only the thinking selection changed, so the role must not make the
        // copy look like a different backend.
        #expect(withThinking.matchesRuntime(configuration))
        #expect(withModel.modelID == "other-model")
        #expect(withThinking.thinkingSelection == .high)
        #expect(replaced.workingDirectoryPath == "/tmp/role-recovered")
    }

    @Test
    func matchesRuntimeDistinguishesProfileRoles() {
        let organizer = sessionConfiguration(agentRole: .organizer)
        let sameRole = sessionConfiguration(agentRole: .organizer)
        let developer = sessionConfiguration(agentRole: .developer)
        let noRole = sessionConfiguration(agentRole: nil)

        #expect(organizer.matchesRuntime(sameRole))
        #expect(!organizer.matchesRuntime(developer))
        #expect(!developer.matchesRuntime(organizer))
        #expect(!organizer.matchesRuntime(noRole))
        #expect(!organizer.matchesSessionIdentity(developer))

        // Same profile identity, different role: a role change must not be
        // mistaken for an unchanged backend.
        let sameProfileOtherRole = AgentCoreSessionConfiguration(
            sessionID: organizer.sessionID,
            modelID: organizer.modelID,
            agentID: organizer.agentID,
            agentName: organizer.agentName,
            agentRole: .reviewer,
            workingDirectory: organizer.workingDirectory,
            systemPrompt: organizer.systemPrompt,
            cacheKey: organizer.cacheKey,
            history: organizer.history,
            allowedToolNames: organizer.allowedToolNames
        )
        #expect(!organizer.matchesRuntime(sameProfileOtherRole))
    }

    @Test
    func builderPassesTheProfileRoleToTheConfiguration() {
        var builder = AgentCoreSessionConfigurationBuilder(
            sessionID: "builder-role",
            modelID: "test-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/role-workspace", isDirectory: true),
            systemPrompt: nil,
            cacheKey: nil
        )
        #expect(builder.makeConfiguration().agentRole == nil)

        builder.agentRole = .organizer
        let configuration = builder.makeConfiguration()
        #expect(configuration.agentRole == .organizer)
        #expect(configuration.memoryGraphTarget == .global)
    }

    @Test
    func runtimeConfigurationCopiesKeepTheProfileRole() {
        let base = AgentRuntimeConfiguration(
            modelID: "test-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/role-workspace", isDirectory: true),
            maxToolRounds: 2,
            toolAuthorizationHandler: nil,
            profileID: "organizer",
            profileName: "Organizer",
            profileRole: .organizer
        )
        #expect(AgentRuntimeConfiguration(
            modelID: nil,
            workingDirectory: base.workingDirectory,
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        ).profileRole == nil)

        #expect(base.withModelID("other-model").profileRole == .organizer)
        #expect(
            base.withModelSettings(
                configuredContextWindowLimit: 4_096,
                generationParameterOverrides: nil
            ).profileRole == .organizer
        )
        #expect(base.withToolAuthorizationHandler { _ in true }.profileRole == .organizer)
        #expect(
            base.withToolExecutionIdentity(agentID: "child", agentName: "Child").profileRole
                == .organizer
        )

        let reprofiled = base.withProfileIdentity(
            profileID: "reviewer",
            profileName: "Reviewer",
            profileRole: .reviewer
        )
        #expect(reprofiled.profileRole == .reviewer)
        #expect(reprofiled.profileID == "reviewer")
        #expect(
            base.withProfileIdentity(profileID: nil, profileName: nil, profileRole: nil).profileRole
                == nil
        )
    }
}
