//
//  VoiceLanguage.swift
//  ZenCODE
//
//  The language of terminal voice mode and of Telegram voice-message
//  transcription. It is not a separate setting: it follows the response
//  language chosen in `/setup`, else the system language, else English.
//

import Foundation

enum VoiceLanguage {
    /// The response language, else the system language, else English, as a
    /// lowercased code such as `it`.
    static func resolvedCode(
        responseLanguage: String?,
        systemLanguage: String?
    ) -> String {
        for candidate in [responseLanguage, systemLanguage] {
            if let code = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !code.isEmpty {
                return code
            }
        }
        return "en"
    }

    /// `resolvedCode` for the saved settings and the current system language.
    static func resolvedCode(manifest: AgentSettingsManifest?) -> String {
        resolvedCode(
            responseLanguage: manifest?.responseLanguage,
            systemLanguage: ResponseLanguageResolver.systemLanguageCode()
        )
    }
}
