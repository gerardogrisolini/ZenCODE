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
            Speech-to-text uses SFSpeechRecognizer and text-to-speech uses AVSpeechSynthesizer.
            No external executable or API key is required.

            """
        )
        #else
        print(
            """

            Voice uses the built-in Apple speech frameworks.
            Audio generation is available only on macOS and will not be enabled on this platform.
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
        #if os(macOS)
        let speaker: String? = try selectVoiceSetupOption(
            title: "macOS synthesis voice",
            options: voiceSpeakerOptions,
            defaultValue: existingSettings?.speaker?.nilIfBlank
                ?? AgentVoiceSettingsManifest.defaultSpeaker
        )
        #else
        let speaker: String? = nil
        #endif

        return AgentVoiceSettingsManifest(
            enabled: true,
            language: language,
            speaker: speaker
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

    private static let voiceSpeakerOptions: [VoiceSetupOption] = [
        VoiceSetupOption(value: "Alice", title: "Alice", detail: "Italiano"),
        VoiceSetupOption(value: "Samantha", title: "Samantha", detail: "English US"),
        VoiceSetupOption(value: "Daniel", title: "Daniel", detail: "English UK"),
        VoiceSetupOption(value: "Paulina", title: "Paulina", detail: "Spanish"),
        VoiceSetupOption(value: "Thomas", title: "Thomas", detail: "French"),
        VoiceSetupOption(value: "Anna", title: "Anna", detail: "German"),
        VoiceSetupOption(value: "Joana", title: "Joana", detail: "Portuguese"),
        VoiceSetupOption(value: "Kyoko", title: "Kyoko", detail: "Japanese"),
        VoiceSetupOption(value: "Yuna", title: "Yuna", detail: "Korean"),
        VoiceSetupOption(value: "Tingting", title: "Tingting", detail: "Chinese"),
        VoiceSetupOption(value: "Milena", title: "Milena", detail: "Russian")
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
