//
//  TerminalChat+ResponseLanguage.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 21/06/26.
//

import Foundation

extension TerminalChat {
  func lockResponseLanguageIfNeeded(from prompt: String) {
    guard !didLockResponseLanguage else {
      return
    }
    didLockResponseLanguage = true
    // The response language follows the operating system language. When it
    // cannot be determined (e.g. a Linux host with no configured locale), we
    // leave `activeResponseLanguageName` nil so no language lock is applied and
    // the generic response-language guidance is used instead.
    activeResponseLanguageName = Self.systemResponseLanguageName()
  }

  func resetResponseLanguageLock() {
    activeResponseLanguageName = nil
    didLockResponseLanguage = false
  }

  func responseLanguageSystemPromptSection() -> String? {
    guard let activeResponseLanguageName else {
      return nil
    }
    return SystemPromptBuilder.responseLanguageSection(
      languageName: activeResponseLanguageName
    )
  }

  /// Resolves the operating system language into a human-readable English
  /// language name (e.g. "Italian"). Returns nil when the system language
  /// cannot be determined, so callers can fall back to the generic guidance.
  static func systemResponseLanguageName() -> String? {
    guard let code = systemLanguageCode() else {
      return nil
    }

    if let mapped = responseLanguageDisplayNames[code] {
      return mapped
    }

    // Fall back to Foundation's localized display name (in English) for any
    // valid ISO language code not present in the static map.
    if let localized = Locale(identifier: "en").localizedString(forLanguageCode: code),
      !localized.isEmpty,
      localized.lowercased() != code
    {
      return localized
    }

    return nil
  }

  /// Extracts a normalized, lowercased ISO language code from the system
  /// locale, with an environment-variable fallback for hosts where
  /// `Locale.current` is not populated (common on Linux).
  private static func systemLanguageCode() -> String? {
      if let code = normalizedLanguageCode(Locale.current.language.languageCode?.identifier) {
      return code
    }

    // Linux/POSIX fallback: read the locale from the environment. Values look
    // like "it_IT.UTF-8" or "en_US"; we only need the leading language code.
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

  private static let responseLanguageDisplayNames: [String: String] = [
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
    "hi": "Hindi",
  ]
}
