//
//  MacOSVoiceModeSetupTests.swift
//  ZenCODECoreTests
//
//  The reading-voice choice of `/setup` > Voice mode on macOS. The helpers
//  are platform neutral, so these run everywhere with fixture voices.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MacOSVoiceModeSetupTests {
    typealias Voices = SystemSpeechVoiceCatalogTests
    typealias Action = ZenCODESetupRunner.SpeechVoiceAction

    static func manifest(
        voice: AgentVoiceSettingsManifest? = nil,
        responseLanguage: String? = "it"
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            models: [],
            voice: voice,
            localExecAllowedCommands: ["git status"],
            responseLanguage: responseLanguage
        )
    }

    /// Runs the section with a scripted menu answer.
    static func configure(
        _ manifest: AgentSettingsManifest?,
        answer: ([TerminalCheckboxMenuItem<Action>], Action) -> Action?
    ) -> (manifest: AgentSettingsManifest?, output: String) {
        var output = ""
        let result = ZenCODESetupRunner.configureSpeechVoice(
            manifest: manifest,
            installedVoices: Voices.installed,
            write: { output += $0 },
            selectOne: { _, items, selected in answer(items, selected) }
        )
        return (result, output)
    }

    @Test
    func localeFollowsTheResponseLanguage() {
        #expect(ZenCODESetupRunner.speechVoiceLocaleIdentifier(manifest: Self.manifest()) == "it-IT")
        #expect(
            ZenCODESetupRunner.speechVoiceLocaleIdentifier(manifest: Self.manifest(responseLanguage: "fr"))
                == "fr-FR"
        )
        // Telegram transcription no longer carries a language of its own.
        let telegramVoice = AgentVoiceSettingsManifest(enabled: true)
        #expect(
            ZenCODESetupRunner.speechVoiceLocaleIdentifier(manifest: Self.manifest(voice: telegramVoice))
                == "it-IT"
        )
    }

    @Test
    func menuListsAutomaticThenTheVoicesOfTheLanguage() throws {
        let items = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "it-IT"
        )
        #expect(items.map(\.value) == [
            .automatic,
            .voice(Voices.federica.identifier),
            .voice(Voices.luca.identifier),
            .voice(Voices.alice.identifier),
            .back
        ])
        #expect(items.first?.title == "Automatic")
        #expect(items.first?.detail == "best installed voice, now Federica (it-IT · premium)")
        let luca = try #require(items.first { $0.value == .voice(Voices.luca.identifier) })
        #expect(luca.title == "Luca")
        #expect(luca.detail == "it-IT · enhanced")
        #expect(items.last?.title == "Back")

        let none = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "ja-JP"
        )
        #expect(none.map(\.value) == [.automatic, .back])
        #expect(none.first?.detail == "system default voice for ja-JP")
    }

    @Test
    func choosingAVoiceStagesItAndKeepsTelegramTranscription() throws {
        let telegramVoice = AgentVoiceSettingsManifest(enabled: true)
        let original = Self.manifest(voice: telegramVoice)
        var offered: [TerminalCheckboxMenuItem<Action>] = []
        var preselected: Action?
        let result = Self.configure(original) { items, selected in
            offered = items
            preselected = selected
            return .voice(Voices.luca.identifier)
        }
        #expect(preselected == .automatic)
        #expect(offered.count == 5)
        let manifest = try #require(result.manifest)
        #expect(manifest.voice == AgentVoiceSettingsManifest(
            enabled: true,
            macOSVoiceIdentifier: Voices.luca.identifier
        ))
        #expect(manifest.responseLanguage == "it")
        #expect(manifest.localExecAllowedCommands == ["git status"])
        #expect(result.output.contains("Siri voices are not available to other apps"))
        #expect(result.output.contains("Current: automatic voice"))
        #expect(result.output.contains("Reading voice: Luca (it-IT)."))

        // Saved with the other settings.
        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded.voice == manifest.voice)
        #expect(reloaded.responseLanguage == "it")
    }

    @Test
    func automaticClearsTheSavedVoice() throws {
        let saved = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.alice.identifier
        ))
        var preselected: Action?
        let cleared = Self.configure(saved) { _, selected in
            preselected = selected
            return .automatic
        }
        #expect(preselected == .voice(Voices.alice.identifier))
        #expect(cleared.output.contains("Current: voice Alice (it-IT)"))
        // Nothing else to keep: the voice settings disappear.
        #expect(try #require(cleared.manifest).voice == nil)

        let withTelegram = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: true,
            macOSVoiceIdentifier: Voices.alice.identifier
        ))
        let kept = Self.configure(withTelegram) { _, _ in .automatic }
        #expect(try #require(kept.manifest).voice == AgentVoiceSettingsManifest(enabled: true))
    }

    @Test
    func backEscapeAndUnchangedChoicesKeepTheManifest() {
        let saved = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.federica.identifier
        ))
        #expect(Self.configure(saved) { _, _ in .back }.manifest == saved)
        #expect(Self.configure(saved) { _, _ in nil }.manifest == saved)
        #expect(Self.configure(saved) { _, _ in .voice(Voices.federica.identifier) }.manifest == saved)
        // Without settings, Automatic creates none.
        #expect(Self.configure(nil) { _, _ in .automatic }.manifest == nil)
    }

    @Test
    func savedVoiceOfAnotherLanguageIsNotPreselected() {
        let saved = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.samantha.identifier
        ))
        var preselected: Action?
        let result = Self.configure(saved) { _, selected in
            preselected = selected
            return .back
        }
        #expect(preselected == .automatic)
        #expect(result.output.contains("Current: automatic voice (saved voice unavailable)"))
    }

    @Test
    func detailAndMarkerReflectTheVoiceInUse() {
        func detail(_ identifier: String?) -> String {
            ZenCODESetupRunner.speechVoiceSetupDetail(
                manifest: Self.manifest(voice: AgentVoiceSettingsManifest(
                    enabled: false,
                    macOSVoiceIdentifier: identifier
                )),
                lookup: Voices.lookup
            )
        }
        #expect(detail(nil) == "automatic voice")
        #expect(detail(Voices.federica.identifier) == "voice Federica (it-IT)")
        #expect(detail("com.apple.voice.premium.it-IT.Removed") == "automatic voice (saved voice unavailable)")
        #expect(detail(Voices.samantha.identifier) == "automatic voice (saved voice unavailable)")

        let chosen = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.federica.identifier
        ))
        #expect(ZenCODESetupRunner.speechVoiceIsChosen(manifest: chosen, lookup: Voices.lookup))
        #expect(!ZenCODESetupRunner.speechVoiceIsChosen(manifest: Self.manifest(), lookup: Voices.lookup))
    }
}
