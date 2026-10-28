//
//  AgentVoiceTranscriptionServiceTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

#if canImport(Speech)
@Suite
struct AgentVoiceTranscriptionServiceTests {
    private let italian = Locale(identifier: "it_IT")
    private let russian = Locale(identifier: "ru_RU")

    @Test
    func speechTranscriberIsPreferredWhenItSupportsTheLanguage() {
        let model = AppleSpeechModel.resolve(
            speechTranscriberLocale: italian,
            dictationTranscriberLocale: italian,
            isSpeechTranscriberAvailable: true
        )
        #expect(model == .speechTranscriber(italian))
        #expect(model?.locale == italian)
    }

    @Test
    func dictationTranscriberCoversLanguagesSpeechTranscriberDoesNotSupport() {
        let model = AppleSpeechModel.resolve(
            speechTranscriberLocale: nil,
            dictationTranscriberLocale: russian,
            isSpeechTranscriberAvailable: true
        )
        #expect(model == .dictationTranscriber(russian))
        #expect(model?.locale == russian)
    }

    @Test
    func dictationTranscriberIsUsedWhenSpeechTranscriberIsUnavailable() {
        let model = AppleSpeechModel.resolve(
            speechTranscriberLocale: italian,
            dictationTranscriberLocale: italian,
            isSpeechTranscriberAvailable: false
        )
        #expect(model == .dictationTranscriber(italian))
    }

    @Test
    func noModelWhenNeitherSupportsTheLanguage() {
        #expect(AppleSpeechModel.resolve(
            speechTranscriberLocale: nil,
            dictationTranscriberLocale: nil,
            isSpeechTranscriberAvailable: true
        ) == nil)
        #expect(AppleSpeechModel.resolve(
            speechTranscriberLocale: italian,
            dictationTranscriberLocale: nil,
            isSpeechTranscriberAvailable: false
        ) == nil)
    }

    @Test
    func modelDownloadFailuresTellHowToRetry() {
        #expect(
            AgentVoiceTranscriptionError.speechModelDownloadFailed(language: "it_IT", detail: "offline")
                .localizedDescription
                == "The speech recognition model for it_IT could not be downloaded (offline). Check the network connection and send the voice message again."
        )
        #expect(
            TerminalDictationError.speechModelDownloadFailed("it_IT", "offline").localizedDescription
                == "The speech recognition model for it_IT could not be downloaded (offline). Check the network connection and run /voice on again."
        )
    }
}
#endif
