//
//  ZenCODESetupSessionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODESetupSessionTests {
    private static func manifest(
        models: [AgentSettingsModelManifest],
        commands: [String] = []
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            models: models,
            localExecAllowedCommands: commands
        )
    }

    private static func emptyManifest(commands: [String] = []) -> AgentSettingsManifest {
        manifest(models: [], commands: commands)
    }

    private static func remoteManifest(commands: [String] = []) -> AgentSettingsManifest {
        let providerID = UUID()
        let modelID = "test-model"
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "Test provider",
            baseURL: "https://example.invalid/v1",
            modelID: modelID
        )
        let model = AgentSettingsModelManifest(
            id: "remote:test-model",
            kind: .remoteAPI,
            modelID: modelID,
            providerID: providerID,
            provider: provider
        )
        return manifest(models: [model], commands: commands)
    }

    @Test
    func startupSetupRequirementRejectsMissingInvalidAndModelFreeConfiguration() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings.json")

        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: nil,
                status: .missingSettings(settingsFileURL: settingsURL)
            )
        )
        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: Self.emptyManifest(),
                status: .ready(settingsFileURL: settingsURL)
            )
        )
        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: Self.remoteManifest(),
                status: .invalidSettings(
                    settingsFileURL: settingsURL,
                    message: "invalid"
                )
            )
        )
        #expect(
            !ZenCODESetupRequirement.isRequired(
                manifest: Self.remoteManifest(),
                status: .ready(settingsFileURL: settingsURL)
            )
        )
    }

    @Test
    func freshSessionWithoutManifestReportsNoModels() {
        let session = SetupSession(originalManifest: nil)

        #expect(session.manifest == nil)
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .noModels)
    }

    @Test
    func existingManifestWithoutModelsReportsNoModels() {
        let empty = Self.emptyManifest(commands: ["ls"])
        let session = SetupSession(originalManifest: empty)

        #expect(session.manifest == empty)
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .noModels)
    }

    @Test
    func quickSetupMarksRemoteSettingsChangedAndWrites() {
        var session = SetupSession(originalManifest: nil)
        let configured = Self.remoteManifest(commands: ["ls"])

        session.applyQuickSetup(configured)

        #expect(session.manifest == configured)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: configured, settingsWillBeWritten: true))
    }

    @Test
    func unchangedSectionOnExistingManifestDoesNotForceWrite() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)

        session.apply(SetupSectionConfigurationResult(manifest: original))

        #expect(session.manifest == original)
        // Nothing changed and settings already existed, so no rewrite is forced.
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .write(manifest: original, settingsWillBeWritten: false))
    }

    @Test
    func sectionThatMutatesManifestMarksSettingsChanged() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let mutated = Self.manifest(
            models: original.models,
            commands: ["ls", "cat"]
        )

        session.apply(SetupSectionConfigurationResult(manifest: mutated))

        #expect(session.manifest == mutated)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: mutated, settingsWillBeWritten: true))
    }

    @Test
    func quickSetupChangeSurvivesAnUnchangedSection() {
        // The change flag from quick setup must survive an unchanged section.
        var session = SetupSession(originalManifest: nil)
        let configured = Self.remoteManifest(commands: ["ls"])
        session.applyQuickSetup(configured)

        session.apply(SetupSectionConfigurationResult(manifest: configured))

        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: configured, settingsWillBeWritten: true))
    }

    @Test
    func clearingAllModelsCannotProduceAWritableOutcome() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let empty = Self.emptyManifest(commands: ["ls"])

        session.apply(SetupSectionConfigurationResult(manifest: empty))

        #expect(session.manifest == empty)
        #expect(session.outcome == .noModels)
    }

    @Test
    func remoteResetIsAvailableWithoutConfiguredModels() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        #expect(options.contains { $0.section == .resetRemoteConfiguration })
        #expect(!SetupSection.resetRemoteConfiguration.requiresConfiguredModels)
        #expect(SetupSection.resetRemoteConfiguration.title == "Reset remote configuration")
    }

    @Test
    func responseLanguageSectionIsAvailableWithoutConfiguredModels() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)

        #expect(options.contains { $0.section == .responseLanguage })
        #expect(!SetupSection.responseLanguage.requiresConfiguredModels)
        #expect(SetupSection.responseLanguage.category == .recommended)
        #expect(SetupSection.responseLanguage.title == "Response language")
        // A configured language is reflected in the menu detail.
        let withLanguage = AgentSettingsManifest(models: [], responseLanguage: "it")
        #expect(
            ZenCODESetupRunner.responseLanguageSetupDetail(withLanguage) == "Italian"
        )
        #expect(
            ZenCODESetupRunner.responseLanguageSetupDetail(nil) == "system default"
        )
    }

    @Test
    func updatingResponseLanguagePreservesExistingSettings() {
        let original = Self.remoteManifest(commands: ["ls"])
        let updated = ZenCODESetupRunner.manifestByUpdatingResponseLanguage(
            original,
            responseLanguage: "es"
        )

        #expect(updated.responseLanguage == "es")
        #expect(updated.providers == original.providers)
        #expect(updated.models == original.models)
        #expect(updated.selectedModelID == original.selectedModelID)
        #expect(updated.localExecAllowedCommands == original.localExecAllowedCommands)
    }

    @Test
    func responseLanguageChangeMarksSettingsChanged() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let mutated = ZenCODESetupRunner.manifestByUpdatingResponseLanguage(
            original,
            responseLanguage: "fr"
        )

        session.apply(SetupSectionConfigurationResult(manifest: mutated))

        #expect(session.manifest?.responseLanguage == "fr")
        #expect(session.shouldWriteSettings)
    }

    @Test
    func stagedSubscriptionCredentialsSurviveASecondProviderPass() {
        let oldCredentials = CodexAgentCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: Date(timeIntervalSince1970: 1),
            accountID: "old-account"
        )
        let stagedCredentials = CodexAgentCredentials(
            accessToken: "staged-access",
            refreshToken: "staged-refresh",
            expiresAt: Date(timeIntervalSince1970: 2),
            accountID: "staged-account"
        )
        let provider = AgentSettingsProviderManifest(
            id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            name: "ChatGPT Subscription",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
            chatEndpoint: .responses
        )
        let preservedInput = ZenCODESetupRunner.preserveProviderInput(
            provider: provider,
            models: [],
            apiKey: nil,
            chatGPTSubscriptionCredentials: stagedCredentials
        )
        let resolved = ZenCODESetupRunner.subscriptionCredentials(
            from: [preservedInput],
            fallback: (chatGPT: oldCredentials, anthropic: nil)
        )

        #expect(preservedInput.chatGPTSubscriptionCredentials?.accessToken == "staged-access")
        #expect(resolved.chatGPT?.accessToken == "staged-access")
        #expect(resolved.chatGPT?.refreshToken == "staged-refresh")
    }

    @Test
    func remoteResetRemovesProvidedConfigurationFilesOnce() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let settingsURL = directory.appendingPathComponent("settings.json")
        let profilesURL = directory.appendingPathComponent("agents.json")
        let missingURL = directory.appendingPathComponent("missing.json")
        try Data("settings".utf8).write(to: settingsURL)
        try Data("profiles".utf8).write(to: profilesURL)

        let result = try ZenCODESetupRunner.resetRemoteConfiguration(
            fileManager: fileManager,
            configurationURLs: [settingsURL, settingsURL, profilesURL, missingURL]
        )

        #expect(result.removedURLs == [settingsURL.standardizedFileURL, profilesURL.standardizedFileURL])
        #expect(result.missingURLs == [missingURL.standardizedFileURL])
        #expect(!fileManager.fileExists(atPath: settingsURL.path))
        #expect(!fileManager.fileExists(atPath: profilesURL.path))
    }

    @Test
    func remoteResetRestoresEarlierRemovalsWhenALaterStepFails() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let settingsURL = directory.appendingPathComponent("settings.json")
        let profilesURL = directory.appendingPathComponent("agents.json")
        let settingsData = Data("settings".utf8)
        let profilesData = Data("profiles".utf8)
        try settingsData.write(to: settingsURL)
        try profilesData.write(to: profilesURL)

        #expect(throws: CancellationError.self) {
            try ZenCODESetupRunner.resetRemoteConfiguration(
                fileManager: fileManager,
                configurationURLs: [settingsURL, profilesURL],
                removalCheckpoint: { completedRemovals in
                    if completedRemovals == 1 { throw CancellationError() }
                }
            )
        }

        #expect(try Data(contentsOf: settingsURL) == settingsData)
        #expect(try Data(contentsOf: profilesURL) == profilesData)
    }
}
