//
//  ZenCODESetupRunner+VoiceModeMacOS.swift
//  ZenCODE
//
//  The macOS "Voice mode" setup section. macOS voice mode uses the system
//  speech frameworks and downloads nothing, so the section only chooses the
//  system voice that reads answers aloud among the installed voices of the
//  voice mode language, or keeps the automatic choice. Like Response
//  language, the choice is staged in the settings manifest
//  (`voice.macOSVoiceIdentifier`) and saved when setup finishes. The helpers
//  are platform neutral so they are testable everywhere; only macOS offers
//  the section, through `configureSpeechVoiceWithPreview`, which lets the
//  operator listen to a voice before using it.
//

import Foundation

extension ZenCODESetupRunner {
    enum SpeechVoiceAction: Hashable {
        case automatic
        case voice(String)
        case back
    }

    /// The locale voice mode listens and reads in, e.g. `it-IT`.
    static func speechVoiceLocaleIdentifier(manifest: AgentSettingsManifest?) -> String {
        SystemSpeechVoiceCatalog.normalizedLocaleIdentifier(
            AgentVoiceTranscriptionService.locale(
                for: voiceModeLanguageCode(manifest: manifest)
            ).identifier
        )
    }

    /// The saved reading voice when voice mode would use it: installed and
    /// reading the voice mode language.
    static func savedSpeechVoice(
        manifest: AgentSettingsManifest?,
        lookup: (String) -> SystemSpeechVoice? = SystemSpeechVoiceCatalog.installedVoice(identifier:)
    ) -> SystemSpeechVoice? {
        SystemSpeechVoiceCatalog.savedVoice(
            identifier: manifest?.voice?.macOSVoiceIdentifier,
            localeIdentifier: speechVoiceLocaleIdentifier(manifest: manifest),
            lookup: lookup
        )
    }

    static func speechVoiceSetupDetail(
        manifest: AgentSettingsManifest?,
        lookup: (String) -> SystemSpeechVoice? = SystemSpeechVoiceCatalog.installedVoice(identifier:)
    ) -> String {
        guard manifest?.voice?.macOSVoiceIdentifier != nil else {
            return "automatic voice"
        }
        guard let voice = savedSpeechVoice(manifest: manifest, lookup: lookup) else {
            return "automatic voice (saved voice unavailable)"
        }
        return "voice \(voice.name) (\(voice.language))"
    }

    static func speechVoiceIsChosen(
        manifest: AgentSettingsManifest?,
        lookup: (String) -> SystemSpeechVoice? = SystemSpeechVoiceCatalog.installedVoice(identifier:)
    ) -> Bool {
        savedSpeechVoice(manifest: manifest, lookup: lookup) != nil
    }

    /// "Automatic", the voices of the locale's language, then "Back".
    static func speechVoiceMenuItems(
        installedVoices: [SystemSpeechVoice],
        localeIdentifier: String
    ) -> [TerminalCheckboxMenuItem<SpeechVoiceAction>] {
        let automaticDetail: String
        if let automatic = SystemSpeechVoiceCatalog.automaticVoice(
            in: installedVoices,
            localeIdentifier: localeIdentifier
        ) {
            automaticDetail = "best installed voice, now \(automatic.name) (\(automatic.language) · \(automatic.quality.title))"
        } else {
            automaticDetail = "system default voice for \(localeIdentifier)"
        }
        var items = [TerminalCheckboxMenuItem(
            value: SpeechVoiceAction.automatic,
            title: "Automatic",
            detail: automaticDetail
        )]
        items += SystemSpeechVoiceCatalog.voices(installedVoices, forLocale: localeIdentifier).map { voice in
            TerminalCheckboxMenuItem(
                value: SpeechVoiceAction.voice(voice.identifier),
                title: voice.name,
                detail: "\(voice.language) · \(voice.quality.title)"
            )
        }
        items.append(TerminalCheckboxMenuItem(
            value: .back,
            title: "Back",
            detail: "return to the main setup menu"
        ))
        return items
    }

    /// Chooses the reading voice and returns the manifest with the choice
    /// staged; Back or Esc returns it unchanged.
    static func configureSpeechVoice(
        manifest: AgentSettingsManifest?,
        installedVoices: [SystemSpeechVoice] = SystemSpeechVoiceCatalog.installedVoices(),
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectOne: (String, [TerminalCheckboxMenuItem<SpeechVoiceAction>], SpeechVoiceAction) -> SpeechVoiceAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) -> AgentSettingsManifest? {
        let localeIdentifier = speechVoiceLocaleIdentifier(manifest: manifest)
        let voices = SystemSpeechVoiceCatalog.voices(installedVoices, forLocale: localeIdentifier)
        let lookup: (String) -> SystemSpeechVoice? = { identifier in
            installedVoices.first { $0.identifier == identifier }
        }
        write(
            """

            Voice mode on macOS listens with Apple speech recognition and reads answers
            aloud with a system voice; nothing is downloaded. Listed are the voices
            installed for \(localeIdentifier), the language voice mode listens and reads in.
            Add voices in System Settings > Accessibility > Spoken Content > System voice
            > Manage Voices. Siri voices are not available to other apps and are not
            listed. The choice is saved when setup finishes and applies the next time
            /voice on starts.
            Current: \(speechVoiceSetupDetail(manifest: manifest, lookup: lookup))

            """
        )
        if voices.isEmpty {
            write("No installed voice reads \(localeIdentifier); voice mode uses the system default voice.\n")
        }
        let savedIdentifier = manifest?.voice?.macOSVoiceIdentifier
        let selected = savedIdentifier
            .flatMap { identifier in voices.contains { $0.identifier == identifier } ? identifier : nil }
            .map(SpeechVoiceAction.voice) ?? .automatic
        guard let action = selectOne(
            "Choose the voice that reads answers aloud (\(localeIdentifier))",
            speechVoiceMenuItems(installedVoices: installedVoices, localeIdentifier: localeIdentifier),
            selected
        ) else {
            return manifest
        }

        switch action {
        case .back:
            return manifest
        case .automatic:
            write("Reading voice: automatic.\n\n")
            return manifestByUpdatingSpeechVoice(manifest, identifier: nil)
        case let .voice(identifier):
            if let voice = voices.first(where: { $0.identifier == identifier }) {
                write("Reading voice: \(voice.name) (\(voice.language)).\n\n")
            }
            return manifestByUpdatingSpeechVoice(manifest, identifier: identifier)
        }
    }

    /// Stores `identifier` as the macOS reading voice, keeping the Telegram
    /// transcription settings. An unchanged choice returns `manifest` as is.
    static func manifestByUpdatingSpeechVoice(
        _ manifest: AgentSettingsManifest?,
        identifier: String?
    ) -> AgentSettingsManifest? {
        guard identifier != manifest?.voice?.macOSVoiceIdentifier else {
            return manifest
        }
        let current = manifest?.voice
        return AgentSettingsManifest(
            version: manifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: manifest?.providers ?? [],
            models: manifest?.models ?? [],
            selectedModelID: manifest?.selectedModelID,
            selectedThinkingSelection: manifest?.selectedThinkingSelection,
            telegram: manifest?.telegram,
            voice: AgentVoiceSettingsManifest(
                enabled: current?.enabled ?? false,
                macOSVoiceIdentifier: identifier
            ),
            remoteAPIKeysByProviderID: manifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: manifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: manifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest?.anthropicSubscriptionCredentials,
            responseLanguage: manifest?.responseLanguage,
            memoryEmbedding: manifest?.memoryEmbedding
        )
    }
}

#if os(macOS)
extension ZenCODESetupRunner {
    enum SpeechVoicePreviewAction: Hashable {
        case listen
        case use
        case back
    }

    /// "▶ Listen", "Use this voice" and "Back" for `voice`, the voice that
    /// reads answers with the item chosen in the list.
    static func speechVoicePreviewMenuItems(
        voice: SystemSpeechVoice,
        isAutomatic: Bool
    ) -> [TerminalCheckboxMenuItem<SpeechVoicePreviewAction>] {
        [
            TerminalCheckboxMenuItem(
                value: .listen,
                title: "▶ Listen",
                detail: "play a short sample read by \(voice.name)"
            ),
            TerminalCheckboxMenuItem(
                value: .use,
                title: "Use this voice",
                detail: isAutomatic
                    ? "keep the automatic choice, saved when setup finishes"
                    : "read answers with \(voice.name), saved when setup finishes"
            ),
            TerminalCheckboxMenuItem(
                value: .back,
                title: "Back",
                detail: "return to the voice list"
            )
        ]
    }

    /// The macOS section: like `configureSpeechVoice`, but choosing a voice,
    /// or Automatic while an installed voice reads the language, opens a
    /// submenu that plays a sample. Only "Use this voice" stages the choice;
    /// its Back returns to the list. A sample never outlives the submenu.
    static func configureSpeechVoiceWithPreview(
        manifest: AgentSettingsManifest?,
        installedVoices: [SystemSpeechVoice] = SystemSpeechVoiceCatalog.installedVoices(),
        player: any SpeechVoicePreviewPlaying = SystemSpeechVoicePreviewPlayer(),
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectOne: (String, [TerminalCheckboxMenuItem<SpeechVoiceAction>], SpeechVoiceAction) -> SpeechVoiceAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        selectPreview: (String, [TerminalCheckboxMenuItem<SpeechVoicePreviewAction>], SpeechVoicePreviewAction) -> SpeechVoicePreviewAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) -> AgentSettingsManifest? {
        defer { player.stop() }
        let localeIdentifier = speechVoiceLocaleIdentifier(manifest: manifest)
        let voices = SystemSpeechVoiceCatalog.voices(installedVoices, forLocale: localeIdentifier)
        let automatic = SystemSpeechVoiceCatalog.automaticVoice(
            in: installedVoices,
            localeIdentifier: localeIdentifier
        )
        return configureSpeechVoice(
            manifest: manifest,
            installedVoices: installedVoices,
            write: write,
            selectOne: { title, items, selected in
                // Called once, right after the section introduction.
                if !voices.isEmpty {
                    write("Choose a voice to listen to a sample before using it.\n")
                }
                while true {
                    guard let action = selectOne(title, items, selected) else {
                        return nil
                    }
                    let voice: SystemSpeechVoice?
                    switch action {
                    case .back:
                        return .back
                    case .automatic:
                        voice = automatic
                    case let .voice(identifier):
                        voice = voices.first { $0.identifier == identifier }
                    }
                    // Without a voice to play, the choice applies as is.
                    guard let voice else {
                        return action
                    }
                    if previewSpeechVoice(
                        voice,
                        isAutomatic: action == .automatic,
                        player: player,
                        write: write,
                        selectPreview: selectPreview
                    ) {
                        return action
                    }
                }
            }
        )
    }

    /// Plays samples of `voice` on request until the operator uses it
    /// (`true`) or goes back with Back or Esc (`false`). Every new sample
    /// stops the previous one, and leaving stops the one being read.
    static func previewSpeechVoice(
        _ voice: SystemSpeechVoice,
        isAutomatic: Bool,
        player: any SpeechVoicePreviewPlaying,
        write: (String) -> Void,
        selectPreview: (String, [TerminalCheckboxMenuItem<SpeechVoicePreviewAction>], SpeechVoicePreviewAction) -> SpeechVoicePreviewAction?
    ) -> Bool {
        defer { player.stop() }
        let description = "\(voice.name) (\(voice.language) · \(voice.quality.title))"
        let title = isAutomatic ? "Automatic: now \(description)" : description
        let items = speechVoicePreviewMenuItems(voice: voice, isAutomatic: isAutomatic)
        let sample = SystemSpeechVoicePreview.sampleText(for: voice)
        while true {
            switch selectPreview(title, items, .listen) {
            case .listen:
                player.stop()
                if !player.play(sample, voiceIdentifier: voice.identifier) {
                    write("\(voice.name) is no longer installed; choose another voice.\n")
                }
            case .use:
                return true
            case .back, nil:
                return false
            }
        }
    }
}
#endif
