//
//  MLXServerSetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import ZenCODECore
import MLXServerCore

public enum MLXServerSetupRunner {
    public static func runQuickSetup() throws -> Bool {
        let settingsURL = MLXServerSettingsStore.settingsURL()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let resolution = try SetupConfigurationResolver.resolve {
                try MLXServerSettingsStore.loadRequired(from: settingsURL)
            } confirmOverwrite: { _ in
                try promptYesNo(
                    "Local MLX settings.json exists but is invalid. Rewrite it with defaults?",
                    defaultValue: true
                )
            }
            if case .loaded = resolution {
                AgentOutput.standardError.writeString("Preserved: local MLX settings.json\n")
                return false
            }
        }

        try MLXServerSettingsStore.save(MLXServerSettings(), to: settingsURL)
        AgentOutput.standardError.writeString("Created: local MLX settings.json\n")
        return true
    }

    public static func run(arguments: [String]) throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerSetupError.nonInteractiveTerminal
        }

        let settingsURL = MLXServerSettingsStore.settingsURL()
        let hadSettingsFile = FileManager.default.fileExists(atPath: settingsURL.path)
        AgentOutput.standardError.writeString(
            """
            ZenCODE MLX setup
            Configuring settings.json at:
            \(settingsURL.path)

            """
        )

        var originalSettings: MLXServerSettings?
        var settings = MLXServerSettings()
        if hadSettingsFile {
            let resolution = try SetupConfigurationResolver.resolve {
                try MLXServerSettingsStore.loadRequired(from: settingsURL)
            } confirmOverwrite: { _ in
                try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
            }
            switch resolution {
            case let .loaded(loadedSettings):
                settings = loadedSettings
                originalSettings = loadedSettings
            case .overwrite:
                AgentOutput.standardError.writeString(
                    "Invalid settings will be replaced with defaults unless you edit a section.\n\n"
                )
            }
        } else {
            AgentOutput.standardError.writeString(
                "No settings.json found. Defaults will be used unless you edit a section.\n\n"
            )
        }

        var didChangeSettings = false
        while true {
            let section = try promptSetupSection(
                currentSettings: settings,
                settingsExists: originalSettings != nil
            )
            if section == .cancel {
                AgentOutput.standardError.writeString("Setup changes were not saved.\n")
                return
            }
            guard section != .finish else {
                break
            }

            let previousSettings = settings
            settings = try configureSetupSection(section, currentSettings: settings)
            if settings != previousSettings {
                didChangeSettings = true
            }
        }

        let finalSettings = try settings.validated()
        let shouldWriteSettings = didChangeSettings
            || originalSettings == nil
            || finalSettings != originalSettings
        if shouldWriteSettings {
            try MLXServerSettingsStore.save(finalSettings, to: settingsURL)
            AgentOutput.standardError.writeString(
                hadSettingsFile ? "Updated: settings.json\n" : "Created: settings.json\n"
            )
        } else {
            AgentOutput.standardError.writeString("Preserved: settings.json\n")
        }
        printRuntimeSetupCompleted()
    }

    static func printRuntimeSetupCompleted() {
        AgentOutput.standardError.writeString("\nRuntime setup completed.\n")
    }

}
