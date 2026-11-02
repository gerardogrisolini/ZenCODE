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

// MARK: - Model and thinking defaults saved by set_model and set_config_option

extension ACPCompatibilityTests {
    /// A model of the user's configured catalog. A configured remote model
    /// needs a provider, otherwise `settings.json` drops it.
    private static func configuredModel(
        _ id: String,
        thinkingOptions: [AgentThinkingSelection],
        defaultThinkingSelection: AgentThinkingSelection
    ) -> AgentSettingsModelManifest {
        let modelID = "local/\(id)"
        return AgentSettingsModelManifest(
            id: id,
            kind: .remoteAPI,
            modelID: modelID,
            provider: AgentRemoteProvider(
                name: "remote-server",
                baseURL: "http://127.0.0.1",
                modelID: modelID
            ),
            thinkingOptions: thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    private static let primaryConfiguredModel = configuredModel(
        "configured-primary",
        thinkingOptions: [.off, .medium, .high],
        defaultThinkingSelection: .medium
    )

    /// Offers neither `.medium` nor `.high`, so a level carried over from the
    /// primary model resolves to its own default, `.low`.
    private static let secondaryConfiguredModel = configuredModel(
        "configured-secondary",
        thinkingOptions: [.off, .low],
        defaultThinkingSelection: .low
    )

    /// Runs `body` with a support directory named by a UUID whose
    /// `settings.json` configures `models`, `selectedModelID` selected. The
    /// override is task-local: everything the bridge does from `body` reads
    /// and writes there, never in the developer's support directory. `body`
    /// receives the settings file and a workspace for the sessions.
    private func withConfiguredSettings(
        models: [AgentSettingsModelManifest],
        selectedModelID: String,
        _ body: (_ settingsURL: URL, _ workspace: URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-persisted-defaults-\(UUID().uuidString)", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = supportDirectory
            .appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: models, selectedModelID: selectedModelID),
            to: settingsURL
        )
        try await AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            try await body(settingsURL, workspace)
        }
    }

    /// A bridge without hosted models, like `zen --acp`: it lists, resolves,
    /// and saves the models of `settings.json`. `--model` is always passed so
    /// an ambient `ZENCODE_AGENT_MODEL` cannot stand in for the explicit model
    /// (an empty value means none).
    private func makeConfiguredBridge(
        workspace: URL,
        launchModelID: String = ""
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration.withoutPersistedConfiguration(
            arguments: [
                "zen",
                "--model", launchModelID,
                "--working-directory", workspace.path,
            ]
        )
        #expect(configuration.hostedModels == nil)
        #expect(configuration.modelID == launchModelID.nilIfBlank)
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: { _ in }),
            backendFactory: { _, _ in CapturingACPBackend() }
        )
    }

    /// A bridge whose host supplies `models`, the first one at launch.
    private func makeHostedBridge(
        models: [AgentSettingsModelManifest],
        workspace: URL
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: models.first?.id ?? "model",
            availableModels: models,
            runMode: .acp,
            workingDirectory: workspace
        )
        #expect(configuration.hostedModels != nil)
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: { _ in }),
            backendFactory: { _, _ in CapturingACPBackend() }
        )
    }

    /// Creates a session with `session/new` and returns its configuration.
    private func newSessionConfiguration(
        on bridge: ZenCODEACPBridge,
        cwd: String,
        modelID: String? = nil
    ) async throws -> AgentCoreSessionConfiguration {
        let existingIDs = Set(await bridge.sessionConfigurationsForTesting().map(\.sessionID))
        var params: [String: Any] = ["cwd": cwd]
        if let modelID {
            params["modelId"] = modelID
        }
        try await bridge.newSession(id: nil, params: params)
        return try #require(
            await bridge.sessionConfigurationsForTesting().first { configuration in
                !existingIDs.contains(configuration.sessionID)
            }
        )
    }

    /// Restores a session under an ID the bridge does not know yet (the
    /// `session/load` branch that creates the session) and returns its
    /// configuration.
    private func restoredSessionConfiguration(
        on bridge: ZenCODEACPBridge,
        cwd: String,
        modelID: String? = nil
    ) async throws -> AgentCoreSessionConfiguration {
        let sessionID = "acp-restored-\(UUID().uuidString.lowercased())"
        var params: [String: Any] = ["sessionId": sessionID, "cwd": cwd]
        if let modelID {
            params["modelId"] = modelID
        }
        try await bridge.restoreSession(id: nil, params: params, replayHistory: false)
        return try await sessionConfiguration(on: bridge, sessionID: sessionID)
    }

    private func sessionConfiguration(
        on bridge: ZenCODEACPBridge,
        sessionID: String
    ) async throws -> AgentCoreSessionConfiguration {
        try #require(
            await bridge.sessionConfigurationsForTesting().first { configuration in
                configuration.sessionID == sessionID
            }
        )
    }

    @Test
    func setModelSavesTheModelAndItsThinkingAsTheDefaultOfNewSessions() async throws {
        let primary = Self.primaryConfiguredModel
        let secondary = Self.secondaryConfiguredModel
        try await withConfiguredSettings(
            models: [primary, secondary],
            selectedModelID: primary.id
        ) { settingsURL, workspace in
            let bridge = try makeConfiguredBridge(workspace: workspace)
            let first = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(first.modelID == primary.id)
            #expect(first.thinkingSelection == .medium)

            try await bridge.setModel(id: nil, params: [
                "sessionId": first.sessionID,
                "modelId": secondary.id,
            ])

            // Read from the UUID directory itself: the save happened in scope.
            let saved = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            #expect(saved.selectedModelID == secondary.id)
            // The thinking level the session ended up with on the new model.
            #expect(saved.selectedThinkingSelection == .low)
            let switched = try await sessionConfiguration(on: bridge, sessionID: first.sessionID)
            #expect(switched.modelID == secondary.id)
            #expect(switched.thinkingSelection == .low)

            let next = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(next.modelID == secondary.id)
            #expect(next.thinkingSelection == .low)
            // The default advertised outside any session follows as well.
            let lifecycle = await bridge.testLifecycleModelState(sessionID: "acp-no-such-session")
            #expect(lifecycle.metaCurrent == secondary.id)
            await bridge.shutdown()
        }
    }

    @Test
    func setConfigOptionSavesThinkingAndModelAsTheDefaultOfNewSessions() async throws {
        let primary = Self.primaryConfiguredModel
        let secondary = Self.secondaryConfiguredModel
        try await withConfiguredSettings(
            models: [primary, secondary],
            selectedModelID: primary.id
        ) { settingsURL, workspace in
            let bridge = try makeConfiguredBridge(workspace: workspace)
            let first = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(first.modelID == primary.id)
            #expect(first.thinkingSelection == .medium)

            try await bridge.setConfigOption(id: nil, params: [
                "sessionId": first.sessionID,
                "configId": "thinking",
                "value": "high",
            ])
            var saved = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            #expect(saved.selectedModelID == primary.id)
            #expect(saved.selectedThinkingSelection == .high)
            let afterThinking = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(afterThinking.modelID == primary.id)
            #expect(afterThinking.thinkingSelection == .high)

            try await bridge.setConfigOption(id: nil, params: [
                "sessionId": first.sessionID,
                "configId": "model",
                "value": secondary.id,
            ])
            saved = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            #expect(saved.selectedModelID == secondary.id)
            #expect(saved.selectedThinkingSelection == .low)
            let afterModel = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(afterModel.modelID == secondary.id)
            #expect(afterModel.thinkingSelection == .low)
            await bridge.shutdown()
        }
    }

    @Test
    func hostedModelsNeverSaveChoicesAndNewSessionsKeepTheLaunchModel() async throws {
        let hostedPrimary = Self.configuredModel(
            "hosted-primary",
            thinkingOptions: [.off, .medium, .high],
            defaultThinkingSelection: .medium
        )
        let hostedSecondary = Self.configuredModel(
            "hosted-secondary",
            thinkingOptions: [.off, .low],
            defaultThinkingSelection: .low
        )
        // The settings in scope select a model the host does not offer: a
        // hosted bridge must neither read nor write them.
        try await withConfiguredSettings(
            models: [Self.primaryConfiguredModel, Self.secondaryConfiguredModel],
            selectedModelID: Self.secondaryConfiguredModel.id
        ) { settingsURL, workspace in
            let settingsBefore = try Data(contentsOf: settingsURL)
            let bridge = try makeHostedBridge(
                models: [hostedPrimary, hostedSecondary],
                workspace: workspace
            )
            let first = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(first.modelID == hostedPrimary.id)

            try await bridge.setModel(id: nil, params: [
                "sessionId": first.sessionID,
                "modelId": hostedSecondary.id,
            ])
            try await bridge.setConfigOption(id: nil, params: [
                "sessionId": first.sessionID,
                "configId": "thinking",
                "value": "off",
            ])
            // Both choices were applied to the session...
            let switched = try await sessionConfiguration(on: bridge, sessionID: first.sessionID)
            #expect(switched.modelID == hostedSecondary.id)
            #expect(switched.thinkingSelection == .off)
            // ...and none was saved.
            #expect(try Data(contentsOf: settingsURL) == settingsBefore)

            // New sessions keep starting from the launch model, as before.
            let next = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(next.modelID == hostedPrimary.id)
            let restored = try await restoredSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(restored.modelID == hostedPrimary.id)
            let lifecycle = await bridge.testLifecycleModelState(sessionID: "acp-no-such-session")
            #expect(lifecycle.metaCurrent == hostedPrimary.id)
            await bridge.shutdown()
        }
    }

    @Test
    func rolledBackReconfigurationSavesNothing() async throws {
        let primary = Self.primaryConfiguredModel
        let secondary = Self.secondaryConfiguredModel
        try await withConfiguredSettings(
            models: [primary, secondary],
            selectedModelID: primary.id
        ) { settingsURL, workspace in
            let bridge = try makeConfiguredBridge(workspace: workspace)
            let sessionID = "acp-rollback-\(UUID().uuidString.lowercased())"
            // The runner already holds this session for another directory, so
            // re-creating it for the ACP session's directory fails in the
            // runner, while the ACP session stays live: a real rollback.
            let elsewhere = workspace.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try await bridge.sessionRunner.createSession(
                configuration: AgentCoreSessionConfiguration(
                    sessionID: sessionID,
                    modelID: primary.id,
                    workingDirectory: elsewhere,
                    systemPrompt: nil,
                    cacheKey: nil,
                    history: [],
                    thinkingSelection: .medium
                )
            )
            await bridge.installTestSession(
                AgentCoreSessionConfiguration(
                    sessionID: sessionID,
                    modelID: primary.id,
                    workingDirectory: workspace,
                    systemPrompt: nil,
                    cacheKey: nil,
                    history: [],
                    thinkingSelection: .medium
                )
            )
            let settingsBefore = try Data(contentsOf: settingsURL)

            await #expect(throws: SessionTaskOrchestratorError.self) {
                try await bridge.setModel(id: nil, params: [
                    "sessionId": sessionID,
                    "modelId": secondary.id,
                ])
            }
            await #expect(throws: SessionTaskOrchestratorError.self) {
                try await bridge.setConfigOption(id: nil, params: [
                    "sessionId": sessionID,
                    "configId": "model",
                    "value": secondary.id,
                ])
            }
            await #expect(throws: SessionTaskOrchestratorError.self) {
                try await bridge.setConfigOption(id: nil, params: [
                    "sessionId": sessionID,
                    "configId": "thinking",
                    "value": "high",
                ])
            }

            let rolledBack = try await sessionConfiguration(on: bridge, sessionID: sessionID)
            #expect(rolledBack.modelID == primary.id)
            #expect(rolledBack.thinkingSelection == .medium)
            #expect(try Data(contentsOf: settingsURL) == settingsBefore)

            // Positive control in the same scope: a committed change is saved.
            let live = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            try await bridge.setModel(id: nil, params: [
                "sessionId": live.sessionID,
                "modelId": secondary.id,
            ])
            let saved = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            #expect(saved.selectedModelID == secondary.id)
            await bridge.shutdown()
        }
    }

    @Test
    func clientAndLaunchModelsStayAheadOfTheSavedDefault() async throws {
        let primary = Self.primaryConfiguredModel
        let secondary = Self.secondaryConfiguredModel
        try await withConfiguredSettings(
            models: [primary, secondary],
            selectedModelID: primary.id
        ) { settingsURL, workspace in
            let bridge = try makeConfiguredBridge(workspace: workspace)
            let first = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            try await bridge.setModel(id: nil, params: [
                "sessionId": first.sessionID,
                "modelId": secondary.id,
            ])
            #expect(
                try AgentSettingsManifestStore.loadRequired(from: settingsURL).selectedModelID
                    == secondary.id
            )

            // Without a client model, new and restored sessions use the saved default...
            let defaulted = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(defaulted.modelID == secondary.id)
            let restoredDefault = try await restoredSessionConfiguration(
                on: bridge,
                cwd: workspace.path
            )
            #expect(restoredDefault.modelID == secondary.id)

            // ...while the client's `modelId` wins over it.
            let explicit = try await newSessionConfiguration(
                on: bridge,
                cwd: workspace.path,
                modelID: primary.id
            )
            #expect(explicit.modelID == primary.id)
            #expect(explicit.thinkingSelection == .medium)
            let restoredExplicit = try await restoredSessionConfiguration(
                on: bridge,
                cwd: workspace.path,
                modelID: primary.id
            )
            #expect(restoredExplicit.modelID == primary.id)
            await bridge.shutdown()

            // `--model` wins over the saved default too.
            let launchBridge = try makeConfiguredBridge(
                workspace: workspace,
                launchModelID: primary.id
            )
            let launched = try await newSessionConfiguration(
                on: launchBridge,
                cwd: workspace.path
            )
            #expect(launched.modelID == primary.id)
            await launchBridge.shutdown()
        }
    }
}
