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
    // Prefer the response language configured in settings.json. When not
    // configured (or when the stored code is unknown), fall back to the
    // operating system language so existing setups keep their behavior.
    // When neither can be determined (e.g. a Linux host with no configured
    // locale), we leave `activeResponseLanguageName` nil so no language lock
    // is applied and the generic response-language guidance is used instead.
    if let configuredName = configuredResponseLanguageName() {
      activeResponseLanguageName = configuredName
    } else {
      activeResponseLanguageName = Self.systemResponseLanguageName()
    }
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

  /// Resolves the response language declared in settings.json into a
  /// human-readable English name. Returns nil when no language is configured
  /// or the stored code cannot be resolved, so the caller can fall back to the
  /// operating system language.
  private func configuredResponseLanguageName() -> String? {
    guard let code = AgentSettingsManifestStore.load()?.responseLanguage else {
      return nil
    }
    return ResponseLanguageResolver.displayName(forCode: code)
  }

  /// Resolves the operating system language into a human-readable English
  /// language name (e.g. "Italian"). Returns nil when the system language
  /// cannot be determined, so callers can fall back to the generic guidance.
  nonisolated static func systemResponseLanguageName() -> String? {
    ResponseLanguageResolver.systemDisplayName()
  }
}
