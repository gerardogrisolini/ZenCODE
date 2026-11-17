//
//  TerminalChat+ResponseLanguage.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 21/06/26.
//

import Foundation

extension TerminalChat {
  func lockResponseLanguageIfNeeded() {
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
    activeResponseLanguageName = ResponseLanguageResolver.lockedDisplayName()
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
}
