//
//  ZenCODESetupSessionTests.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@testable import ZenCODESetup
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
}
