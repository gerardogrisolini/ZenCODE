//
//  ZenCODESetupRunner+ResponseLanguage.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 24/07/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    /// Prompts for the natural-language response language, defaulting to the
    /// currently configured language or — when none is set — the operating
    /// system language. Does not require a configured provider/model.
    static func configureResponseLanguage(
        existingManifest manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        let languages = ResponseLanguageResolver.selectableLanguages
        let systemCode = ResponseLanguageResolver.systemLanguageCode()
        let defaultCode = manifest?.responseLanguage ?? systemCode
        let defaultIndex = defaultCode
            .flatMap { code in languages.firstIndex { $0.code == code } }
            ?? 0

        let items = languages.enumerated().map { index, language in
            TerminalCheckboxMenuItem(
                value: index,
                title: language.displayName,
                detail: language.code == systemCode ? "system" : nil
            )
        }
        let selectedIndex = try promptMenuChoice(
            title: "Response language",
            items: items,
            selected: defaultIndex
        )
        return manifestByUpdatingResponseLanguage(
            manifest,
            responseLanguage: languages[selectedIndex].code
        )
    }

    static func manifestByUpdatingResponseLanguage(
        _ manifest: AgentSettingsManifest?,
        responseLanguage: String?
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            version: manifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: manifest?.providers ?? [],
            models: manifest?.models ?? [],
            selectedModelID: manifest?.selectedModelID,
            selectedThinkingSelection: manifest?.selectedThinkingSelection,
            telegram: manifest?.telegram,
            voice: manifest?.voice,
            remoteAPIKeysByProviderID: manifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: manifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: manifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest?.anthropicSubscriptionCredentials,
            responseLanguage: responseLanguage
        )
    }

    static func responseLanguageSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let code = manifest?.responseLanguage else {
            return "system default"
        }
        if let name = ResponseLanguageResolver.displayName(forCode: code) {
            return name
        }
        return code
    }
}
