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
    // Two distinct, equatable manifests used to detect "changed" transitions
    // without touching the terminal.
    private static func manifest(commands: [String] = []) -> AgentSettingsManifest {
        AgentSettingsManifest(
            models: [],
            localExecAllowedCommands: commands
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
    func quickSetupMarksSettingsChangedAndWrites() {
        var session = SetupSession(originalManifest: nil)
        let configured = Self.manifest(commands: ["ls"])

        session.applyQuickSetup(configured)

        #expect(session.manifest == configured)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: configured, settingsWillBeWritten: true))
    }

    @Test
    func unchangedSectionOnExistingManifestDoesNotForceWrite() {
        let original = Self.manifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)

        session.apply(
            section: .telegram,
            result: SetupSectionConfigurationResult(manifest: original)
        )

        #expect(session.manifest == original)
        // Nothing changed and settings already existed, so no rewrite is forced.
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .write(manifest: original, settingsWillBeWritten: false))
    }

    @Test
    func sectionThatMutatesManifestMarksSettingsChanged() {
        let original = Self.manifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let mutated = Self.manifest(commands: ["ls", "cat"])

        session.apply(
            section: .telegram,
            result: SetupSectionConfigurationResult(manifest: mutated)
        )

        #expect(session.manifest == mutated)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: mutated, settingsWillBeWritten: true))
    }

    @Test
    func loadedManifestWithoutChangesStillWritesWhenNoOriginalExisted() {
        // Simulates quick setup producing a manifest then a no-op section: the
        // change flag from quick setup must survive an unchanged section.
        var session = SetupSession(originalManifest: nil)
        let configured = Self.manifest(commands: ["ls"])
        session.applyQuickSetup(configured)

        session.apply(
            section: .voice,
            result: SetupSectionConfigurationResult(manifest: configured)
        )

        #expect(session.shouldWriteSettings)
    }

    @Test
    func additionalSectionMarksAdditionalRunWithoutForcingChange() {
        let original = Self.manifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let additional: SetupSection = .additionalGroup(0, title: "Extra", aliases: [])

        session.apply(
            section: additional,
            result: SetupSectionConfigurationResult(manifest: original)
        )

        #expect(session.manifest == original)
        // An additional section that returns the same manifest is not a change.
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .write(manifest: original, settingsWillBeWritten: false))
    }

    @Test
    func removedStandaloneConfigurationResetsManifestAndReportsAdditionalOnly() {
        let original = Self.manifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let additional: SetupSection = .additionalGroup(0, title: "Extra", aliases: [])

        session.apply(
            section: additional,
            result: SetupSectionConfigurationResult(
                manifest: original,
                additionalResult: .removedStandaloneConfiguration
            )
        )

        #expect(session.manifest == nil)
        #expect(session.shouldWriteSettings == false)
        // Additional work ran, so setup completes instead of throwing noModels.
        #expect(session.outcome == .additionalOnly)
    }

    @Test
    func removedStandaloneConfigurationClearsPriorChangeFlag() {
        // Even if a settings change was recorded earlier, removing a standalone
        // configuration returns to a clean, model-less state.
        var session = SetupSession(originalManifest: nil)
        session.applyQuickSetup(Self.manifest(commands: ["ls"]))
        let additional: SetupSection = .additionalGroup(0, title: "Extra", aliases: [])

        session.apply(
            section: additional,
            result: SetupSectionConfigurationResult(
                manifest: nil,
                additionalResult: .removedStandaloneConfiguration
            )
        )

        #expect(session.manifest == nil)
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .additionalOnly)
    }
}
