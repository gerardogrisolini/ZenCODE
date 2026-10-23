//
//  MacOSVoicePreviewSetupTests.swift
//  ZenCODECoreTests
//
//  The audio preview of `/setup` > Voice mode on macOS. A recording player
//  replaces the synthesizer, so these tests play no audio.
//

#if os(macOS)
import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MacOSVoicePreviewSetupTests {
    typealias Voices = SystemSpeechVoiceCatalogTests
    typealias Action = ZenCODESetupRunner.SpeechVoiceAction
    typealias PreviewAction = ZenCODESetupRunner.SpeechVoicePreviewAction

    final class RecordingPlayer: SpeechVoicePreviewPlaying {
        enum Event: Equatable {
            case play(text: String, voiceIdentifier: String)
            case stop
        }

        var events: [Event] = []
        var isInstalled = true

        func play(_ text: String, voiceIdentifier: String) -> Bool {
            events.append(.play(text: text, voiceIdentifier: voiceIdentifier))
            return isInstalled
        }

        func stop() {
            events.append(.stop)
        }

        var playedVoices: [String] {
            events.compactMap {
                if case let .play(_, voiceIdentifier) = $0 { voiceIdentifier } else { nil }
            }
        }
    }

    struct Run {
        var manifest: AgentSettingsManifest?
        var output = ""
        /// The preselected item of each list shown.
        var listSelections: [Action] = []
        var previewTitles: [String] = []
        var previewItems: [[TerminalCheckboxMenuItem<PreviewAction>]] = []
    }

    /// Runs the section with scripted answers; a menu without answers left
    /// is escaped, so every run ends.
    static func configure(
        _ manifest: AgentSettingsManifest?,
        installedVoices: [SystemSpeechVoice] = Voices.installed,
        player: RecordingPlayer,
        list: [Action?],
        preview: [PreviewAction?] = []
    ) -> Run {
        var run = Run()
        var listAnswers = list[...]
        var previewAnswers = preview[...]
        let manifest = ZenCODESetupRunner.configureSpeechVoiceWithPreview(
            manifest: manifest,
            installedVoices: installedVoices,
            player: player,
            write: { run.output += $0 },
            selectOne: { _, _, selected in
                run.listSelections.append(selected)
                return listAnswers.popFirst() ?? nil
            },
            selectPreview: { title, items, _ in
                run.previewTitles.append(title)
                run.previewItems.append(items)
                return previewAnswers.popFirst() ?? nil
            }
        )
        run.manifest = manifest
        return run
    }

    @Test
    func previewMenuOffersListenUseAndBack() {
        let items = ZenCODESetupRunner.speechVoicePreviewMenuItems(voice: Voices.luca, isAutomatic: false)
        #expect(items.map(\.value) == [.listen, .use, .back])
        #expect(items.map(\.title) == ["▶ Listen", "Use this voice", "Back"])
        #expect(items[0].detail == "play a short sample read by Luca")
        #expect(items[1].detail == "read answers with Luca, saved when setup finishes")
        #expect(items[2].detail == "return to the voice list")

        let automatic = ZenCODESetupRunner.speechVoicePreviewMenuItems(voice: Voices.federica, isAutomatic: true)
        #expect(automatic[1].detail == "keep the automatic choice, saved when setup finishes")
    }

    @Test
    func sampleSaysTheVoiceNameInItsLanguage() {
        #expect(SystemSpeechVoicePreview.sampleText(for: Voices.federica) == "Ciao, sono Federica. Questa è la mia voce.")
        #expect(SystemSpeechVoicePreview.sampleText(for: Voices.daniel) == "Hello, I'm Daniel. This is my voice.")
        // Other languages fall back to English.
        let thomas = SystemSpeechVoice(identifier: "thomas", name: "Thomas", language: "fr-FR", quality: .standard)
        #expect(SystemSpeechVoicePreview.sampleText(for: thomas) == "Hello, I'm Thomas. This is my voice.")
    }

    @Test
    func listenPlaysTheChosenVoiceWithoutStagingIt() {
        let original = MacOSVoiceModeSetupTests.manifest()
        let player = RecordingPlayer()
        let run = Self.configure(
            original,
            player: player,
            list: [.voice(Voices.luca.identifier)],
            preview: [.listen, .back]
        )
        #expect(player.events.contains(.play(
            text: "Ciao, sono Luca. Questa è la mia voce.",
            voiceIdentifier: Voices.luca.identifier
        )))
        #expect(player.playedVoices == [Voices.luca.identifier])
        // The submenu comes back after each sample.
        #expect(run.previewTitles == Array(repeating: "Luca (it-IT · enhanced)", count: 2))
        #expect(run.manifest == original)
        #expect(!run.output.contains("Reading voice:"))
        #expect(run.output.contains("Choose a voice to listen to a sample before using it."))
        // Leaving stops the sample.
        #expect(player.events.last == .stop)
    }

    @Test
    func useStagesTheVoice() throws {
        let player = RecordingPlayer()
        let run = Self.configure(
            MacOSVoiceModeSetupTests.manifest(),
            player: player,
            list: [.voice(Voices.luca.identifier)],
            preview: [.listen, .use]
        )
        let manifest = try #require(run.manifest)
        #expect(manifest.voice == AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.luca.identifier
        ))
        #expect(run.output.contains("Reading voice: Luca (it-IT)."))
        #expect(player.events.last == .stop)

        // Listening is optional.
        let direct = Self.configure(
            MacOSVoiceModeSetupTests.manifest(),
            player: RecordingPlayer(),
            list: [.voice(Voices.alice.identifier)],
            preview: [.use]
        )
        #expect(direct.manifest?.voice?.macOSVoiceIdentifier == Voices.alice.identifier)
    }

    @Test
    func backAndEscapeReturnToTheListWithoutApplying() {
        let saved = MacOSVoiceModeSetupTests.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.federica.identifier
        ))
        let player = RecordingPlayer()
        let run = Self.configure(
            saved,
            player: player,
            list: [.voice(Voices.luca.identifier), .voice(Voices.alice.identifier), .back],
            preview: [.back, nil]
        )
        #expect(run.manifest == saved)
        // The list comes back with the current choice still selected.
        #expect(run.listSelections == Array(repeating: .voice(Voices.federica.identifier), count: 3))
        #expect(run.previewTitles == ["Luca (it-IT · enhanced)", "Alice (it-IT · standard)"])
        #expect(player.playedVoices.isEmpty)

        // A voice used after going back from another one is staged.
        let changed = Self.configure(
            saved,
            player: RecordingPlayer(),
            list: [.voice(Voices.luca.identifier), .voice(Voices.alice.identifier)],
            preview: [.back, .use]
        )
        #expect(changed.manifest?.voice?.macOSVoiceIdentifier == Voices.alice.identifier)
    }

    @Test
    func aNewListenStopsThePreviousSample() {
        let player = RecordingPlayer()
        _ = Self.configure(
            MacOSVoiceModeSetupTests.manifest(),
            player: player,
            list: [.voice(Voices.federica.identifier)],
            preview: [.listen, .listen, .back]
        )
        let sample = RecordingPlayer.Event.play(
            text: "Ciao, sono Federica. Questa è la mia voce.",
            voiceIdentifier: Voices.federica.identifier
        )
        // Each sample is preceded by a stop, and leaving stops the last one.
        #expect(player.events.prefix(5) == [.stop, sample, .stop, sample, .stop])
        #expect(player.events.dropFirst(5).allSatisfy { $0 == .stop })
    }

    @Test
    func automaticPlaysTheVoiceItWouldChoose() throws {
        let saved = MacOSVoiceModeSetupTests.manifest(voice: AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: Voices.alice.identifier
        ))
        let player = RecordingPlayer()
        let back = Self.configure(saved, player: player, list: [.automatic], preview: [.listen, .back])
        #expect(back.previewTitles == Array(repeating: "Automatic: now Federica (it-IT · premium)", count: 2))
        #expect(back.previewItems.first?[1].detail == "keep the automatic choice, saved when setup finishes")
        #expect(player.playedVoices == [Voices.federica.identifier])
        #expect(back.manifest == saved)

        let used = Self.configure(saved, player: RecordingPlayer(), list: [.automatic], preview: [.use])
        #expect(try #require(used.manifest).voice == nil)
        #expect(used.output.contains("Reading voice: automatic."))
    }

    @Test
    func withoutVoicesAutomaticAppliesWithoutPreview() throws {
        let saved = MacOSVoiceModeSetupTests.manifest(
            voice: AgentVoiceSettingsManifest(enabled: true, language: "ja", macOSVoiceIdentifier: "ja-voice"),
            responseLanguage: "ja"
        )
        let player = RecordingPlayer()
        let run = Self.configure(saved, player: player, list: [.automatic], preview: [.use])
        #expect(run.previewTitles.isEmpty)
        #expect(player.playedVoices.isEmpty)
        #expect(!run.output.contains("Choose a voice to listen"))
        #expect(try #require(run.manifest).voice == AgentVoiceSettingsManifest(enabled: true, language: "ja"))
    }

    @Test
    func aRemovedVoiceIsReported() {
        let player = RecordingPlayer()
        player.isInstalled = false
        let run = Self.configure(
            MacOSVoiceModeSetupTests.manifest(),
            player: player,
            list: [.voice(Voices.luca.identifier)],
            preview: [.listen, .back]
        )
        #expect(run.output.contains("Luca is no longer installed; choose another voice."))
        #expect(run.manifest == MacOSVoiceModeSetupTests.manifest())
    }
}
#endif
