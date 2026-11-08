//
//  MacOSVoicePreviewSetupTests.swift
//  ZenCODECoreTests
//
//  The audio preview of `zen --setup` > Voice mode on macOS. A recording player
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
}
#endif
