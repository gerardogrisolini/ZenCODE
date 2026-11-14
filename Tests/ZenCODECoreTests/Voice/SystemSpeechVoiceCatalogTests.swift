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

    /// v2.4.0 saved `voice.maximumSpokenCharacters`; voice mode now always reads
    /// an answer whole, so the key is ignored and not written again.
    @Test
    func theRemovedSpokenCharactersLimitIsIgnoredAndDropped() throws {
        let voice = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"enabled":true,"maximumSpokenCharacters":0,"utteranceSilenceSeconds":8}"#.utf8)
        )
        #expect(voice == AgentVoiceSettingsManifest(enabled: true, utteranceSilenceSeconds: 8))
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(voice)) as? [String: Any]
        )
        #expect(encoded.keys.sorted() == ["enabled", "utteranceSilenceSeconds"])

        // Through a whole settings file, the key disappears on the next save.
        let manifest = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(
                #"{"version":14,"models":[],"voice":{"enabled":true,"maximumSpokenCharacters":600}}"#.utf8
            )
        )
        #expect(manifest.voice == AgentVoiceSettingsManifest(enabled: true))
        let object = try Self.encodedVoice(of: manifest)
        #expect(object.keys.sorted() == ["enabled"])

        // With nothing else set, the saved limit leaves no voice settings.
        let onlyTheLimit = try JSONDecoder().decode(
            AgentVoiceSettingsManifest.self,
            from: Data(#"{"maximumSpokenCharacters":600}"#.utf8)
        )
        #expect(onlyTheLimit.isEmpty)
        let alone = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(#"{"version":14,"models":[],"voice":{"maximumSpokenCharacters":600}}"#.utf8)
        )
        #expect(alone.voice == nil)
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

        let object = try Self.encodedVoice(of: manifest)
        #expect(object["enabled"] as? Bool == false)
        #expect(object["macOSVoiceIdentifier"] as? String == Self.identifier)
        #expect(object["language"] == nil)

        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: JSONEncoder().encode(manifest))
        #expect(reloaded == manifest)
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
