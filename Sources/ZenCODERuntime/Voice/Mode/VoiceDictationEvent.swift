//
//  VoiceDictationEvent.swift
//  ZenCODE
//
//  The values of dictation voice mode: the recognizer events and errors, and
//  the settling and restart policy of audio device changes.
//

import Foundation

enum VoiceDictationEvent: Sendable, Equatable {
    /// A recognition result. `endsSegment` marks a final one, which closes
    /// the speech segment recognized since the previous final result: the
    /// next results hold only what is said after it, so the earlier words
    /// must be kept by the receiver.
    case partial(generation: UInt64, text: String, endsSegment: Bool)
    case ended(generation: UInt64)
}

enum VoiceDictationError: LocalizedError, Equatable {
    case unsupportedPlatform
    case unsupportedLanguage(String)
    /// The language's speech model could not be downloaded: the locale and
    /// the reason.
    case speechModelDownloadFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice mode requires macOS."
        case let .unsupportedLanguage(identifier):
            return "Speech recognition does not support \(identifier)."
        case let .speechModelDownloadFailed(identifier, detail):
            return "The speech recognition model for \(identifier) could not be downloaded (\(detail)). Check the network connection and run /voice on again."
        }
    }
}

/// Groups a burst of change notifications, e.g. the audio configuration
/// changes posted while headphones connect: each change waits a short
/// settling time, and only the last one of the burst then proceeds.
struct VoiceChangeSettler: Sendable, Equatable {
    private var latest: UInt64 = 0

    /// Records a change and returns its token.
    mutating func begin() -> UInt64 {
        latest &+= 1
        return latest
    }

    /// Whether no change was recorded after the one with `token`.
    func isLatest(_ token: UInt64) -> Bool {
        token == latest
    }
}

/// Decides what follows a restart of the voice device after an audio device
/// change: the engine may stop again right away, e.g. when it never stays
/// running on the new hardware, and restarting must not go on forever.
struct VoiceAudioRestartPolicy: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        /// The engine runs: listen again and tell the user.
        case announce
        /// The engine stopped again: show nothing, another restart follows.
        case retry
        /// The engine keeps stopping: give up.
        case fail
    }

    /// The restarts in a row after which the engine was stopped again.
    static let maximumConsecutiveAudioRestarts = 3

    private(set) var consecutiveAudioRestarts = 0

    /// Records a restart of the device and returns what follows it.
    /// `isEngineRunning` is whether the engine runs right after the restart.
    mutating func restarted(isEngineRunning: Bool) -> Decision {
        guard !isEngineRunning else {
            consecutiveAudioRestarts = 0
            return .announce
        }
        consecutiveAudioRestarts += 1
        return consecutiveAudioRestarts >= Self.maximumConsecutiveAudioRestarts ? .fail : .retry
    }

    mutating func reset() {
        consecutiveAudioRestarts = 0
    }
}
