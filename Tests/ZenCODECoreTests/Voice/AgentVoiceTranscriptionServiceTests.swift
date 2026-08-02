//
//  AgentVoiceTranscriptionServiceTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

#if canImport(Speech)
import Speech

@Suite
struct AgentVoiceTranscriptionServiceTests {
    @Test
    func recognitionRequestIsConfiguredForAccurateDictation() {
        let request = SFSpeechURLRecognitionRequest(
            url: URL(fileURLWithPath: "/tmp/ZenCODE-voice-test.m4a")
        )

        AgentVoiceTranscriptionService.configureRecognitionRequest(request)

        #expect(!request.shouldReportPartialResults)
        #expect(request.taskHint == .dictation)
        #expect(request.addsPunctuation)
        #expect(!request.requiresOnDeviceRecognition)
    }
}
#endif
