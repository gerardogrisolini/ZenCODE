//
//  TerminalVoiceController.swift
//  ZenCODE
//
//  The platform-neutral contract of terminal voice mode. macOS runs local
//  dictation with Apple speech frameworks; Linux runs the downloaded
//  sherpa-onnx programs. Both turn utterances into ordinary prompts and read
//  final answers aloud; audio is never persisted.
//

import Foundation

/// Where a voice controller reports what happens.
struct TerminalVoiceCallbacks: Sendable {
    let systemMessage: @Sendable (String) async -> Void
    let failureMessage: @Sendable (String) async -> Void
    let utteranceRecognized: @Sendable (String) async -> Void
    /// The controller started (`true`) or stopped (`false`) reading an
    /// answer aloud, so `Esc` can stop the reading.
    let speakingChanged: @Sendable (Bool) async -> Void
}

/// One platform's voice mode: dictation into ordinary prompts and spoken
/// answers.
protocol TerminalVoiceController: Actor {
    /// `false` once the controller failed or was stopped; `/voice on` then
    /// starts a new one.
    var isActive: Bool { get }
    /// A paused voice mode neither listens nor reads answers aloud.
    var isPaused: Bool { get }

    func start() async
    func stop() async
    /// Reads a final answer aloud, replacing anything still being read.
    func speak(_ response: String) async
    /// Stops the answer being read, e.g. after `Esc`.
    func interruptPlayback() async
    /// Returns `false` when already in the requested state.
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool
}

enum TerminalVoiceControllerCreation {
    case ready(any TerminalVoiceController)
    /// Voice mode cannot run here; the message explains why.
    case unavailable(String)
}

enum TerminalVoicePlatform {
    static let unsupportedMessage = "ZenCODE: voice mode requires macOS or Linux.\n"

    /// Builds the controller for this platform. On Linux it requires the
    /// files downloaded from `/setup` > Voice mode.
    static func makeController(
        languageCode: String,
        callbacks: TerminalVoiceCallbacks
    ) -> TerminalVoiceControllerCreation {
        #if os(macOS)
        guard TerminalDictationVoiceController.isSupported else {
            return .unavailable(unsupportedMessage)
        }
        return .ready(TerminalDictationVoiceController(
            languageCode: languageCode,
            locale: AgentVoiceTranscriptionService.locale(for: languageCode),
            callbacks: callbacks
        ))
        #elseif os(Linux)
        switch SherpaOnnxVoiceInstallation.standard().runtimePaths() {
        case let .success(paths):
            return .ready(TerminalSherpaVoiceController(paths: paths, callbacks: callbacks))
        case let .failure(error):
            return .unavailable("ZenCODE: \(error.localizedDescription)\n")
        }
        #else
        return .unavailable(unsupportedMessage)
        #endif
    }
}
