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
        #expect(fresh.map(\.value) == [.sendMode] + voices.map { .voice($0.id) } + [.back])
        #expect(fresh[0].title == "Send mode")
        #expect(fresh[0].detail == "after 5 s of silence")
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
}
