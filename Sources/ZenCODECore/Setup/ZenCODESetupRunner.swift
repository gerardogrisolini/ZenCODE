//
//  ZenCODESetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ZenCODESetupRunner {
    /// Runs the interactive setup of `zen` (first run) and `/setup`.
    ///
    /// Esc on any prompt returns to the menu that opened that step, with the
    /// step discarded and the changes staged by other sections kept. Esc on a
    /// menu that has Done or Back discards the changes made in that menu
    /// during the visit. Only Esc on the first menu (the main setup menu, the
    /// Quick/Custom mode menu, or the prompt to rewrite an invalid
    /// settings.json) leaves setup, with `.cancelled`.
    ///
    /// It never throws `ZenCODESetupError.cancelled`: the callers end the
    /// process on an error, so a cancel that still reached this point used to
    /// close ZenCODE from `/setup`.
    public static func run() async throws -> SetupOutcome {
        do {
            return try await runInteractiveSetup()
        } catch ZenCODESetupError.cancelled {
            // Last resort: every menu handles its own Esc.
            printSetupNotSaved()
            return .cancelled
        }
    }

    private static func runInteractiveSetup() async throws -> SetupOutcome {
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
                // The first menu of this run: Esc leaves setup with
                // settings.json untouched.
                guard let rewrite = try returningToMenuOnCancel(nil, {
                    try promptYesNo(
                        "settings.json exists but is invalid. Rewrite it?",
                        defaultValue: true
                    )
                }) else {
                    printSetupNotSaved()
                    return .cancelled
                }
                guard rewrite else {
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

        if session.manifest?.models.isEmpty != false {
            modeMenu: while true {
                // The first menu of this run: Esc leaves setup.
                guard let useQuickSetup = try returningToMenuOnCancel(nil, {
                    try promptQuickSetupMode()
                }) else {
                    printSetupNotSaved()
                    return .cancelled
                }
                guard useQuickSetup else {
                    break modeMenu
                }
                switch try await runQuickSetup(session: &session) {
                case .completed:
                    shouldOpenSetupMenu = false
                    break modeMenu
                case .incomplete:
                    break modeMenu
                case .providersCancelled:
                    continue modeMenu
                }
            }
        }

        while shouldOpenSetupMenu {
            // Read before the menu opens: the menu itself is synchronous.
            let zenCRON = await ZenCRONSetupStatus.load()
            let section = try promptSetupSection(
                currentManifest: session.manifest,
                zenCRON: zenCRON
            )
            if section == .finish {
                break
            }
            if section == .cancel {
                printSetupNotSaved()
                return .cancelled
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

            try await runSetupSection(section, session: &session)
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
            // Only now, with the settings saved and the registry reset, so the
            // stores open with the new provider; a cancelled setup never
            // reaches this point.
            await offerMemoryReembeddingAfterSetup(
                originalSettings: session.originalManifest?.memoryEmbedding,
                finalManifest: finalManifest
            )
            printCompletion()
            return .configured
        }
    }

    static func printCompletion() {
        AgentOutput.standardError.writeString("\nSetup completed.\n\n")
    }

    static func printSetupNotSaved() {
        AgentOutput.standardError.writeString("Setup changes were not saved.\n")
    }

    /// Runs one section of the main setup menu and folds its result into
    /// `session`.
    ///
    /// Esc inside the section (`ZenCODESetupError.cancelled`) or another error
    /// discards that pass: `session` is left as it was, a message says so
    /// (see ``reportInterruptedSetupStep(_:title:stagesSettings:write:)``) and
    /// setup goes back to the main menu. Changes staged by other sections are
    /// kept. For a section that acts immediately
    /// (``SetupSection/stagesSettings`` is `false`) the message says that the
    /// actions already applied are kept. A `CancellationError`, or any error
    /// once the task is cancelled, propagates. `configure` replaces the
    /// section prompts in tests.
    static func runSetupSection(
        _ section: SetupSection,
        session: inout SetupSession,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        configure: (
            SetupSection,
            AgentSettingsManifest?,
            [AgentProfile]?
        ) async throws -> SetupSectionConfigurationResult = {
            try await configureSetupSection(
                $0,
                currentManifest: $1,
                currentAgentProfiles: $2
            )
        }
    ) async throws {
        do {
            let result = try await configure(
                section,
                session.manifest,
                session.agentProfiles
            )
            session.apply(result)
        } catch {
            try reportInterruptedSetupStep(
                error,
                title: section.title,
                stagesSettings: section.stagesSettings,
                write: write
            )
        }
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

    /// How quick setup ended.
    enum QuickSetupOutcome: Equatable {
        /// Every step completed: setup finishes without the main menu.
        case completed
        /// Providers and models was cancelled or failed: nothing is staged
        /// and the Quick/Custom mode menu opens again.
        case providersCancelled
        /// A later step was cancelled or failed: the steps already completed
        /// stay staged and the main setup menu opens.
        case incomplete
    }

    static let quickSetupIncompleteNotice =
        "Quick setup stopped: the completed steps are kept. Continue from the setup menu, then choose Finish setup.\n\n"

    /// Quick setup: providers and models, then the response language, then
    /// the agents. Each step is staged in `session` as soon as it completes,
    /// so Esc (or an error) in a step discards only that step: in Providers
    /// and models nothing is staged and the mode menu opens again; in a
    /// later step the completed ones are kept and the main menu opens. A
    /// `CancellationError` propagates. The step closures replace the prompts
    /// in tests.
    static func runQuickSetup(
        session: inout SetupSession,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        configureProviders: (AgentSettingsManifest?) async throws -> AgentSettingsManifest = {
            try await configureProvidersAndModels(existingManifest: $0)
        },
        configureLanguage: (AgentSettingsManifest) throws -> AgentSettingsManifest = {
            try configureResponseLanguage(existingManifest: $0)
        },
        configureAgents: () throws -> [AgentProfile] = {
            try ZenCODEAgentProfileSetupRunner.configureInteractively(
                currentAgents: nil,
                persist: false
            )
        }
    ) async throws -> QuickSetupOutcome {
        write(
            """

            Quick setup configures a remote provider and its models.
            Advanced options like Telegram can be enabled later with /setup.

            """
        )

        let providersManifest: AgentSettingsManifest
        do {
            providersManifest = try await configureProviders(session.manifest)
        } catch {
            try reportInterruptedSetupStep(
                error,
                title: SetupSection.providersAndModels.title,
                write: write
            )
            return .providersCancelled
        }
        session.applyQuickSetup(providersManifest)

        let languageManifest: AgentSettingsManifest
        do {
            languageManifest = try configureLanguage(providersManifest)
        } catch {
            try reportInterruptedSetupStep(
                error,
                title: SetupSection.responseLanguage.title,
                write: write
            )
            write(quickSetupIncompleteNotice)
            return .incomplete
        }
        session.applyQuickSetup(languageManifest)

        let agentProfiles: [AgentProfile]
        do {
            agentProfiles = try configureAgents()
        } catch {
            try reportInterruptedSetupStep(
                error,
                title: SetupSection.agents.title,
                write: write
            )
            write(quickSetupIncompleteNotice)
            return .incomplete
        }
        session.applyQuickSetup(languageManifest, agentProfiles: agentProfiles)
        return .completed
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
        case .telegram:
            return SetupSectionConfigurationResult(
                manifest: try await configureTelegram(in: requireExistingManifest(manifest))
            )
        case .features:
            try await configureFeatures()
            return SetupSectionConfigurationResult(manifest: manifest)
        case .scheduledPrompts:
            await configureScheduledPrompts()
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
                manifest: try await configureMemoryEmbedding(in: manifest)
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
        case .dataManagement, .finish, .cancel:
            return SetupSectionConfigurationResult(manifest: manifest)
        case .ds4Runtime:
            return SetupSectionConfigurationResult(
                manifest: try await configureDS4Runtime(existingManifest: manifest)
            )
        case .voiceMode:
            #if os(macOS)
            return SetupSectionConfigurationResult(
                manifest: configureSpeechVoiceWithPreview(manifest: manifest)
            )
            #else
            return SetupSectionConfigurationResult(
                manifest: try await configureVoiceMode(manifest: manifest)
            )
            #endif
        }
    }
}
