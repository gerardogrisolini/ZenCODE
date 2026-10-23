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

    /// Runs the section with a scripted menu answer; `option` answers the
    /// pause and limit submenus, `sendMode` and `keyword` the send mode ones.
    static func configure(
        _ manifest: AgentSettingsManifest?,
        option: ([TerminalCheckboxMenuItem<ZenCODESetupRunner.VoiceOptionAction>], ZenCODESetupRunner.VoiceOptionAction) -> ZenCODESetupRunner.VoiceOptionAction? = { _, _ in .back },
        sendMode: ([TerminalCheckboxMenuItem<ZenCODESetupRunner.VoiceSendModeAction>], ZenCODESetupRunner.VoiceSendModeAction) -> ZenCODESetupRunner.VoiceSendModeAction? = { _, _ in .back },
        keyword: @escaping (String?) -> String? = { _ in nil },
        answer: ([TerminalCheckboxMenuItem<Action>], Action) -> Action?
    ) -> (manifest: AgentSettingsManifest?, output: String) {
        var output = ""
        let result = ZenCODESetupRunner.configureSpeechVoice(
            manifest: manifest,
            installedVoices: Voices.installed,
            write: { output += $0 },
            selectOne: { _, items, selected in answer(items, selected) },
            selectOption: { _, items, selected in option(items, selected) },
            selectSendMode: { _, items, selected in sendMode(items, selected) },
            promptKeyword: keyword
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
    func menuListsTheOptionsThenAutomaticThenTheVoicesOfTheLanguage() throws {
        let items = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "it-IT"
        )
        #expect(items.map(\.value) == [
            .sendMode,
            .spokenLimit,
            .automatic,
            .voice(Voices.federica.identifier),
            .voice(Voices.luca.identifier),
            .voice(Voices.alice.identifier),
            .back
        ])
        #expect(items[0].title == "Send mode")
        #expect(items[0].detail == "after 5 s of silence")
        #expect(items[1].title == "Spoken answer limit")
        #expect(items[1].detail == "600 characters · a longer answer is read from its final sentences")
        #expect(items[2].title == "Automatic")
        #expect(items[2].detail == "best installed voice, now Federica (it-IT · premium)")
        let luca = try #require(items.first { $0.value == .voice(Voices.luca.identifier) })
        #expect(luca.title == "Luca")
        #expect(luca.detail == "it-IT · enhanced")
        #expect(items.last?.title == "Back")

        let none = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "ja-JP"
        )
        #expect(none.map(\.value) == [.sendMode, .spokenLimit, .automatic, .back])
        #expect(none[2].detail == "system default voice for ja-JP")

        // Saved options show in the item details.
        let saved = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "it-IT",
            manifest: Self.manifest(voice: AgentVoiceSettingsManifest(
                utteranceSilenceSeconds: 8,
                maximumSpokenCharacters: 0
            ))
        )
        #expect(saved[0].detail == "after 8 s of silence")
        #expect(saved[1].detail?.hasPrefix("whole answer · ") == true)

        // In keyword mode the send mode shows the word; the pause is part of
        // "After a pause" only.
        let keyword = ZenCODESetupRunner.speechVoiceMenuItems(
            installedVoices: Voices.installed,
            localeIdentifier: "it-IT",
            manifest: Self.manifest(voice: AgentVoiceSettingsManifest(sendMode: .keyword, sendKeyword: "vai"))
        )
        #expect(keyword[0].detail == "on the word “vai” · silence never sends")
        #expect(keyword[1].title == "Spoken answer limit")
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
        #expect(offered.count == 7)
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

    @Test
    func optionMenusListPresetsAndTheSavedValueWithTheDefaultMarked() {
        typealias Option = ZenCODESetupRunner.VoiceOptionAction
        let silence = ZenCODESetupRunner.utteranceSilenceMenuItems(current: 5)
        #expect(silence.map(\.value) == [.value(2), .value(3), .value(5), .value(8), .value(10), .back])
        #expect(silence.map(\.title) == ["2 s", "3 s", "5 s", "8 s", "10 s", "Back"])
        #expect(silence[2].detail == "default")
        #expect(silence[0].detail == "")
        #expect(silence.last?.detail == "keep the current send mode")
        // A hand-edited value joins the list in order.
        #expect(ZenCODESetupRunner.utteranceSilenceMenuItems(current: 4).map(\.value)
            == [.value(2), .value(3), .value(4), .value(5), .value(8), .value(10), .back])

        let limit = ZenCODESetupRunner.spokenLimitMenuItems(current: 0)
        #expect(limit.map(\.value) == [.value(300), .value(600), .value(1_000), .value(2_000), .value(0), .back])
        #expect(limit.map(\.title) == ["300 characters", "600 characters", "1000 characters", "2000 characters", "whole answer", "Back"])
        #expect(limit[1].detail == "default")
        #expect(limit.last?.detail == "keep whole answer")
        #expect(ZenCODESetupRunner.spokenLimitMenuItems(current: 800).map(\.value)
            == [.value(300), .value(600), .value(800), .value(1_000), .value(2_000), .value(0), .back])
    }

    @Test
    func choosingAnOptionStagesItAndShowsTheMenuAgain() throws {
        let original = Self.manifest(voice: AgentVoiceSettingsManifest(
            enabled: true,
            macOSVoiceIdentifier: Voices.luca.identifier
        ))
        var round = 0
        var preselected: [Action] = []
        var optionPreselected: [ZenCODESetupRunner.VoiceOptionAction] = []
        var sendModePreselected: [ZenCODESetupRunner.VoiceSendModeAction] = []
        let result = Self.configure(
            original,
            option: { _, selected in
                optionPreselected.append(selected)
                return selected == .value(5) ? .value(8) : .value(0)
            },
            sendMode: { _, selected in
                sendModePreselected.append(selected)
                return .pause
            },
            answer: { _, selected in
                preselected.append(selected)
                round += 1
                switch round {
                case 1: return .sendMode
                case 2: return .spokenLimit
                default: return .back
                }
            }
        )
        #expect(preselected == [.voice(Voices.luca.identifier), .sendMode, .spokenLimit])
        // "After a pause" goes on to the pause, then the limit has its own menu.
        #expect(sendModePreselected == [.pause])
        #expect(optionPreselected == [.value(5), .value(600)])
        let manifest = try #require(result.manifest)
        #expect(manifest.voice == AgentVoiceSettingsManifest(
            enabled: true,
            macOSVoiceIdentifier: Voices.luca.identifier,
            utteranceSilenceSeconds: 8,
            maximumSpokenCharacters: 0
        ))
        #expect(manifest.responseLanguage == "it")
        #expect(manifest.localExecAllowedCommands == ["git status"])
        #expect(result.output.contains("Send mode: after 8 s of silence."))
        #expect(result.output.contains("Spoken answer limit: whole answer."))

        // Saved with the other settings and read back by voice mode.
        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded.voice == manifest.voice)
        let options = TerminalVoiceOptions(voice: reloaded.voice)
        #expect(options.utteranceSilence == .seconds(8))
        #expect(options.utteranceSilenceSeconds == 8)
        #expect(options.maximumSpokenCharacters == nil)

        // Choosing a voice afterwards keeps the options.
        let withVoice = Self.configure(manifest) { _, _ in .automatic }
        #expect(try #require(withVoice.manifest).voice == AgentVoiceSettingsManifest(
            enabled: true,
            utteranceSilenceSeconds: 8,
            maximumSpokenCharacters: 0
        ))
    }

    @Test
    func optionsAloneKeepTheVoiceSettingsAndDefaultsApplyWhenAbsent() throws {
        // Without any other voice setting, a chosen option is still stored.
        let result = Self.configure(
            Self.manifest(),
            option: { _, _ in .value(3) },
            sendMode: { _, _ in .pause },
            answer: { _, selected in selected == .sendMode ? .back : .sendMode }
        )
        #expect(try #require(result.manifest).voice == AgentVoiceSettingsManifest(utteranceSilenceSeconds: 3))
        #expect(ZenCODESetupRunner.voiceOptionsSetupSuffix(manifest: result.manifest) == " · pause 3 s")

        // Back or Esc in the option menu changes nothing.
        let saved = Self.manifest(voice: AgentVoiceSettingsManifest(enabled: true))
        var round = 0
        let unchanged = Self.configure(
            saved,
            option: { _, _ in round == 1 ? .back : nil },
            answer: { _, _ in
                round += 1
                return round <= 2 ? .spokenLimit : .back
            }
        )
        #expect(unchanged.manifest == saved)
        #expect(ZenCODESetupRunner.voiceOptionsSetupSuffix(manifest: saved).isEmpty)

        // Defaults: 5 s and 600 characters; settings without the keys decode
        // unchanged.
        let legacy = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(legacy == AgentVoiceSettingsManifest(enabled: true))
        let defaults = TerminalVoiceOptions(voice: legacy)
        #expect(defaults == TerminalVoiceOptions())
        #expect(defaults.utteranceSilence == .seconds(5))
        #expect(defaults.maximumSpokenCharacters == 600)
        #expect(ZenCODESetupRunner.spokenCharacters(manifest: nil) == 600)
        #expect(ZenCODESetupRunner.utteranceSilenceSeconds(manifest: nil) == 5)
        // Invalid saved values fall back to the defaults.
        #expect(AgentVoiceSettingsManifest(utteranceSilenceSeconds: 0, maximumSpokenCharacters: -1).isEmpty)
    }

    @Test
    func sendModeMenuOffersPauseAndKeywordAndTheKeywordIsTyped() throws {
        typealias Mode = ZenCODESetupRunner.VoiceSendModeAction
        let items = ZenCODESetupRunner.sendModeMenuItems(manifest: Self.manifest())
        #expect(items.map(\.value) == [.pause, .keyword, .back])
        #expect(items[0].title == "After a pause")
        #expect(items[0].detail == "the utterance is sent after the silence you choose next, now 5 s (default)")
        #expect(items[1].title == "On a word")
        #expect(items[1].detail == "the utterance is sent when you say a word you choose; silence never sends")

        // Choosing the word stores keyword mode and the word.
        var preselected: [Mode] = []
        var offeredDefault: [String?] = []
        var round = 0
        let chosen = Self.configure(
            Self.manifest(voice: AgentVoiceSettingsManifest(enabled: true)),
            sendMode: { _, selected in
                preselected.append(selected)
                return .keyword
            },
            keyword: { saved in
                offeredDefault.append(saved)
                return " Vai! "
            },
            answer: { _, _ in
                round += 1
                return round == 1 ? .sendMode : .back
            }
        )
        #expect(preselected == [.pause])
        #expect(offeredDefault == [nil])
        let manifest = try #require(chosen.manifest)
        #expect(manifest.voice == AgentVoiceSettingsManifest(enabled: true, sendMode: .keyword, sendKeyword: "Vai!"))
        #expect(chosen.output.contains("Send mode: on the word “Vai!”."))
        #expect(ZenCODESetupRunner.voiceOptionsSetupSuffix(manifest: manifest) == " · send on “Vai!”")
        let options = TerminalVoiceOptions(voice: manifest.voice)
        #expect(options.sendKeyword?.words == ["vai"])
        #expect(options.recognizerSilenceSeconds == 1)
        #expect(options.utteranceSilenceSeconds == 5)

        // Saved and reloaded; the saved word is offered as the default next time.
        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded.voice == manifest.voice)
        let keywordItems = ZenCODESetupRunner.sendModeMenuItems(manifest: reloaded)
        #expect(keywordItems[1].detail == "the utterance is sent when you say “Vai!”; silence never sends")

        // Back or Esc in the pause list keeps sending on the word.
        for pauseAnswer in [ZenCODESetupRunner.VoiceOptionAction.back, nil] {
            round = 0
            let kept = Self.configure(
                reloaded,
                option: { _, _ in pauseAnswer },
                sendMode: { _, _ in .pause },
                answer: { _, _ in
                    round += 1
                    return round == 1 ? .sendMode : .back
                }
            )
            #expect(kept.manifest == reloaded)
        }

        // Back to pause, with its seconds, keeps the word for later; the
        // suffix no longer shows it.
        round = 0
        var pausePreselected: [ZenCODESetupRunner.VoiceOptionAction] = []
        let paused = Self.configure(
            reloaded,
            option: { _, selected in
                pausePreselected.append(selected)
                return selected
            },
            sendMode: { _, selected in
                preselected.append(selected)
                return .pause
            },
            answer: { _, _ in
                round += 1
                return round == 1 ? .sendMode : .back
            }
        )
        #expect(preselected.last == .keyword)
        #expect(pausePreselected == [.value(5)])
        #expect(paused.output.contains("Send mode: after 5 s of silence."))
        #expect(try #require(paused.manifest).voice == AgentVoiceSettingsManifest(
            enabled: true,
            utteranceSilenceSeconds: 5,
            sendMode: .pause,
            sendKeyword: "Vai!"
        ))
        #expect(ZenCODESetupRunner.voiceOptionsSetupSuffix(manifest: paused.manifest).isEmpty)
        #expect(TerminalVoiceOptions(voice: paused.manifest?.voice).sendMode == .pause)
        round = 0
        let again = Self.configure(
            paused.manifest,
            sendMode: { _, _ in .keyword },
            keyword: { saved in
                offeredDefault.append(saved)
                return saved
            },
            answer: { _, _ in
                round += 1
                return round == 1 ? .sendMode : .back
            }
        )
        #expect(offeredDefault.last == "Vai!")
        #expect(try #require(again.manifest).voice?.sendMode == .keyword)

        // A cancelled or unusable word keeps the manifest; a yes/no word is refused.
        let saved = Self.manifest(voice: AgentVoiceSettingsManifest(enabled: true))
        round = 0
        let cancelled = Self.configure(
            saved,
            sendMode: { _, _ in .keyword },
            keyword: { _ in nil },
            answer: { _, _ in
                round += 1
                return round == 1 ? .sendMode : .back
            }
        )
        #expect(cancelled.manifest == saved)
        var attempts = 0
        round = 0
        let refused = Self.configure(
            saved,
            sendMode: { _, _ in .keyword },
            keyword: { _ in
                attempts += 1
                switch attempts {
                case 1: return "..."
                case 2: return "ok"
                default: return "fatto"
                }
            },
            answer: { _, _ in
                round += 1
                return round == 1 ? .sendMode : .back
            }
        )
        #expect(attempts == 3)
        #expect(refused.output.contains("The word must contain letters or digits."))
        #expect(refused.output.contains("“ok” is a spoken yes or no"))
        #expect(try #require(refused.manifest).voice?.sendKeyword == "fatto")

        // Keyword mode without a word, or an unknown mode, is pause mode.
        let noWord = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"enabled":false,"sendMode":"keyword"}"#.utf8)
        )
        #expect(TerminalVoiceOptions(voice: noWord).sendMode == .pause)
        #expect(!ZenCODESetupRunner.sendsOnKeyword(manifest: Self.manifest(voice: noWord)))
        let unknown = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"enabled":false,"sendMode":"gesture","sendKeyword":"vai"}"#.utf8)
        )
        #expect(unknown == AgentVoiceSettingsManifest(sendKeyword: "vai"))
        #expect(TerminalVoiceOptions(voice: unknown).sendMode == .pause)
    }
}
