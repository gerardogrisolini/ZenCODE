//
//  VoiceModeSetupTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct VoiceModeSetupTests {
    @Test
    func voiceModeIsAnOptionalSectionThatNeedsNoModels() {
        #expect(SetupSection.voiceMode.title == "Voice mode")
        #expect(SetupSection.voiceMode.category == .optional)
        #expect(!SetupSection.voiceMode.requiresConfiguredModels)
        #expect(SetupSection.voiceMode.matches("voice"))
        #expect(SetupSection.voiceMode.matches("voice mode"))
        #expect(!SetupSection.voiceMode.matches("telegram"))
    }

    @Test
    func voiceModeIsOfferedOnLinuxAndMacOS() {
        let options = ZenCODESetupRunner.setupSectionOptions(currentManifest: nil)
        #if os(Linux) || os(macOS)
        #expect(options.map(\.section).contains(.voiceMode))
        #else
        #expect(!options.map(\.section).contains(.voiceMode))
        #endif
        #if os(macOS)
        // macOS downloads nothing: the section only picks the reading voice.
        #expect(options.first { $0.section == .voiceMode }?.detail == "automatic voice")
        #expect(ZenCODESetupRunner.setupSectionReadinessMarker(for: .voiceMode, currentManifest: nil) == "[-]")
        #endif
    }

    @Test
    func voicesFollowTheLanguageAndFallBackToEveryVoice() {
        let italian = ZenCODESetupRunner.voiceModeChoices(languageCode: "it")
        #expect(italian.matchesLanguage)
        #expect(italian.voices.map(\.speaker) == ["dii", "miro", "paola", "riccardo"])

        let unknown = ZenCODESetupRunner.voiceModeChoices(languageCode: "ja")
        #expect(!unknown.matchesLanguage)
        #expect(unknown.voices == SherpaOnnxVoiceCatalog.voices)
    }

    @Test
    func menuListsVoicesWithSizeAndOffersRemovalOnlyWhenFilesExist() throws {
        let installation = SherpaOnnxVoiceInstallation(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZenCODE-voice-setup-\(UUID().uuidString)/voice", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: installation.directoryURL.deletingLastPathComponent()) }
        let voices = SherpaOnnxVoiceCatalog.voices(forLanguage: "it")

        let fresh = ZenCODESetupRunner.voiceModeMenuItems(voices: voices, installation: installation)
        #expect(fresh.map(\.value) == voices.map { .voice($0.id) } + [.back])
        let paola = try #require(fresh.first { $0.title == "paola" })
        #expect(paola.detail == "it_IT · medium · 67 MB")
        #expect(fresh.first { $0.title == "riccardo" }?.detail == "it_IT · x low · 26 MB")
        #expect(ZenCODESetupRunner.voiceModeSetupDetail(installation: installation) == "not installed")

        let installedVoice = try #require(voices.first { $0.speaker == "paola" })
        try FileManager.default.createDirectory(
            at: installation.installedURL(for: installedVoice.asset),
            withIntermediateDirectories: true
        )
        let installed = ZenCODESetupRunner.voiceModeMenuItems(voices: voices, installation: installation)
        #expect(installed.first { $0.title == "paola" }?.detail == "it_IT · medium · 67 MB · installed")
        #expect(installed.map(\.value).suffix(2) == [.remove, .back])
        #expect(ZenCODESetupRunner.voiceModeSetupDetail(installation: installation) == "incomplete download")
    }

    @Test
    func sizesAreShownInWholeMegabytes() {
        #expect(ZenCODESetupRunner.megabytes(487_170_055) == "487 MB")
        #expect(ZenCODESetupRunner.megabytes(643_854) == "1 MB")
    }
}
