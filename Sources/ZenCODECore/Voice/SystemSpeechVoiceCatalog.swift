//
//  SystemSpeechVoiceCatalog.swift
//  ZenCODE
//
//  The macOS system voices that read answers aloud in terminal voice mode,
//  and the rules that pick one. `/setup` > Voice mode lists them and saves
//  the operator's choice as `voice.macOSVoiceIdentifier`; the speaker applies
//  the same rules when `/voice on` starts. Voices are plain values so the
//  rules are testable without the voices installed on a machine. Siri voices
//  are not exposed to other apps by `AVSpeechSynthesisVoice.speechVoices()`.
//

import Foundation
import ToolCore
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One installed system speech-synthesis voice.
struct SystemSpeechVoice: Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .standard:
                return "standard"
            case .enhanced:
                return "enhanced"
            case .premium:
                return "premium"
            }
        }
    }

    let identifier: String
    let name: String
    /// BCP 47 tag, e.g. `it-IT`.
    let language: String
    let quality: Quality
}

enum SystemSpeechVoiceCatalog {
    /// `it-IT` for `it_IT` or `it-IT`.
    static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The primary language subtag, lowercased: `it` for `it-IT`.
    static func languageCode(of identifier: String) -> String {
        let normalized = normalizedLocaleIdentifier(identifier)
        return normalized.split(separator: "-").first.map { String($0).lowercased() }
            ?? normalized.lowercased()
    }

    /// The voices that read the language of `localeIdentifier`: the exact
    /// locale first, then the other regions by tag, each by quality (best
    /// first) and name.
    static func voices(
        _ voices: [SystemSpeechVoice],
        forLocale localeIdentifier: String
    ) -> [SystemSpeechVoice] {
        let locale = normalizedLocaleIdentifier(localeIdentifier)
        let language = languageCode(of: locale)
        func isExact(_ voice: SystemSpeechVoice) -> Bool {
            voice.language.caseInsensitiveCompare(locale) == .orderedSame
        }
        return voices
            .filter { isExact($0) || languageCode(of: $0.language) == language }
            .sorted { lhs, rhs in
                if isExact(lhs) != isExact(rhs) {
                    return isExact(lhs)
                }
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                if lhs.quality != rhs.quality {
                    return lhs.quality > rhs.quality
                }
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.identifier < rhs.identifier
            }
    }

    /// The automatic choice: the best voice of the exact locale, else of any
    /// region of the language. Among equal qualities the system order wins.
    static func automaticVoice(
        in voices: [SystemSpeechVoice],
        localeIdentifier: String
    ) -> SystemSpeechVoice? {
        let locale = normalizedLocaleIdentifier(localeIdentifier)
        let language = languageCode(of: locale)
        let exact = voices.filter { $0.language.caseInsensitiveCompare(locale) == .orderedSame }
        let candidates = exact.isEmpty
            ? voices.filter { $0.language.lowercased().hasPrefix(language + "-") }
            : exact
        return candidates.max { $0.quality < $1.quality }
    }

    /// The saved voice when it is installed and reads the language of
    /// `localeIdentifier`. A voice of another language would read answers
    /// with the wrong pronunciation, so it is ignored rather than used.
    static func savedVoice(
        identifier: String?,
        localeIdentifier: String,
        lookup: (String) -> SystemSpeechVoice?
    ) -> SystemSpeechVoice? {
        guard let identifier = identifier?.nilIfBlank,
              let voice = lookup(identifier),
              languageCode(of: voice.language) == languageCode(of: localeIdentifier) else {
            return nil
        }
        return voice
    }

    /// The saved voice when it applies, else the automatic choice.
    static func preferredVoice(
        savedIdentifier: String?,
        localeIdentifier: String,
        installedVoices: [SystemSpeechVoice],
        lookup: (String) -> SystemSpeechVoice?
    ) -> SystemSpeechVoice? {
        savedVoice(identifier: savedIdentifier, localeIdentifier: localeIdentifier, lookup: lookup)
            ?? automaticVoice(in: installedVoices, localeIdentifier: localeIdentifier)
    }

    #if canImport(AVFoundation)
    /// Installed voices in system order, without novelty voices and
    /// Personal Voice.
    static func installedVoices() -> [SystemSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter {
                !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .map(SystemSpeechVoice.init(_:))
    }

    /// The installed voice with `identifier`, or `nil` once it is removed.
    static func installedVoice(identifier: String) -> SystemSpeechVoice? {
        AVSpeechSynthesisVoice(identifier: identifier).map(SystemSpeechVoice.init(_:))
    }
    #else
    static func installedVoices() -> [SystemSpeechVoice] {
        []
    }

    static func installedVoice(identifier: String) -> SystemSpeechVoice? {
        nil
    }
    #endif
}

#if canImport(AVFoundation)
extension SystemSpeechVoice {
    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality
        switch voice.quality {
        case .premium:
            quality = .premium
        case .enhanced:
            quality = .enhanced
        default:
            quality = .standard
        }
        self.init(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality
        )
    }
}
#endif
