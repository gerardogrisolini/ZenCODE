//
//  ResponseLanguageResolver.swift
//  ZenCODE
//
//  Centralizes operating-system language detection and ISO language-code
//  resolution so the TUI session lock and the setup flow share one source of
//  truth for the configured response language.
//

import Foundation

public enum ResponseLanguageResolver {
    /// Curated mapping of ISO language codes to human-readable English display
    /// names. Languages not in this map fall back to Foundation's localized
    /// name via ``displayName(forCode:)``.
    public static let displayNames: [String: String] = [
        "en": "English",
        "it": "Italian",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "pt": "Portuguese",
        "nl": "Dutch",
        "sv": "Swedish",
        "da": "Danish",
        "no": "Norwegian",
        "fi": "Finnish",
        "pl": "Polish",
        "cs": "Czech",
        "tr": "Turkish",
        "ru": "Russian",
        "uk": "Ukrainian",
        "ja": "Japanese",
        "ko": "Korean",
        "zh": "Chinese",
        "ar": "Arabic",
        "hi": "Hindi"
    ]

    /// The curated language list ordered by display name for menu presentation.
    public static let selectableLanguages: [(code: String, displayName: String)] =
        displayNames
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { (code: $0.key, displayName: $0.value) }

    /// Resolves the operating system language into a human-readable English
    /// language name (e.g. "Italian"). Returns nil when the system language
    /// cannot be determined, so callers can fall back to generic guidance.
    public static func systemDisplayName() -> String? {
        guard let code = systemLanguageCode() else {
            return nil
        }
        return displayName(forCode: code)
    }

    /// Resolves the operating system language code (e.g. "it"). Returns nil
    /// when the system language cannot be determined.
    public static func systemLanguageCode() -> String? {
        if let code = normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) {
            return code
        }

        // Linux/POSIX fallback: read the locale from the environment. Values
        // look like "it_IT.UTF-8" or "en_US"; we only need the leading
        // language code.
        let environment = ProcessInfo.processInfo.environment
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let raw = environment[key] else {
                continue
            }
            let languagePart = raw.split(whereSeparator: { $0 == "_" || $0 == "." || $0 == "@" }).first
            if let code = normalizedLanguageCode(languagePart.map(String.init)) {
                return code
            }
        }

        return nil
    }

    /// Maps a normalized ISO language code to its human-readable English name.
    /// Returns nil for unknown or blank codes so callers can fall back to
    /// generic guidance.
    public static func displayName(forCode code: String?) -> String? {
        guard let normalized = normalizedLanguageCode(code) else {
            return nil
        }
        if let mapped = displayNames[normalized] {
            return mapped
        }
        // Fall back to Foundation's localized display name (in English) for
        // any valid ISO language code not present in the static map.
        if let localized = Locale(identifier: "en").localizedString(forLanguageCode: normalized),
           !localized.isEmpty,
           localized.lowercased() != normalized
        {
            return localized
        }
        return nil
    }

    private static func normalizedLanguageCode(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        // "C" and "posix" are not real languages; treat them as undetermined.
        guard normalized != "c", normalized != "posix" else {
            return nil
        }
        return normalized
    }
}
