//
//  SystemSpeechVoiceCatalogTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore
#if canImport(AVFAudio)
import AVFAudio
#endif

@Suite("System speech voices")
struct SystemSpeechVoiceCatalogTests {
    static let alice = SystemSpeechVoice(
        identifier: "com.apple.voice.compact.it-IT.Alice", name: "Alice", language: "it-IT", quality: .standard
    )
    static let federica = SystemSpeechVoice(
        identifier: "com.apple.voice.premium.it-IT.Federica", name: "Federica", language: "it-IT", quality: .premium
    )
    static let luca = SystemSpeechVoice(
        identifier: "com.apple.voice.enhanced.it-IT.Luca", name: "Luca", language: "it-IT", quality: .enhanced
    )
    static let samantha = SystemSpeechVoice(
        identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard
    )
    static let daniel = SystemSpeechVoice(
        identifier: "com.apple.voice.enhanced.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: .enhanced
    )
    /// System order, deliberately unsorted.
    static let installed = [alice, samantha, federica, daniel, luca]

    static func lookup(_ identifier: String) -> SystemSpeechVoice? {
        installed.first { $0.identifier == identifier }
    }

    @Test
    func languageCodesIgnoreRegionScriptAndSeparator() {
        #expect(SystemSpeechVoiceCatalog.languageCode(of: "it_IT") == "it")
        #expect(SystemSpeechVoiceCatalog.languageCode(of: "zh-Hant-TW") == "zh")
        #expect(SystemSpeechVoiceCatalog.languageCode(of: "EN") == "en")
        #expect(SystemSpeechVoiceCatalog.normalizedLocaleIdentifier("it_IT") == "it-IT")
    }

    @Test
    func voicesOfALanguageListTheExactLocaleFirstThenQualityAndName() {
        #expect(
            SystemSpeechVoiceCatalog.voices(Self.installed, forLocale: "it_IT")
                == [Self.federica, Self.luca, Self.alice]
        )
        // Other regions follow the exact locale.
        #expect(
            SystemSpeechVoiceCatalog.voices(Self.installed, forLocale: "en-US")
                == [Self.samantha, Self.daniel]
        )
        #expect(SystemSpeechVoiceCatalog.voices(Self.installed, forLocale: "ja-JP").isEmpty)
    }

    @Test
    func automaticVoiceKeepsTheCurrentChoice() {
        // Best quality of the exact locale.
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: Self.installed, localeIdentifier: "it-IT") == Self.federica)
        // The exact locale wins over a better voice of another region.
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: Self.installed, localeIdentifier: "en_US") == Self.samantha)
        // Without the exact locale, the best voice of any region.
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: Self.installed, localeIdentifier: "en-AU") == Self.daniel)
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: Self.installed, localeIdentifier: "ja-JP") == nil)

        // Equal qualities keep the system order.
        let paola = SystemSpeechVoice(identifier: "paola", name: "Paola", language: "it-IT", quality: .standard)
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: [paola, Self.alice], localeIdentifier: "it-IT") == paola)
        #expect(SystemSpeechVoiceCatalog.automaticVoice(in: [Self.alice, paola], localeIdentifier: "it-IT") == Self.alice)
    }

    @Test
    func savedVoiceIsUsedWhenInstalledAndOfTheSameLanguage() {
        func preferred(_ saved: String?, _ locale: String = "it_IT") -> SystemSpeechVoice? {
            SystemSpeechVoiceCatalog.preferredVoice(
                savedIdentifier: saved,
                localeIdentifier: locale,
                installedVoices: Self.installed,
                lookup: Self.lookup
            )
        }
        // A saved voice wins over the better automatic one.
        #expect(preferred(Self.luca.identifier) == Self.luca)
        #expect(preferred(Self.alice.identifier, "it-CH") == Self.alice)
        // Otherwise the automatic choice.
        #expect(preferred(nil) == Self.federica)
        #expect(preferred("  ") == Self.federica)
        #expect(preferred("com.apple.voice.premium.it-IT.Removed") == Self.federica)
        // A voice of another language is ignored rather than read with the
        // wrong pronunciation.
        #expect(preferred(Self.samantha.identifier) == Self.federica)
        #expect(preferred(Self.federica.identifier, "ja-JP") == nil)

        #expect(SystemSpeechVoiceCatalog.savedVoice(
            identifier: Self.samantha.identifier, localeIdentifier: "it-IT", lookup: Self.lookup
        ) == nil)
    }

    #if os(macOS)
    /// The installed voices of this Mac resolve by identifier; a removed
    /// voice does not, so the speaker falls back to the automatic voice.
    @Test
    func installedVoicesResolveByIdentifier() {
        let voices = SystemSpeechVoiceCatalog.installedVoices()
        for voice in voices.prefix(20) {
            #expect(SystemSpeechVoiceCatalog.installedVoice(identifier: voice.identifier) == voice)
        }
        #expect(SystemSpeechVoiceCatalog.installedVoice(identifier: "com.zencode.tests.missing-voice") == nil)
    }

    @MainActor
    @Test
    func speakerFallsBackToTheAutomaticVoice() {
        let automatic = TerminalVoiceSpeaker.preferredVoice(localeIdentifier: "it_IT", readingVoiceIdentifier: nil)
        let missing = TerminalVoiceSpeaker.preferredVoice(
            localeIdentifier: "it_IT",
            readingVoiceIdentifier: "com.zencode.tests.missing-voice"
        )
        #expect(missing?.identifier == automatic?.identifier)

        let installed = SystemSpeechVoiceCatalog.installedVoices()
        if let otherLanguage = installed.first(where: { SystemSpeechVoiceCatalog.languageCode(of: $0.language) != "it" }) {
            let ignored = TerminalVoiceSpeaker.preferredVoice(
                localeIdentifier: "it_IT",
                readingVoiceIdentifier: otherLanguage.identifier
            )
            #expect(ignored?.identifier == automatic?.identifier)
        }
        if let italian = SystemSpeechVoiceCatalog.voices(installed, forLocale: "it-IT").last {
            let saved = TerminalVoiceSpeaker.preferredVoice(
                localeIdentifier: "it_IT",
                readingVoiceIdentifier: italian.identifier
            )
            #expect(saved?.identifier == italian.identifier)
        }
    }
    #endif
}

@Suite("Voice settings manifest")
struct AgentVoiceSettingsManifestTests {
    static let identifier = "com.apple.voice.premium.it-IT.Federica"

    @Test
    func legacyVoiceSettingsDecodeAndDropTheLanguage() throws {
        let voice = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"enabled":true,"language":"it"}"#.utf8)
        )
        #expect(voice == AgentVoiceSettingsManifest(enabled: true))
        #expect(voice.macOSVoiceIdentifier == nil)
        #expect(voice.isConfigured)

        let manifest = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(#"{"version":14,"models":[],"voice":{"enabled":true,"language":"it"}}"#.utf8)
        )
        #expect(manifest.voice == voice)
        // The language follows the response language: the saved key is not
        // written again.
        let object = try Self.encodedVoice(of: manifest)
        #expect(object.keys.sorted() == ["enabled"])

        // A disabled legacy value is still dropped.
        let disabled = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(#"{"version":14,"models":[],"voice":{"enabled":false}}"#.utf8)
        )
        #expect(disabled.voice == nil)
    }

    @Test
    func readingVoiceIsStoredWithoutTelegramTranscription() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            voice: AgentVoiceSettingsManifest(enabled: false, macOSVoiceIdentifier: Self.identifier)
        )
        let voice = try #require(manifest.voice)
        #expect(!voice.isConfigured)
        #expect(!voice.isEmpty)
        #expect(!TerminalOptionalCommandAvailability.from(manifest: manifest).voiceEnabled)

        let object = try Self.encodedVoice(of: manifest)
        #expect(object["enabled"] as? Bool == false)
        #expect(object["macOSVoiceIdentifier"] as? String == Self.identifier)
        #expect(object["language"] == nil)

        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded == manifest)
    }

    @Test
    func readingVoiceRoundTripsBesideTelegramTranscription() throws {
        let voice = AgentVoiceSettingsManifest(enabled: true, macOSVoiceIdentifier: Self.identifier)
        let manifest = AgentSettingsManifest(models: [], voice: voice)
        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded.voice == voice)
        #expect(TerminalOptionalCommandAvailability.from(manifest: reloaded).voiceEnabled)
    }

    @Test
    func emptyVoiceSettingsAreOmitted() throws {
        for empty in [
            AgentVoiceSettingsManifest(enabled: false),
            AgentVoiceSettingsManifest(enabled: false, macOSVoiceIdentifier: "  ")
        ] {
            #expect(empty.isEmpty)
            #expect(empty.macOSVoiceIdentifier == nil)
            let manifest = AgentSettingsManifest(models: [], voice: empty)
            #expect(manifest.voice == nil)
            let object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
            )
            #expect(object["voice"] == nil)
        }
    }

    private static func encodedVoice(of manifest: AgentSettingsManifest) throws -> [String: Any] {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        return try #require(object["voice"] as? [String: Any])
    }
}
