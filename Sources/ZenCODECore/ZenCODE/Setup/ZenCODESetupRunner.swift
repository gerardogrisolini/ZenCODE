//
//  ZenCODESetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ZenCODESetupRunner {
    public static func run() async throws -> SetupOutcome {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw ZenCODESetupError.nonInteractiveTerminal
        }
        let manifestBaseline = try SetupManifestBaseline.capture()

        AgentOutput.standardError.writeString(
            """
            ZenCODE setup
            Configuring support files at:
            \(ZenFileService.supportDirectoryURL().path)

            """
        )

        let settingsURL = AgentSettingsManifestStore.settingsURL()
        var manifest: AgentSettingsManifest?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                manifest = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            } catch {
                guard try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                ) else {
                    throw error
                }
            }
        }

        if manifest == nil {
            AgentOutput.standardError.writeString(
                "No valid settings.json found. Quick setup configures remote providers.\n\n"
            )
        } else if manifest?.models.isEmpty == true {
            AgentOutput.standardError.writeString(
                "settings.json does not contain a remote provider model. Setup must configure one.\n\n"
            )
        }

        var session = SetupSession(originalManifest: manifest)
        var shouldOpenSetupMenu = true

        if session.manifest?.models.isEmpty != false,
           try promptQuickSetupMode() {
            let quickSetup = try await runQuickSetup(
                currentManifest: session.manifest
            )
            session.applyQuickSetup(
                quickSetup.manifest,
                agentProfiles: quickSetup.agentProfiles
            )
            shouldOpenSetupMenu = false
        }

        while shouldOpenSetupMenu {
            let section = try promptSetupSection(
                currentManifest: session.manifest
            )
            if section == .finish {
                break
            }
            if section == .cancel {
                AgentOutput.standardError.writeString("Setup changes were not saved.\n")
                return .cancelled
            }
            if section == .resetRemoteConfiguration {
                guard try confirmRemoteConfigurationReset() else {
                    continue
                }
                try resetRemoteConfiguration()
                await MemoryGraphStoreRegistry.shared.reset()
                printCompletion()
                return .reset
            }
            if section == .dataManagement {
                switch try await runDataManagementMenu() {
                case .dataReplaced:
                    AgentOutput.standardError.writeString(
                        """

                        Configuration replaced by the imported backup.

                        """
                    )
                    printCompletion()
                    return .dataReplaced
                case .reset:
                    printCompletion()
                    return .reset
                case .exportCompleted, .back:
                    continue
                }
            }

            let result = try await configureSetupSection(
                section,
                currentManifest: session.manifest,
                currentAgentProfiles: session.agentProfiles
            )
            session.apply(result)
        }

        switch session.outcome {
        case .noModels:
            throw ZenCODESetupError.noModelsConfigured
        case let .write(finalManifest, shouldWriteSettings):
            printSetupSummary(
                manifest: finalManifest,
                settingsWillBeWritten: shouldWriteSettings
            )
            let result = try ZenFileService.ensureRequiredFiles(
                settingsManifest: finalManifest,
                overwriteSettings: shouldWriteSettings,
                stagedAgentProfiles: session.agentProfiles,
                expectedBaseline: manifestBaseline
            )
            if session.originalManifest?.memoryEmbedding != finalManifest.memoryEmbedding {
                await MemoryGraphStoreRegistry.shared.reset()
            }
            printResult(result, settingsWasWritten: shouldWriteSettings)
            printCompletion()
            return .configured
        }
    }

    static func printCompletion() {
        AgentOutput.standardError.writeString("\nSetup completed.\n\n")
    }

    static func promptQuickSetupMode() throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(
                value: true,
                title: "Quick setup",
                detail: "recommended path to configure a remote provider"
            ),
            TerminalCheckboxMenuItem(
                value: false,
                title: "Custom setup",
                detail: "configure each section manually"
            )
        ]
        return try promptMenuChoice(
            title: "Choose setup mode",
            items: items,
            selected: true
        )
    }

    static func runQuickSetup(
        currentManifest existingManifest: AgentSettingsManifest?
    ) async throws -> (
        manifest: AgentSettingsManifest,
        agentProfiles: [AgentProfile]
    ) {
        AgentOutput.standardError.writeString(
            """

            Quick setup configures a remote provider and its default model.
            Advanced options like Telegram can be enabled later with /setup.

            """
        )

        var manifest = try await configureProvidersAndModels(existingManifest: existingManifest)
        manifest = try configureDefaultModel(in: manifest)
        manifest = try configureResponseLanguage(existingManifest: manifest)
        let agentProfiles = try ZenCODEAgentProfileSetupRunner.configureInteractively(
            currentAgents: nil,
            persist: false
        )
        return (manifest, agentProfiles)
    }

    static func requireExistingManifest(
        _ manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        guard let manifest, !manifest.models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }
        return manifest
    }

    static func confirmRemoteConfigurationReset(
        prompt: (String, Bool, String?) throws -> Bool = {
            try promptYesNo($0, defaultValue: $1, help: $2)
        }
    ) throws -> Bool {
        try prompt(
            "Reset remote configuration?",
            false,
            "This removes provider settings, profiles, permissions, global ZenCODE context, and the saved-session index (sessions.json). Per-project session files (.session) are not removed."
        )
    }

    static func configureSetupSection(
        _ section: SetupSection,
        currentManifest manifest: AgentSettingsManifest?,
        currentAgentProfiles: [AgentProfile]? = nil
    ) async throws -> SetupSectionConfigurationResult {
        switch section {
        case .providersAndModels:
            return SetupSectionConfigurationResult(
                manifest: try await configureProvidersAndModels(existingManifest: manifest)
            )
        case .defaultModelSettings:
            guard let nestedSection = try promptDefaultModelSetupSection(
                currentManifest: requireExistingManifest(manifest)
            ) else {
                return SetupSectionConfigurationResult(manifest: manifest)
            }
            return try await configureSetupSection(
                nestedSection,
                currentManifest: manifest,
                currentAgentProfiles: currentAgentProfiles
            )
        case .defaultModel:
            return SetupSectionConfigurationResult(
                manifest: try configureDefaultModel(in: requireExistingManifest(manifest))
            )
        case .defaultThinking:
            return SetupSectionConfigurationResult(
                manifest: try configureDefaultThinking(in: requireExistingManifest(manifest))
            )
        case .telegram:
            return SetupSectionConfigurationResult(
                manifest: try await configureTelegram(in: requireExistingManifest(manifest))
            )
        case .features:
            try await configureFeatures()
            return SetupSectionConfigurationResult(manifest: manifest)
        case .agents:
            let agentProfiles = try ZenCODEAgentProfileSetupRunner.configureInteractively(
                currentAgents: currentAgentProfiles,
                persist: false
            )
            return SetupSectionConfigurationResult(
                manifest: manifest,
                agentProfiles: agentProfiles
            )
        case .responseLanguage:
            return SetupSectionConfigurationResult(
                manifest: try configureResponseLanguage(existingManifest: manifest)
            )
        case .memoryEmbedding:
            return SetupSectionConfigurationResult(
                manifest: try configureMemoryEmbedding(in: manifest)
            )
        case .agentModels:
            let currentManifest = try requireExistingManifest(manifest)
            let agentProfiles = try ZenCODEAgentProfileSetupRunner.configureAgentModels(
                currentManifest: currentManifest,
                currentAgents: currentAgentProfiles,
                persist: false
            )
            return SetupSectionConfigurationResult(
                manifest: currentManifest,
                agentProfiles: agentProfiles
            )
        case .dataManagement, .resetRemoteConfiguration, .finish, .cancel:
            return SetupSectionConfigurationResult(manifest: manifest)
        }
    }
}
