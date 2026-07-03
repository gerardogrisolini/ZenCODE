//
//  ZenCODESetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore

public enum ZenCODESetupAdditionalSectionResult {
    case unchanged
    case removedStandaloneConfiguration
}

public enum ZenCODESetupQuickActionResult: Equatable {
    case unchanged
    case configuredStandaloneRuntime(usageHint: String, hasUsableModel: Bool)
}

public struct ZenCODESetupQuickAction {
    let title: String
    let detail: String?
    private let action: () async throws -> ZenCODESetupQuickActionResult

    public init(
        title: String,
        detail: String? = nil,
        action: @escaping () async throws -> ZenCODESetupQuickActionResult
    ) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    func run() async throws -> ZenCODESetupQuickActionResult {
        try await action()
    }
}

public struct ZenCODESetupAdditionalSection {
    let title: String
    let detail: String?
    let aliases: Set<String>
    private let action: () async throws -> ZenCODESetupAdditionalSectionResult

    public init(
        title: String,
        detail: String? = nil,
        aliases: Set<String> = [],
        action: @escaping () async throws -> ZenCODESetupAdditionalSectionResult
    ) {
        self.title = title
        self.detail = detail
        self.aliases = aliases
        self.action = action
    }

    func run() async throws -> ZenCODESetupAdditionalSectionResult {
        try await action()
    }
}

public struct ZenCODESetupAdditionalSectionGroup {
    let title: String
    let detail: String?
    let aliases: Set<String>
    let placement: ZenCODESetupAdditionalSectionGroupPlacement
    let prefersBackDefault: Bool
    let sections: [ZenCODESetupAdditionalSection]

    public init(
        title: String,
        detail: String? = nil,
        aliases: Set<String> = [],
        placement: ZenCODESetupAdditionalSectionGroupPlacement = .afterAgents,
        prefersBackDefault: Bool = false,
        sections: [ZenCODESetupAdditionalSection]
    ) {
        self.title = title
        self.detail = detail
        self.aliases = aliases
        self.placement = placement
        self.prefersBackDefault = prefersBackDefault
        self.sections = sections
    }
}

public enum ZenCODESetupAdditionalSectionGroupPlacement {
    case afterAgents
    case afterVoice
}

public enum ZenCODESetupRunner {
    public static func run(
        arguments: [String],
        additionalSectionGroups: [ZenCODESetupAdditionalSectionGroup] = [],
        quickActions: [ZenCODESetupQuickAction] = []
    ) async throws {
        _ = arguments
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
        var originalManifest: AgentSettingsManifest?
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
                originalManifest = loadedManifest
                manifest = loadedManifest
            }
        }

        if manifest == nil {
            AgentOutput.standardError.writeString(
                "No valid settings.json found. Quick setup can configure local MLX, remote providers, or both.\n\n"
            )
        }

        var didChangeSettings = false
        var didRunAdditionalSection = false
        var shouldOpenSetupMenu = true

                if manifest == nil,
           try promptQuickSetupMode() {
            manifest = try await runQuickSetup(
                currentManifest: manifest,
                quickActions: quickActions
            )
            didChangeSettings = true
            shouldOpenSetupMenu = false
        }

        while shouldOpenSetupMenu {
            let section = try promptSetupSection(
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            if section == .finish {
                break
            }
            if section == .cancel {
                AgentOutput.standardError.writeString("Setup changes were not saved.\n")
                return
            }

            let previousManifest = manifest
            let result = try await configureSetupSection(
                section,
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            if result.additionalResult == .removedStandaloneConfiguration {
                manifest = nil
                originalManifest = nil
                didChangeSettings = false
                didRunAdditionalSection = true
            } else if section.isAdditional {
                manifest = result.manifest
                didRunAdditionalSection = true
            } else if result.manifest != previousManifest {
                manifest = result.manifest
                didChangeSettings = true
            } else {
                manifest = result.manifest
            }
        }

        guard let finalManifest = manifest else {
            if didRunAdditionalSection {
                printCompletion()
                return
            }
            throw ZenCODESetupError.noModelsConfigured
        }

        let shouldWriteSettings = didChangeSettings
            || originalManifest == nil
            || finalManifest != originalManifest
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

    static func printCompletion() {
        AgentOutput.standardError.writeString("\nSetup completed.\n\n")
    }

    static func promptQuickSetupMode() throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(
                value: true,
                title: "Quick setup",
                detail: "recommended path to start coding"
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
        currentManifest existingManifest: AgentSettingsManifest?,
        quickActions: [ZenCODESetupQuickAction]
    ) async throws -> AgentSettingsManifest {
        AgentOutput.standardError.writeString(
            """

            Quick setup configures the essentials automatically.
            Advanced options like Telegram and voice can be enabled later from zen --setup.

            """
        )

        let quickActionResults = try await runQuickSetupActions(quickActions)
        let configuredStandaloneRuntime = quickActionResults.contains { result in
            if case .configuredStandaloneRuntime = result {
                return true
            }
            return false
        }

        let shouldConfigureRemoteProviders: Bool
        if configuredStandaloneRuntime {
            shouldConfigureRemoteProviders = try promptYesNo(
                "Configure a remote provider now?",
                defaultValue: false,
                help: "Choose No for a local-only setup. You can add remote providers later with zen --setup."
            )
        } else {
            shouldConfigureRemoteProviders = true
        }

        let manifest: AgentSettingsManifest
        if shouldConfigureRemoteProviders {
            var configuredManifest = try await configureProvidersAndModels(existingManifest: existingManifest)
            configuredManifest = try configureDefaultModel(in: configuredManifest)
            manifest = configuredManifest
        } else {
            manifest = localOnlyManifest(preservingOptionalSettingsFrom: existingManifest)
        }

        try ZenCODEAgentProfileSetupRunner.configureInteractively()
        printQuickActionResults(quickActionResults)
        return manifest
    }


    static func runQuickSetupActions(
        _ quickActions: [ZenCODESetupQuickAction]
    ) async throws -> [ZenCODESetupQuickActionResult] {
        var results: [ZenCODESetupQuickActionResult] = []
        for action in quickActions {
            let detail = action.detail.map { " (\($0))" } ?? ""
            guard try promptYesNo(
                "Configure \(action.title)\(detail) now?",
                defaultValue: true
            ) else {
                continue
            }
            results.append(try await action.run())
        }
        return results
    }

    static func localOnlyManifest(
        preservingOptionalSettingsFrom existingManifest: AgentSettingsManifest?
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            version: existingManifest?.version ?? AgentSettingsManifest.currentVersion,
            models: [],
            telegram: existingManifest?.telegram,
            voice: existingManifest?.voice,
            localExecAllowedCommands: existingManifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: existingManifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: existingManifest?.anthropicSubscriptionCredentials
        )
    }

    static func printQuickActionResults(_ results: [ZenCODESetupQuickActionResult]) {
        let hints = results.compactMap { result -> String? in
            guard case let .configuredStandaloneRuntime(usageHint, _) = result else {
                return nil
            }
            return usageHint
        }
        guard !hints.isEmpty else {
            return
        }
        AgentOutput.standardError.writeString("\n")
        for hint in hints {
            AgentOutput.standardError.writeString("\(hint)\n")
        }
    }

        static func requireExistingManifest(
        _ manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        guard let manifest else {
            throw ZenCODESetupError.noModelsConfigured
        }
        return manifest
    }


    static func configureSetupSection(
        _ section: SetupSection,
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [ZenCODESetupAdditionalSectionGroup]
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
                additionalSectionGroups: additionalSectionGroups
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
            return SetupSectionConfigurationResult(
                manifest: try requireExistingManifest(manifest)
            )
        case .additionalGroup(let index, _, _):
            guard additionalSectionGroups.indices.contains(index) else {
                throw ZenCODESetupError.invalidChoice(String(index + 1))
            }
            guard let additionalSection = try promptAdditionalSetupSection(
                in: additionalSectionGroups[index]
            ) else {
                return SetupSectionConfigurationResult(manifest: manifest)
            }
            let result = try await additionalSection.run()
            return SetupSectionConfigurationResult(
                manifest: manifest,
                additionalResult: result
            )
        case .finish, .cancel:
            return SetupSectionConfigurationResult(manifest: manifest)
        }
    }
}
