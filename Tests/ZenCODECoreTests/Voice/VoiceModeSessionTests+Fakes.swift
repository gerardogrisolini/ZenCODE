//
//  VoiceModeSessionTests+Fakes.swift
//  ZenCODECoreTests
//
//  The fake voice controller and the fake session host that the voice mode
//  session tests drive, shared by the suite and its extensions.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

/// A voice controller that listens until stopped, never speaks for real and
/// records every call.
actor SessionFakeVoiceController: VoiceModeController {
    struct Spoken: Sendable, Equatable {
        let text: String
        let rendering: VoiceModeSpeechRendering
    }

    nonisolated let languageCode = "it"
    private(set) var isActive = true
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [Spoken] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var interruptCount = 0
    private(set) var awaitingShortAnswer: [Bool] = []
    private(set) var discarded: [UInt64] = []
    /// While `true`, `start()` waits for ``releaseStart()``.
    private var isStartHeld = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated let installedCallbacks = Mutex<VoiceModeCallbacks?>(nil)

    /// The callbacks the session created this controller with.
    nonisolated var callbacks: VoiceModeCallbacks? {
        installedCallbacks.withLock { $0 }
    }

    nonisolated func install(_ callbacks: VoiceModeCallbacks) {
        installedCallbacks.withLock { $0 = callbacks }
    }

    /// Pretends a reading is in progress (`true`) or over (`false`).
    func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
    }

    /// Pretends the controller failed on its own.
    func fail() {
        isActive = false
    }

    /// Makes the next `start()` wait for ``releaseStart()``, as a
    /// controller that asks for a permission or loads its models.
    func holdStart() {
        isStartHeld = true
    }

    func releaseStart() {
        isStartHeld = false
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func start() async {
        startCount += 1
        guard isStartHeld else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func stop() async {
        stopCount += 1
        isActive = false
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard isActive, !isPaused, !text.isEmpty else {
            return false
        }
        spoken.append(Spoken(text: text, rendering: rendering))
        return true
    }

    func interruptPlayback() async {
        interruptCount += 1
    }

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {
        awaitingShortAnswer.append(awaiting)
    }

    func discardDictation(through id: UInt64) async {
        discarded.append(id)
    }
}

/// A channel that records what the session asks of it.
@ChatSessionActor
final class FakeVoiceModeHost: VoiceModeSessionHost {
    enum Shown: Equatable {
        case system(String)
        case failure(String)
    }

    struct Sent: Equatable {
        let text: String
        let destination: AgentSharedChat.Destination
    }

    /// What arrived from the controller's context.
    struct ControllerLog: Sendable, Equatable {
        var previews: [String] = []
        var takes: [UInt64] = []
        var utterances: [String] = []
        var speaking: [Bool] = []
        var deadlines: [UUID] = []
    }

    var shown: [Shown] = []
    var startCount = 0
    var stopCount = 0
    var submitted: [VoiceModeDictatedInput] = []
    var submitResult = true
    var participants: [AgentSharedChat.Participant] = []
    var readIDs: Set<UUID> = []
    var markedRead: [UUID] = []
    var admitsInput = true
    var destinationIsActive = true
    var sendSucceeds = true
    var sent: [Sent] = []
    /// The typed draft a dictation is sent after; `nil` when an edit ended
    /// the dictation.
    nonisolated let draft: String?
    private nonisolated let log = Mutex(ControllerLog())

    init(draft: String? = "") {
        self.draft = draft
    }

    nonisolated var controllerLog: ControllerLog {
        log.withLock { $0 }
    }

    func voiceModeShowSystemMessage(_ text: String) async {
        shown.append(.system(text))
    }

    func voiceModeShowFailureMessage(_ text: String) async {
        shown.append(.failure(text))
    }

    func voiceModeDidStart() async {
        startCount += 1
    }

    func voiceModeDidStop() async {
        stopCount += 1
    }

    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool {
        submitted.append(input)
        return submitResult
    }

    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        participants
    }

    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool {
        !readIDs.contains(id)
    }

    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async {
        markedRead.append(id)
    }

    func voiceModeAdmitsInput() async -> Bool {
        admitsInput
    }

    func voiceModeIsActiveSharedChatDestination(_ destination: AgentSharedChat.Destination) async -> Bool {
        destinationIsActive
    }

    func voiceModeSendSharedChatMessage(_ text: String, to destination: AgentSharedChat.Destination) async -> Bool {
        sent.append(Sent(text: text, destination: destination))
        return sendSucceeds
    }

    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async {
        log.withLock { $0.previews.append("\(id):\(text)") }
    }

    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String? {
        log.withLock { $0.takes.append(id) }
        return draft.map { VoiceModeSendKeyword.joined($0, text) }
    }

    nonisolated func voiceModeDeliverUtterance(_ text: String) async {
        log.withLock { $0.utterances.append(text) }
    }

    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async {
        log.withLock { $0.speaking.append(isSpeaking) }
    }

    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async {
        log.withLock { $0.deadlines.append(token) }
    }
}
