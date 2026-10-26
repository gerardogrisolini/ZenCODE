//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//

import Foundation
import Synchronization
@testable import FeatureMCPBridgeKit
@testable import ZenCODECore
import Testing
import ToolCore

extension ACPCompatibilityTests {
    @Test
    func acpSessionKeepsTheEffectiveAgentAcrossRoutingAndRestore() async throws {
        let agentA = AgentProfile(
            id: "agent-a",
            name: "Agent A",
            instructions: "Instructions for Agent A.",
            role: .developer,
            tools: []
        )
        let agentB = AgentProfile(
            id: "agent-b",
            name: "Agent B",
            instructions: "Instructions for Agent B.",
            role: .developer,
            tools: []
        )
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agentA, agentB],
            agentName: agentA.name,
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-agent-routing",
            "agentId": agentA.id
        ])
        let initialConfiguration = try #require(
            await bridge.sessionConfigurationsForTesting().first
        )
        let sessionID = initialConfiguration.sessionID
        #expect(initialConfiguration.agentID == agentA.id)
        #expect(initialConfiguration.agentName == agentA.name)
        #expect(initialConfiguration.runtimeConfiguration.profileID == agentA.id)
        #expect(initialConfiguration.runtimeConfiguration.profileName == agentA.name)
        #expect(initialConfiguration.agentRole == agentA.role)
        #expect(initialConfiguration.runtimeConfiguration.profileRole == agentA.role)
        #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == agentA.id)

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "@AgentB inspect this session"
        ])

        let routedConfiguration = try #require(
            await bridge.sessionConfigurationsForTesting().first
        )
        #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == agentB.id)
        #expect(routedConfiguration.agentID == agentB.id)
        #expect(routedConfiguration.agentName == agentB.name)
        #expect(routedConfiguration.runtimeConfiguration.profileID == agentB.id)
        #expect(routedConfiguration.runtimeConfiguration.profileName == agentB.name)
        #expect(routedConfiguration.agentRole == agentB.role)
        #expect(routedConfiguration.runtimeConfiguration.profileRole == agentB.role)
        #expect(await bridge.sessionRunner.sessions[sessionID]?.agentID == agentB.id)
        #expect(await bridge.sessionRunner.sessions[sessionID]?.agentName == agentB.name)
        #expect(routedConfiguration.systemPrompt?.contains("Instructions for Agent B.") == false)
        #expect(routedConfiguration.dynamicContext?.contains("Instructions for Agent B.") == true)
        #expect(await bridge.lifecycleAgentIDForTesting(sessionID: sessionID) == agentB.id)

        let restoredBridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agentA, agentB],
            agentName: agentA.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )
        try await restoredBridge.restoreSession(
            id: nil,
            params: [
                "sessionId": "restored-agent-b",
                "cwd": "/tmp/acp-agent-routing",
                "agentId": agentB.id
            ],
            replayHistory: false
        )
        let restoredConfiguration = try #require(
            await restoredBridge.sessionConfigurationsForTesting().first
        )
        #expect(
            await restoredBridge.selectedAgentIDForTesting(sessionID: "restored-agent-b")
                == agentB.id
        )
        #expect(restoredConfiguration.agentID == agentB.id)
        #expect(restoredConfiguration.agentName == agentB.name)
        #expect(restoredConfiguration.runtimeConfiguration.profileID == agentB.id)
        #expect(restoredConfiguration.runtimeConfiguration.profileName == agentB.name)
        #expect(restoredConfiguration.agentRole == agentB.role)
        #expect(restoredConfiguration.runtimeConfiguration.profileRole == agentB.role)
        #expect(restoredConfiguration.systemPrompt?.contains("Instructions for Agent B.") == false)
        #expect(restoredConfiguration.dynamicContext?.contains("Instructions for Agent B.") == true)
        #expect(
            await restoredBridge.lifecycleAgentIDForTesting(sessionID: "restored-agent-b")
                == agentB.id
        )
    }

    @Test
    func acpPreloadPreservesSelectedProfileInDefaultRuntimeConfiguration() async throws {
        let agent = AgentProfile(id: "preload-profile", name: "Preload Profile", role: .developer, tools: [])
        let runtimeConfigurations = Mutex<[AgentRuntimeConfiguration]>([])
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agent],
            agentName: agent.name,
            backendFactory: { runtimeConfiguration, _ in
                runtimeConfigurations.withLock { $0.append(runtimeConfiguration) }
                return backend
            }
        )

        try await bridge.preloadModel(id: nil, params: [:])

        let runtimeConfiguration = try #require(runtimeConfigurations.withLock { $0.first })
        #expect(runtimeConfiguration.agentID == agent.id)
        #expect(runtimeConfiguration.agentName == agent.name)
        #expect(runtimeConfiguration.profileID == agent.id)
        #expect(runtimeConfiguration.profileName == agent.name)
        #expect(runtimeConfiguration.profileRole == agent.role)
        await bridge.shutdown()
    }

    @Test
    func newSessionSkipsUnavailableACPProvidedMCPServers() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Unavailable",
                    "command": "/path/that/does/not/exist/fixture-server",
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(!allowedToolNames.contains("unavailable.run"))
    }

    @Test
    func newSessionConsumesAllowedToolsFromACPParams() async throws {
        let backend = CapturingACPBackend()
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
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["custom.", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("custom."))
        #expect(allowedToolNames.contains("local.exec"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify tools"
        ])
        #expect(await backend.createdAllowedToolNames() == allowedToolNames)
    }

    @Test
    func acpReadOnlyProfileCannotRestoreMutableCoreToolsFromClientSelection() async throws {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let rawCompatibilityAlias = "agent.spawn"
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [profile],
            agentName: profile.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-read-only-tools",
            "agentId": profile.id,
            "allowed_tools": ["shell", "files", "custom.", rawCompatibilityAlias] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("custom."))
        #expect(allowedToolNames.contains(rawCompatibilityAlias))
        #expect(
            !DirectToolExecutor.isCoreCoordinationToolAllowed(
                rawCompatibilityAlias,
                allowedToolNames: allowedToolNames
            )
        )
    }

    @Test
    func acpAgentMentionReappliesReadOnlyCoreToolPolicy() async throws {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            tools: ["shell", "files"]
        )
        let reviewer = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            readOnly: true,
            role: .reviewer,
            tools: ["shell", "files"]
        )
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [developer, reviewer],
            agentName: developer.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-read-only-agent-switch",
            "agentId": developer.id,
            "allowed_tools": ["shell", "files"] as [String]
        ])
        let sessionID = try #require(
            await bridge.sessionConfigurationsForTesting().first?.sessionID
        )

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "@Reviewer inspect the change"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(configuration.agentRole == reviewer.role)
        #expect(configuration.runtimeConfiguration.profileRole == reviewer.role)
    }

    @Test
    func acpSessionRoleFollowsTheSelectedProfileOnNewAndRestoredSessions() async throws {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            tools: []
        )
        let reviewer = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            role: .reviewer,
            tools: []
        )
        let models = [
            AgentSettingsModelManifest(
                id: "test-model",
                kind: .remoteAPI,
                modelID: "local/test-model"
            )
        ]
        let bridge = try makeBridge(
            models: models,
            availableAgents: [developer, reviewer],
            agentName: developer.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-role-new-session",
            "agentId": reviewer.id
        ])
        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        #expect(configuration.agentID == reviewer.id)
        #expect(configuration.agentRole == reviewer.role)
        #expect(configuration.runtimeConfiguration.profileRole == reviewer.role)

        let restoredBridge = try makeBridge(
            models: models,
            availableAgents: [developer, reviewer],
            agentName: developer.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )
        try await restoredBridge.restoreSession(
            id: nil,
            params: [
                "sessionId": "restored-developer-role",
                "cwd": "/tmp/acp-role-new-session",
                "agentId": developer.id
            ],
            replayHistory: false
        )
        let restoredConfiguration = try #require(
            await restoredBridge.sessionConfigurationsForTesting().first
        )
        #expect(restoredConfiguration.agentID == developer.id)
        #expect(restoredConfiguration.agentRole == developer.role)
        #expect(restoredConfiguration.runtimeConfiguration.profileRole == developer.role)
    }

    @Test
    func newSessionIgnoresNonStandardSystemPromptParameter() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-system-prompt-workspace",
            "systemPrompt": "CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let systemPrompt = try #require(configuration.systemPrompt)

        #expect(!systemPrompt.contains("CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"))
    }

    @Test
    func newSessionUsesHostedDefaultThinkingWhenThinkingIsNotProvided() async throws {
        let bridge = try makeBridge(
            models: [
                Self.thinkingModel(defaultThinkingSelection: .high)
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionUsesAgentThinkingOverHostedDefault() async throws {
        let model = Self.thinkingModel(defaultThinkingSelection: .medium)
        let agent = AgentProfile(
            id: "thinking-agent",
            name: "Thinking Agent",
            role: .developer,
            tools: [],
            modelID: model.id,
            thinkingSelection: .high
        )
        let bridge = try makeBridge(
            models: [model],
            availableAgents: [agent],
            agentName: agent.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.modelID == model.id)
        #expect(configuration.agentID == agent.id)
        #expect(configuration.agentName == agent.name)
        #expect(configuration.agentRole == agent.role)
        #expect(configuration.runtimeConfiguration.profileRole == agent.role)
        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func promptRefreshPreservesSessionRevisionAndGenerationSettings() async throws {
        let backend = CapturingACPBackend()
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
        let generationOverrides = AgentGenerationParameterOverrides(
            maxTokens: 321,
            temperature: 0.25
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "acp-refresh-state",
            modelID: "test-model",
            agentID: "acp-refresh-profile",
            agentName: "ACP Refresh Profile",
            agentRole: .developer,
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "test system prompt",
            cacheKey: "acp-refresh-cache",
            sessionRevision: 7,
            history: [],
            allowedToolNames: [],
            configuredContextWindowLimit: 16_384,
            generationParameterOverrides: generationOverrides
        )
        await bridge.installTestSession(configuration)

        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "refresh this session"
        ])

        let refreshed = try #require(
            await bridge.sessionConfigurationsForTesting().first
        )
        #expect(refreshed.agentID == configuration.agentID)
        #expect(refreshed.agentName == configuration.agentName)
        #expect(refreshed.runtimeConfiguration.profileID == configuration.agentID)
        #expect(refreshed.runtimeConfiguration.profileName == configuration.agentName)
        #expect(refreshed.agentRole == configuration.agentRole)
        #expect(refreshed.agentRole == .developer)
        #expect(refreshed.runtimeConfiguration.profileRole == configuration.agentRole)
        #expect(refreshed.sessionRevision == configuration.sessionRevision)
        #expect(
            refreshed.configuredContextWindowLimit
                == configuration.configuredContextWindowLimit
        )
        #expect(
            refreshed.generationParameterOverrides
                == configuration.generationParameterOverrides
        )
        #expect(
            refreshed.history.contains {
                $0.role == .user && $0.content == "refresh this session"
            }
        )
    }

    // MARK: - Default agent per session working directory

    private static let projectDefaultTestModel = AgentSettingsModelManifest(
        id: "test-model",
        kind: .remoteAPI,
        modelID: "local/test-model"
    )

    @Test
    func newSessionDefaultsToTheDeveloperAssociatedWithTheSessionWorkingDirectory() async throws {
        let systemDeveloper = AgentProfileRoleTestSupport.developer
        let projectDeveloper = AgentProfile(
            id: "project-developer",
            name: "Project Developer",
            role: .developer,
            tools: []
        )
        let agents = [systemDeveloper, projectDeveloper]

        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [projectDeveloper.id],
                workspaceRootURL: workspace
            )
            // The launch directory has no saved selection, so the bridge
            // starts with the system developer.
            let bridge = try makeBridge(
                models: [Self.projectDefaultTestModel],
                availableAgents: agents,
                backendFactory: { _, _ in CapturingACPBackend() }
            )
            let launchConfiguration = await bridge.configuration
            #expect(launchConfiguration.selectedAgent?.id == systemDeveloper.id)
            #expect(launchConfiguration.requestedAgentName == nil)

            try await bridge.newSession(id: nil, params: ["cwd": workspace.path])
            let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
            #expect(configuration.agentID == projectDeveloper.id)
            #expect(configuration.agentName == projectDeveloper.name)
            #expect(configuration.agentRole == .developer)
            #expect(
                await bridge.selectedAgentIDForTesting(sessionID: configuration.sessionID)
                    == projectDeveloper.id
            )
            await bridge.shutdown()

            // A directory without a saved selection keeps the system developer.
            let otherBridge = try makeBridge(
                models: [Self.projectDefaultTestModel],
                availableAgents: agents,
                backendFactory: { _, _ in CapturingACPBackend() }
            )
            let otherWorkspace = workspace
                .deletingLastPathComponent()
                .appendingPathComponent("unconfigured", isDirectory: true)
            try FileManager.default.createDirectory(
                at: otherWorkspace,
                withIntermediateDirectories: true
            )
            try await otherBridge.newSession(id: nil, params: ["cwd": otherWorkspace.path])
            let otherConfiguration = try #require(
                await otherBridge.sessionConfigurationsForTesting().first
            )
            #expect(otherConfiguration.agentID == systemDeveloper.id)
            await otherBridge.shutdown()
        }
    }

    @Test
    func newSessionExplicitAgentOrLaunchAgentOverridesTheProjectDefault() async throws {
        let systemDeveloper = AgentProfileRoleTestSupport.developer
        let projectDeveloper = AgentProfile(
            id: "project-developer",
            name: "Project Developer",
            role: .developer,
            tools: []
        )
        let agents = [systemDeveloper, projectDeveloper]

        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [projectDeveloper.id],
                workspaceRootURL: workspace
            )

            // `agentId` selects any profile, associated with the project or not.
            let explicitBridge = try makeBridge(
                models: [Self.projectDefaultTestModel],
                availableAgents: agents,
                backendFactory: { _, _ in CapturingACPBackend() }
            )
            try await explicitBridge.newSession(id: nil, params: [
                "cwd": workspace.path,
                "agentId": systemDeveloper.id,
            ])
            let explicitConfiguration = try #require(
                await explicitBridge.sessionConfigurationsForTesting().first
            )
            #expect(explicitConfiguration.agentID == systemDeveloper.id)
            await explicitBridge.shutdown()

            // An agent requested at launch (`--agent`) is never replaced by the
            // project default.
            let launchBridge = try makeBridge(
                models: [Self.projectDefaultTestModel],
                availableAgents: agents,
                agentName: systemDeveloper.name,
                backendFactory: { _, _ in CapturingACPBackend() }
            )
            #expect(await launchBridge.configuration.requestedAgentName == systemDeveloper.name)
            try await launchBridge.newSession(id: nil, params: ["cwd": workspace.path])
            let launchConfiguration = try #require(
                await launchBridge.sessionConfigurationsForTesting().first
            )
            #expect(launchConfiguration.agentID == systemDeveloper.id)
            await launchBridge.shutdown()
        }
    }

    @Test
    func loadSessionDefaultsToTheDeveloperAssociatedWithTheSessionWorkingDirectory() async throws {
        let systemDeveloper = AgentProfileRoleTestSupport.developer
        let projectDeveloper = AgentProfile(
            id: "project-developer",
            name: "Project Developer",
            role: .developer,
            tools: []
        )

        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [projectDeveloper.id],
                workspaceRootURL: workspace
            )
            let bridge = try makeBridge(
                models: [Self.projectDefaultTestModel],
                availableAgents: [systemDeveloper, projectDeveloper],
                backendFactory: { _, _ in CapturingACPBackend() }
            )

            try await bridge.restoreSession(
                id: nil,
                params: [
                    "sessionId": "restored-project-default",
                    "cwd": workspace.path,
                ],
                replayHistory: false
            )
            let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
            #expect(configuration.agentID == projectDeveloper.id)
            #expect(
                await bridge.selectedAgentIDForTesting(sessionID: "restored-project-default")
                    == projectDeveloper.id
            )
            await bridge.shutdown()
        }
    }
}
