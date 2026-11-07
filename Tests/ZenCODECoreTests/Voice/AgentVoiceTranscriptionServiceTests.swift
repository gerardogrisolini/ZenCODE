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
    /// SpeechTranscriber is preferred when it supports the language and is
    /// available; DictationTranscriber covers the languages it does not support
    /// and replaces it when it is unavailable; no model when neither fits.
    @Test(arguments: [
        (
            Locale(identifier: "it_IT"), Locale(identifier: "it_IT"), true,
            AppleSpeechModel.speechTranscriber(Locale(identifier: "it_IT"))
        ),
        (nil, Locale(identifier: "ru_RU"), true, .dictationTranscriber(Locale(identifier: "ru_RU"))),
        (Locale(identifier: "it_IT"), Locale(identifier: "it_IT"), false, .dictationTranscriber(Locale(identifier: "it_IT"))),
        (nil, nil, true, nil),
        (Locale(identifier: "it_IT"), nil, false, nil)
    ] as [(Locale?, Locale?, Bool, AppleSpeechModel?)])
    func speechTranscriberIsPreferredWhenItSupportsTheLanguage(
        speechTranscriberLocale: Locale?,
        dictationTranscriberLocale: Locale?,
        isSpeechTranscriberAvailable: Bool,
        expected: AppleSpeechModel?
    ) {
        let model = AppleSpeechModel.resolve(
            speechTranscriberLocale: speechTranscriberLocale,
            dictationTranscriberLocale: dictationTranscriberLocale,
            isSpeechTranscriberAvailable: isSpeechTranscriberAvailable
        )
        #expect(model == expected)
        #expect(model?.locale == expected?.locale)
    }
}
#endif
