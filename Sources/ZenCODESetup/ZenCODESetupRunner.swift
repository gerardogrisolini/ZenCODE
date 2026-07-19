//
//  ZenCODESetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore

public enum ZenCODESetupRunner {
    public static func run() async throws {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw ZenCODESetupError.nonInteractiveTerminal
        }

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
            let resolution = try SetupConfigurationResolver.resolve {
                try AgentSettingsManifestStore.loadRequired(from: settingsURL)
            } confirmOverwrite: { _ in
                try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
            }
            if case let .loaded(loadedManifest) = resolution {
                manifest = loadedManifest
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
            let quickManifest = try await runQuickSetup(
                currentManifest: session.manifest
            )
            session.applyQuickSetup(quickManifest)
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
                return
            }
            if section == .resetRemoteConfiguration {
                guard try confirmRemoteConfigurationReset() else {
                    continue
                }
                try resetRemoteConfiguration()
                printCompletion()
                return
            }

            let result = try await configureSetupSection(
                section,
                currentManifest: session.manifest
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
                overwriteSettings: shouldWriteSettings
            )
            printResult(result, settingsWasWritten: shouldWriteSettings)
            printCompletion()
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
    ) async throws -> AgentSettingsManifest {
        AgentOutput.standardError.writeString(
            """

            Quick setup configures a remote provider and its default model.
            Advanced options like Telegram and voice can be enabled later from zen --setup.

            """
        )

        var manifest = try await configureProvidersAndModels(existingManifest: existingManifest)
        manifest = try configureDefaultModel(in: manifest)
        try ZenCODEAgentProfileSetupRunner.configureInteractively()
        return manifest
    }

    static func requireExistingManifest(
        _ manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        guard let manifest, !manifest.models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }
        return manifest
    }

    static func confirmRemoteConfigurationReset() throws -> Bool {
        try promptYesNo(
            "Reset remote configuration?",
            defaultValue: false,
            help: "This removes provider settings, profiles, permissions, saved sessions, and global ZenCODE context."
        )
    }

    static func configureSetupSection(
        _ section: SetupSection,
        currentManifest manifest: AgentSettingsManifest?
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
                currentManifest: manifest
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
        case .voice:
            return SetupSectionConfigurationResult(
                manifest: try configureVoice(in: requireExistingManifest(manifest))
            )
        case .features:
            try await configureFeatures()
            return SetupSectionConfigurationResult(manifest: manifest)
        case .agents:
            try ZenCODEAgentProfileSetupRunner.configureInteractively()
            return SetupSectionConfigurationResult(manifest: manifest)
        case .agentModels:
            try ZenCODEAgentProfileSetupRunner.configureAgentModels()
            return SetupSectionConfigurationResult(
                manifest: try requireExistingManifest(manifest)
            )
        case .resetRemoteConfiguration, .finish, .cancel:
            return SetupSectionConfigurationResult(manifest: manifest)
        }
    }
}
