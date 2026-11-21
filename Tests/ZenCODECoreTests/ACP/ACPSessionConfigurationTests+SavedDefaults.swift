//
//  ACPSessionConfigurationTests+SavedDefaults.swift
//  ZenCODE
//
//  Tests of the model and thinking defaults that `set_model` and
//  `set_config_option` save for new ACP sessions, with the settings fixtures
//  they use.
//

import Foundation
import Synchronization
@testable import FeatureMCPBridgeKit
@testable import ZenCODECore
import Testing
import ToolCore

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

    /// `zen --acp` launched by Xcode: the launch directory has no project
    /// selection, so the launch agent is the system developer, while each
    /// session resolves the developer of its own working directory. Without a
    /// client model, that developer's default binding is the session's model,
    /// not the model selected in the settings.
    @Test
    func sessionsDefaultToTheBindingOfTheDeveloperOfTheirWorkingDirectory() async throws {
        let primary = Self.primaryConfiguredModel
        let secondary = Self.secondaryConfiguredModel
        let systemDeveloper = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            tools: []
        )
        let projectDeveloper = AgentProfile(
            id: "project-developer",
            name: "Project Developer",
            role: .developer,
            tools: [],
            modelBindings: [
                AgentModelBinding(modelID: secondary.id, thinkingSelection: .off),
            ]
        )
        try await withConfiguredSettings(
            models: [primary, secondary],
            selectedModelID: primary.id
        ) { _, workspace in
            try AgentProfileStore.save([systemDeveloper, projectDeveloper])
            try ProjectAgentSelectionStore.save(
                agentIDs: [projectDeveloper.id],
                workspaceRootURL: workspace
            )
            let launchDirectory = workspace
                .deletingLastPathComponent()
                .appendingPathComponent("launch", isDirectory: true)
            try FileManager.default.createDirectory(
                at: launchDirectory,
                withIntermediateDirectories: true
            )
            // `--model` is passed empty so an ambient `ZENCODE_AGENT_MODEL`
            // cannot stand in for the explicit model.
            let configuration = try AgentConfiguration(arguments: [
                "zen", "--acp",
                "--model", "",
                "--working-directory", launchDirectory.path,
            ])
            #expect(configuration.hostedModels == nil)
            #expect(configuration.selectedAgent?.id == systemDeveloper.id)
            let bridge = ZenCODEACPBridge(
                configuration: configuration,
                writer: ACPWriter(sink: { _ in }),
                backendFactory: { _, _ in CapturingACPBackend() }
            )

            let created = try await newSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(created.agentID == projectDeveloper.id)
            #expect(created.modelID == secondary.id)
            #expect(created.thinkingSelection == .off)

            let restored = try await restoredSessionConfiguration(on: bridge, cwd: workspace.path)
            #expect(restored.agentID == projectDeveloper.id)
            #expect(restored.modelID == secondary.id)
            #expect(restored.thinkingSelection == .off)

            // The client's `modelId` still wins over the agent's binding.
            let explicit = try await newSessionConfiguration(
                on: bridge,
                cwd: workspace.path,
                modelID: primary.id
            )
            #expect(explicit.agentID == projectDeveloper.id)
            #expect(explicit.modelID == primary.id)
            await bridge.shutdown()
        }
    }
}
