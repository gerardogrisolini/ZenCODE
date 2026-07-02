//
//  TerminalVoiceRecordingService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
#if canImport(os)
import os
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct TerminalVoiceRecordingSession: Equatable, Sendable {
    public let fileURL: URL
    public let startedAt: Date
}

public final class TerminalVoiceRecordingService: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    #endif
    private var activeSession: TerminalVoiceRecordingSession?

    public init() {}

    public func startRecording() async throws -> TerminalVoiceRecordingSession {
        #if canImport(AVFoundation)
        try await ensureMicrophoneAccess()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw TerminalVoiceRecordingError.startFailed
        }

        let session = TerminalVoiceRecordingSession(
            fileURL: fileURL,
            startedAt: Date()
        )
        storeActiveRecorder(recorder, session: session)
        return session
        #else
        throw TerminalVoiceRecordingError.unsupportedPlatform
        #endif
    }

    public func stopRecording() throws -> AgentVoiceAudioInput {
        #if canImport(AVFoundation)
        let (recorder, session) = lock.withLock {
            let state = (recorder: self.recorder, session: activeSession)
            self.recorder = nil
            activeSession = nil
            return state
        }

        guard let recorder, let session else {
            throw TerminalVoiceRecordingError.noActiveRecording
        }
        recorder.stop()
        guard FileManager.default.fileExists(atPath: session.fileURL.path) else {
            throw TerminalVoiceRecordingError.unreadableRecording
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: session.fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize == 0 {
            try? FileManager.default.removeItem(at: session.fileURL)
            throw TerminalVoiceRecordingError.emptyRecording
        }
        return AgentVoiceAudioInput(
            fileURL: session.fileURL,
            filename: session.fileURL.lastPathComponent,
            contentType: "audio/mp4",
            removeAfterUse: true
        )
        #else
        throw TerminalVoiceRecordingError.unsupportedPlatform
        #endif
    }

    public func cancelRecording() {
        #if canImport(AVFoundation)
        let (recorder, fileURL) = lock.withLock {
            let state = (recorder: self.recorder, fileURL: activeSession?.fileURL)
            self.recorder = nil
            activeSession = nil
            return state
        }

        recorder?.stop()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        #endif
    }

    #if canImport(AVFoundation)
    private func storeActiveRecorder(
        _ recorder: AVAudioRecorder,
        session: TerminalVoiceRecordingSession
    ) {
        lock.withLock {
            self.recorder = recorder
            activeSession = session
        }
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw TerminalVoiceRecordingError.microphoneAccessDenied
            }
        case .denied, .restricted:
            throw TerminalVoiceRecordingError.microphoneAccessDenied
        @unknown default:
            throw TerminalVoiceRecordingError.microphoneAccessDenied
        }
    }
    #endif
}

public enum TerminalVoiceRecordingError: LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case microphoneAccessDenied
    case startFailed
    case noActiveRecording
    case unreadableRecording
    case emptyRecording

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice recording is not supported on this platform."
        case .microphoneAccessDenied:
            return "Microphone access is denied. Enable microphone access for ZenCODE in macOS Settings."
        case .startFailed:
            return "Unable to start voice recording."
        case .noActiveRecording:
            return "No active voice recording."
        case .unreadableRecording:
            return "Unable to read the recorded audio."
        case .emptyRecording:
            return "Recorded audio is empty."
        }
    }
}
