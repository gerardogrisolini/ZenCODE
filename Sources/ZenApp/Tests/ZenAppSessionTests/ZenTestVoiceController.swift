//
//  ZenTestVoiceController.swift
//  ZenAppSessionTests
//
//  A voice mode controller for tests, which records what it is asked to read
//  and reports what the test makes it hear, and the factory that keeps the
//  controllers /voice on created.
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

// MARK: - Test controller

/// A voice controller that records what it is asked to read and reports
/// what the test makes it hear, through the session's callbacks, as the
/// platform controllers do: previews, sends, the start and end of a reading.
actor ZenTestVoiceController: VoiceModeController {
    struct Spoken: Equatable, Sendable {
        let text: String
        let rendering: VoiceModeSpeechRendering
    }

    nonisolated let languageCode = "en"
    nonisolated let callbacks: VoiceModeCallbacks
    private(set) var isActive = true
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [Spoken] = []
    private(set) var interruptions = 0
    private(set) var discarded: [UInt64] = []
    /// The dictation the controller collects now; from 1, as the platform
    /// controllers number them.
    private(set) var dictationID: UInt64 = 1
    private var preview = ""

    init(callbacks: VoiceModeCallbacks) {
        self.callbacks = callbacks
    }

    var spokenTexts: [String] {
        spoken.map(\.text)
    }

    func start() async {
        await callbacks.systemMessage("Voice: listening (test).\n")
    }

    func stop() async {
        isActive = false
        await endReading()
        await publish("")
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard isActive, !isPaused, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        spoken.append(Spoken(text: text, rendering: rendering))
        if !isSpeaking {
            isSpeaking = true
            await callbacks.speakingChanged(true)
        }
        return true
    }

    func interruptPlayback() async {
        interruptions += 1
        await endReading()
    }

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else { return false }
        isPaused = paused
        if paused {
            // As the platform controllers: the reading stops and the
            // preview leaves the draft.
            await endReading()
            await publish("")
        }
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {}

    func discardDictation(through id: UInt64) async {
        discarded.append(id)
        guard id >= dictationID else { return }
        dictationID = id &+ 1
        preview = ""
    }

    // MARK: Driven by the test

    /// The speech recognized so far for the current dictation.
    func hear(_ text: String) async {
        await publish(text)
    }

    /// A preview of an older dictation, still on its way.
    func hearLate(id: UInt64, _ text: String) async {
        await callbacks.dictationChanged(id, text)
    }

    /// The current dictation ends with `text`, its final words, and is sent.
    func send(_ text: String) async {
        let id = dictationID
        dictationID &+= 1
        preview = ""
        await callbacks.utteranceRecognized(.dictation(id: id, text: text))
    }

    /// A bare yes or no the live-chat dialogue awaits.
    func answer(_ text: String) async {
        await callbacks.utteranceRecognized(.answer(text))
    }

    /// The reading ends on its own.
    func finishReading() async {
        await endReading()
    }

    private func endReading() async {
        guard isSpeaking else { return }
        isSpeaking = false
        await callbacks.speakingChanged(false)
    }

    private func publish(_ text: String) async {
        guard text != preview else { return }
        preview = text
        await callbacks.dictationChanged(dictationID, text)
    }
}

/// The controllers `/voice on` created, the newest last.
final class ZenTestVoiceControllers: Sendable {
    private let created = Mutex<[ZenTestVoiceController]>([])

    var all: [ZenTestVoiceController] {
        created.withLock { $0 }
    }

    var latest: ZenTestVoiceController? {
        all.last
    }

    var session: VoiceModeSession {
        VoiceModeSession { [self] callbacks in
            let controller = ZenTestVoiceController(callbacks: callbacks)
            created.withLock { $0.append(controller) }
            return .ready(controller)
        }
    }
}
