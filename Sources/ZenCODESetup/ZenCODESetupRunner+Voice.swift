//
//  ZenCODESetupRunner+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func configureVoice(
        in manifest: AgentSettingsManifest
    ) throws -> AgentSettingsManifest {
        let voice = try promptVoiceSettings(existingSettings: manifest.voice)
        return AgentSettingsManifest(
            version: manifest.version,
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: manifest.selectedModelID,
            selectedThinkingSelection: manifest.selectedThinkingSelection,
            telegram: manifest.telegram,
            voice: voice,
            remoteAPIKeysByProviderID: manifest.remoteAPIKeysByProviderID,
            localExecAllowedCommands: manifest.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: manifest.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials
        )
    }

    static func promptVoiceSettings(
        existingSettings: AgentVoiceSettingsManifest?
    ) throws -> AgentVoiceSettingsManifest? {
        let shouldEnableVoice = try promptYesNo(
            "Enable voice tools?",
            defaultValue: existingSettings?.isConfigured == true
        )
        guard shouldEnableVoice else {
            return nil
        }

        #if os(macOS)
        print(
            """

            Voice uses the built-in macOS speech frameworks.
            Speech-to-text uses SFSpeechRecognizer.
            No external executable or API key is required.

            """
        )
        #else
        print(
            """

            Voice uses the built-in Apple speech frameworks.
            No external executable or API key is required.

            """
        )
        #endif

        let language = try selectVoiceSetupOption(
            title: "Voice language",
            options: voiceLanguageOptions,
            defaultValue: existingSettings?.language?.nilIfBlank
                ?? AgentVoiceSettingsManifest.defaultLanguage
        )

        return AgentVoiceSettingsManifest(
            enabled: true,
            language: language
        )
    }

    private static let voiceLanguageOptions: [VoiceSetupOption] = [
        VoiceSetupOption(value: "it", title: "Italiano", aliases: ["italian"]),
        VoiceSetupOption(value: "en", title: "English", aliases: ["english"]),
        VoiceSetupOption(value: "es", title: "Spanish", aliases: ["spanish"]),
        VoiceSetupOption(value: "fr", title: "French", aliases: ["french"]),
        VoiceSetupOption(value: "de", title: "Deutsch", aliases: ["german"]),
        VoiceSetupOption(value: "pt", title: "Portuguese", aliases: ["portuguese"]),
        VoiceSetupOption(value: "ja", title: "Japanese", aliases: ["japanese"]),
        VoiceSetupOption(value: "ko", title: "Korean", aliases: ["korean"]),
        VoiceSetupOption(value: "zh", title: "Chinese", aliases: ["chinese"]),
        VoiceSetupOption(value: "ru", title: "Russian", aliases: ["russian"])
    ]

    static func selectVoiceSetupOption(
        title: String,
        options: [VoiceSetupOption],
        defaultValue: String
    ) throws -> String {
        let defaultIndex = options.firstIndex { $0.matches(defaultValue) } ?? 0
        let items = options.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.title,
                detail: [option.value, option.detail].compactMap(\.self).joined(separator: " - ")
            )
        }
        let selectedIndex = try promptMenuChoice(
            title: title,
            items: items,
            selected: defaultIndex
        )
        return options[selectedIndex].value
    }

}
