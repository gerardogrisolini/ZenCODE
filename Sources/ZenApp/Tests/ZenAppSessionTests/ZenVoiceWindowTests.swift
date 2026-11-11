//
//  ZenVoiceWindowTests.swift
//  ZenAppSessionTests
//
//  `/voice` in the app over a scripted backend and a test voice controller
//  (`VoiceModeSession(makeController:)`): nothing records, plays, or asks for
//  a permission. One voice mode for the whole app, following the active
//  window: the command texts, the app-wide state, dictation into the draft,
//  the answers, comments, and announcements read aloud, the per-turn
//  instruction, Esc, the switch of the active window, and its close.
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

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct ZenVoiceWindowTests {
    private static let instruction = "Voice mode is on: the user is listening and your final answer is read aloud. Answer in short sentences. While you work, briefly comment on what you are doing as you do it. Keep any format the request requires."
    private static let dormantRefusal = ZenTranscriptItem.Content.local(
        text: "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.",
        isFailure: true
    )
    private static let agentID = "agent-1"
    private static let agentName = "Reviewer"

    // MARK: Command

    @Test("/voice is a channel command of every window, always visible, run during a turn, with the app's help")
    func descriptor() throws {
        let registry = ZenAppCommands.registry
        let voice = try #require(registry.descriptor(forLine: "/voice on"))
        #expect(voice == ZenAppCommands.voice)
        #expect(voice.scope == .channel)
        #expect(voice.availability.isEmpty)
        #expect(voice.summary == "voice mode on/off/pause/resume")
        #expect(voice.help.hasPrefix("/voice on starts voice mode with any agent in the app:"))
        #expect(voice.help.hasSuffix("Voice mode lasts until the app quits."))
        #expect(!voice.help.contains("TUI"))
        for line in ["/voice", "/voice on", "/voice off", "/voice pause", "/voice resume"] {
            #expect(registry.isAvailableDuringGeneration(line), "\(line)")
        }
        #expect(ZenAppCommands.descriptors.map(\.command).suffix(3) == ["/telegram", "/voice", "/exit"])
        #expect(ZenAppCommands.visibleDescriptors(in: []).map(\.command).suffix(2) == ["/voice", "/exit"])
        #expect(ZenAppCommands.visibleDescriptors(in: ZenAppCommands.telegramEnabled).map(\.command).suffix(3)
            == ["/telegram", "/voice", "/exit"])
    }

    @Test("/voice answers with the terminal's texts: off, on, already on, pause, toggle, usage, off; it runs beside a turn")
    func commandTexts() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            #expect(window.voiceState == .off)

            try await Self.run("/voice", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(
                text: "ZenCODE: voice mode is off. Run /voice on to start it.",
                isFailure: true
            ))
            try await Self.run("/voice off", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Voice: already off.", isFailure: false))
            #expect(controllers.all.isEmpty)

            try await Self.run("/voice on", in: window, runtime)
            #expect(window.transcript.contains { $0.content == .commandLine("/voice on") })
            await waitUntil("voice mode is on") { window.voiceState == VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false) }
            await waitUntil("the controller says it listens") {
                window.transcript.contains { $0.content == .local(text: "Voice: listening (test).", isFailure: false) }
            }
            await waitUntil("voice mode follows the window") { window.isVoiceWindow }
            #expect(runtime.activeVoiceWindowID == window.id)
            #expect(controllers.all.count == 1)

            try await Self.run("/voice ON", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Voice: already on.", isFailure: false))
            #expect(controllers.all.count == 1)

            // While a prompt runs, /voice runs beside it, never queued.
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            window.draft = "/voice pause"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.isEmpty)
            await waitUntil("voice mode pauses") { window.voiceState.isPaused }
            await waitUntil("the pause is shown") {
                window.transcript.contains {
                    $0.content == .local(
                        text: "Voice: paused; not listening or reading answers aloud. /voice resumes it.",
                        isFailure: false
                    )
                }
            }
            #expect(window.isBusy)
            await backend.release()
            #expect(await window.waitUntilIdle())

            try await Self.run("/voice", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Voice: resumed.", isFailure: false))
            await waitUntil("voice mode resumes") { !window.voiceState.isPaused }
            try await Self.run("/voice resume", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Voice: already listening.", isFailure: false))
            try await Self.run("/voice sing", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Usage: /voice [on|off|pause|resume]", isFailure: false))

            try await Self.run("/voice off", in: window, runtime)
            #expect(Self.lastRow(of: window) == .local(text: "Voice: off.", isFailure: false))
            await waitUntil("voice mode is off") { window.voiceState == .off }
            let controller = try #require(controllers.latest)
            #expect(await !controller.isActive)
        }
    }

    @Test("A window Telegram drives refuses dictation, a dictated command, and a live message by voice, with the dormant text")
    func dormantWindowRefusesVoiceInput() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            window.isDrivenFromTelegram = true

            for utterance in ["che ore sono?", "/exit", "message to the coordinator: stop"] {
                let refusals = window.transcript.filter { $0.content == Self.dormantRefusal }.count
                await controller.send(utterance)
                await runtime.waitForVoice()
                await waitUntil("\(utterance) is refused") {
                    window.transcript.filter { $0.content == Self.dormantRefusal }.count == refusals + 1
                }
            }
            #expect(await window.waitUntilIdle())
            #expect(!window.closeRequested)
            #expect(window.queuedLines.isEmpty)
            #expect(await backend.prompts.isEmpty)
            #expect(await backend.sentSharedChatMessages.isEmpty)
        }
    }

    // MARK: App-wide state and the active window

    @Test("One voice mode for the whole app: every window shows its state, one follows it, and shutdown stops it")
    func appWideState() async throws {
        try await withVoice { runtime, _, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            #expect(runtime.activeVoiceWindowID == nil)

            try await Self.run("/voice on", in: second, runtime)
            await waitUntil("voice mode is on") { runtime.voiceState.isOn }
            await waitUntil("voice mode follows the second window") { second.isVoiceWindow }
            #expect(first.voiceState.isOn)
            #expect(second.voiceState.isOn)
            #expect(!first.isVoiceWindow)
            // The command did not reach the other window.
            #expect(!first.transcript.contains { $0.content == .commandLine("/voice on") })

            runtime.windowDidBecomeActive(first)
            await runtime.waitForVoice()
            await waitUntil("voice mode follows the first window") { first.isVoiceWindow }
            #expect(!second.isVoiceWindow)
            #expect(first.voiceState == second.voiceState)
            #expect(controllers.all.count == 1)

            // The window that runs /voice becomes the one voice follows.
            try await Self.run("/voice pause", in: second, runtime)
            await waitUntil("both windows show the pause") { first.voiceState.isPaused && second.voiceState.isPaused }
            await waitUntil("voice mode follows the second window again") { second.isVoiceWindow }

            let controller = try await Self.controller(controllers)
            await runtime.shutdown()
            #expect(await !controller.isActive)
            #expect(runtime.voiceState == .off)
            #expect(runtime.activeVoiceWindowID == nil)
        }
    }

    @Test("Dictation, answers, the instruction, and announcements reach the active window only; a coordinator turn's answer is read too")
    func routingToTheActiveWindow() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            let chat = await backend.sharedChat()
            let firstRoom = try await Self.room(of: first, runtime)
            let secondRoom = try await Self.room(of: second, runtime)
            for room in [firstRoom, secondRoom] {
                try await chat.registerCoordinator(roomID: room)
                try await chat.registerAgent(id: Self.agentID, name: Self.agentName, roomID: room)
            }
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)

            // A turn of the active window carries the instruction; its
            // answer is read aloud.
            first.draft = "Alpha"
            first.submitDraft()
            #expect(await first.waitUntilIdle())
            await waitUntil("the answer is read") {
                await controller.spokenTexts == ["Scripted answer to Alpha"]
            }
            #expect(await controller.spoken.last?.rendering == .answer)
            #expect(await backend.turnInstructions.last == Self.instruction)
            await controller.finishReading()

            // The other window's turn carries none and is not read.
            second.draft = "Beta"
            second.submitDraft()
            #expect(await second.waitUntilIdle())
            await runtime.waitForVoice()
            #expect(await backend.prompts.last == "Beta")
            #expect(await backend.turnInstructions.last == .some(nil))
            #expect(await controller.spokenTexts == ["Scripted answer to Alpha"])

            // Dictation goes to the active window's draft.
            await controller.hear("ciao")
            await waitUntil("the preview reaches the active draft") { first.draft == "ciao" }
            #expect(second.draft.isEmpty)
            first.draft = ""

            // A message for the operator in the other window's room stays
            // silent; one in the active window's room is announced.
            _ = try await chat.send(roomID: secondRoom, senderID: Self.agentID, destination: .operator, text: "Elsewhere")
            await waitUntil("the other reader has it") { second.sharedChat.unreadCount == 1 }
            await runtime.waitForVoice()
            #expect(await controller.spoken.count == 1)
            let delivery = try await chat.send(roomID: firstRoom, senderID: Self.agentID, destination: .operator, text: "Build is green")
            await waitUntil("the message is announced") {
                await controller.spoken.last?.rendering == .plainText
            }
            let announcement = try #require(await controller.spoken.last?.text)
            #expect(announcement.contains(Self.agentName))
            #expect(first.sharedChat.isUnread(delivery.message.id))

            // "Yes" reads it aloud, and the reader marks it read.
            await controller.answer("yes")
            await waitUntil("the message is read aloud") {
                await controller.spokenTexts.last?.contains("Build is green") == true
            }
            await waitUntil("the reader marks it read") { !first.sharedChat.isUnread(delivery.message.id) }
            #expect(first.sharedChat.unreadCount == 0)
            #expect(second.sharedChat.unreadCount == 1)
            await controller.finishReading()

            // A switch drops the dialogue; a coordinator turn of the active
            // window is a turn of the window: its answer is read.
            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice follows the second window") { second.isVoiceWindow }
            await backend.script(prompt: "Need a decision", events: [])
            let spokenBefore = await controller.spoken.count
            _ = try await chat.send(roomID: secondRoom, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the coordinator turn's answer is read") {
                await controller.spokenTexts.dropFirst(spokenBefore).contains("Scripted answer to Need a decision")
            }
            #expect(await second.waitUntilIdle())
            #expect(await backend.turnInstructions.last == Self.instruction)
        }
    }

    @Test("Switching windows while dictating keeps the words in the old draft as text; dictation goes on in the new window")
    func switchWhileDictating() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)

            first.draft = "Nota:"
            await controller.hear("ciao")
            await waitUntil("the preview shows") { first.draft == "Nota: ciao" }
            #expect(first.voiceDictation.isActive)
            let interruptions = await controller.interruptions

            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice follows the second window") { second.isVoiceWindow }
            // The old window keeps the words as ordinary text; voice forgets them.
            #expect(first.draft == "Nota: ciao")
            #expect(!first.voiceDictation.isActive)
            await waitUntil("voice forgets the dictation") { await controller.discarded == [1] }
            // The switch is a new target: the reading stops.
            #expect(await controller.interruptions == interruptions + 1)

            // A late preview of the ended dictation reaches neither window.
            await controller.hearLate(id: 1, "ciao mondo")
            await runtime.waitForVoice()
            #expect(first.draft == "Nota: ciao")
            #expect(second.draft.isEmpty)

            // Dictation goes on in the new window, and is sent from there.
            await controller.hear("hello")
            await waitUntil("the new window shows the dictation") { second.draft == "hello" }
            #expect(first.draft == "Nota: ciao")
            await controller.send("hello world")
            await waitUntil("the dictation runs in the new window") { await backend.prompts.last == "hello world" }
            #expect(await second.waitUntilIdle())
            #expect(second.draft.isEmpty)
            #expect(first.draft == "Nota: ciao")
        }
    }

    @Test("An utterance taken from a window that is no longer the active one goes back to its draft, unsent")
    func utteranceAfterASwitchGoesBack() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)
            first.draft = "Nota:"
            await controller.hear("ciao")
            await waitUntil("the preview shows") { first.draft == "Nota: ciao" }

            // The switch waits in the voice context while the controller,
            // still pointed at the first window, sends from its draft.
            let gate = ZenGate()
            await Self.hold(runtime.voice, at: gate) { request in
                if case .activate = request { return true }
                return false
            }
            runtime.windowDidBecomeActive(second)
            await waitUntil("the switch waits") { await gate.reached }
            await controller.send("ciao mondo")
            #expect(first.draft.isEmpty)
            await gate.open()
            await runtime.waitForVoice()
            await Self.hold(runtime.voice, at: nil) { _ in false }

            await waitUntil("voice follows the second window") { second.isVoiceWindow }
            #expect(first.draft == "Nota: ciao mondo")
            #expect(second.draft.isEmpty)
            #expect(await first.waitUntilIdle())
            #expect(await backend.prompts.isEmpty)
        }
    }

    @Test("Closing the active window moves voice mode to the most recent active window left, or to none")
    func closingTheActiveWindow() async throws {
        try await withVoice { runtime, _, _, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            let third = try await Self.open(runtime, workspace)
            runtime.windowDidBecomeActive(first)
            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice follows the second window") { runtime.activeVoiceWindowID == second.id }

            // Closing a window voice mode does not follow changes nothing.
            await third.close()
            await runtime.waitForVoice()
            #expect(runtime.activeVoiceWindowID == second.id)

            await second.close()
            await runtime.waitForVoice()
            await waitUntil("voice follows the first window") { runtime.activeVoiceWindowID == first.id }
            #expect(first.isVoiceWindow)

            await first.close()
            await runtime.waitForVoice()
            await waitUntil("voice follows no window") { runtime.activeVoiceWindowID == nil }

            // A closed window never becomes active again.
            runtime.windowDidBecomeActive(first)
            await runtime.waitForVoice()
            #expect(runtime.activeVoiceWindowID == nil)
        }
    }

    @Test("Bouncing between windows while dictating: each switch ends the dictation shown, and its late previews reach neither window")
    func bounceBetweenWindows() async throws {
        try await withVoice { runtime, _, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)

            await controller.hear("uno")
            await waitUntil("the preview shows in the first window") { first.draft == "uno" }
            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice forgets the first dictation") { await controller.discarded == [1] }

            await controller.hear("due")
            await waitUntil("the preview shows in the second window") { second.draft == "due" }
            runtime.windowDidBecomeActive(first)
            await runtime.waitForVoice()
            await waitUntil("voice follows the first window again") { first.isVoiceWindow }
            await waitUntil("voice forgets the second dictation") { await controller.discarded == [1, 2] }

            // Late previews of both ended dictations reach neither window.
            await controller.hearLate(id: 1, "uno e mezzo")
            await controller.hearLate(id: 2, "due e mezzo")
            await runtime.waitForVoice()
            #expect(first.draft == "uno")
            #expect(second.draft == "due")
            #expect(!first.voiceDictation.isActive)
            #expect(!second.voiceDictation.isActive)

            // Dictation goes on in the first window, after its text.
            await controller.hear("tre")
            await waitUntil("the next preview shows in the first window") { first.draft == "uno tre" }
            #expect(second.draft == "due")
        }
    }

    @Test("An edit ends the dictation before a switch asked after it: a late preview of it never shows in the window voice moves to")
    func editThenSwitchIgnoresTheEndedDictation() async throws {
        try await withVoice { runtime, _, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)
            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice follows the second window") { second.isVoiceWindow }

            await controller.hear("ciao")
            await waitUntil("the preview shows in the second window") { second.draft == "ciao" }
            // The edit ends the dictation; the switch comes right after it.
            second.draft = "ciao!"
            runtime.windowDidBecomeActive(first)
            await runtime.waitForVoice()
            await waitUntil("voice follows the first window") { first.isVoiceWindow }
            await waitUntil("voice forgets the dictation") { await controller.discarded == [1] }
            #expect(await runtime.voice.dictationFloor == 1)

            // A preview of the ended dictation, still on its way, arrives
            // after the switch: the first window ignores it.
            await controller.hearLate(id: 1, "ciao mondo")
            await runtime.waitForVoice()
            #expect(first.draft.isEmpty)
            #expect(!first.voiceDictation.isActive)
            #expect(second.draft == "ciao!")

            // The next dictation shows in the first window.
            await controller.hear("hello")
            await waitUntil("the next preview shows") { first.draft == "hello" }
        }
    }

    @Test("/voice on with voice mode already on keeps the ended dictations ignored; a new voice mode numbers them from 1 again")
    func voiceOnAlreadyOnKeepsTheFloor() async throws {
        try await withVoice { runtime, _, controllers, workspace in
            let first = try await Self.open(runtime, workspace)
            let second = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: first, runtime)
            let controller = try await Self.controller(controllers)
            await controller.hear("ciao")
            await waitUntil("the preview shows") { first.draft == "ciao" }
            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice forgets the dictation") { await controller.discarded == [1] }

            try await Self.run("/voice on", in: second, runtime)
            #expect(Self.lastRow(of: second) == .local(text: "Voice: already on.", isFailure: false))
            #expect(controllers.all.count == 1)
            #expect(await runtime.voice.dictationFloor == 1)

            // Back in the first window, a late preview of the ended dictation
            // stays out.
            runtime.windowDidBecomeActive(first)
            await runtime.waitForVoice()
            await waitUntil("voice follows the first window") { first.isVoiceWindow }
            await controller.hearLate(id: 1, "ciao mondo")
            await runtime.waitForVoice()
            #expect(first.draft == "ciao")
            #expect(!first.voiceDictation.isActive)

            // A new voice mode numbers its dictations from 1: they show.
            try await Self.run("/voice off", in: first, runtime)
            try await Self.run("/voice on", in: first, runtime)
            #expect(controllers.all.count == 2)
            #expect(await runtime.voice.dictationFloor == 0)
            let fresh = try await Self.controller(controllers)
            await fresh.hear("di nuovo")
            await waitUntil("the new voice mode's first dictation shows") { first.draft == "di nuovo" }
        }
    }

    // MARK: Draft

    @Test("The preview follows the typed text; an edit makes it text; pause and off remove it; voice sends the whole draft")
    func previewEditAndTake() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)

            window.draft = "Nota:"
            await controller.hear("ciao")
            await waitUntil("the preview shows") { window.draft == "Nota: ciao" }
            #expect(window.voiceDictationPreviewRange == 6..<10)
            #expect(window.voiceDictationUpdate?.change == .started)
            let started = try #require(window.voiceDictationUpdate?.revision)
            await controller.hear("ciao mondo")
            await waitUntil("the preview follows the speech") { window.draft == "Nota: ciao mondo" }
            #expect(window.voiceDictationUpdate == ZenVoiceDictationUpdate(
                revision: started + 1,
                change: .updated(previewStart: 6)
            ))
            // Setting the same text is not an edit.
            window.draft = window.draft
            #expect(window.voiceDictation.isActive)

            // An edit turns the dictation into text; voice forgets it.
            window.draft = "Nota: ciao mondo!"
            #expect(!window.voiceDictation.isActive)
            #expect(window.voiceDictationPreviewRange == nil)
            await waitUntil("voice forgets the dictation") { await controller.discarded == [1] }
            await controller.hearLate(id: 1, "ciao mondo e poi")
            #expect(window.draft == "Nota: ciao mondo!")

            // The next dictation goes after it; voice sends the whole draft.
            await controller.hear("di nuovo")
            await waitUntil("the next preview shows") { window.draft == "Nota: ciao mondo! di nuovo" }
            await controller.send("di nuovo")
            await waitUntil("the draft is sent") { await backend.prompts.last == "Nota: ciao mondo! di nuovo" }
            #expect(window.draft.isEmpty)
            #expect(window.voiceDictationUpdate?.change == .taken)
            // The prompt history records what was typed, not what voice sent.
            #expect(window.history.entries == ["/voice on"])
            #expect(await window.waitUntilIdle())

            // Pause removes the preview and keeps the typed text.
            window.draft = "Scritto"
            await controller.hear("parlato")
            await waitUntil("the preview shows") { window.draft == "Scritto parlato" }
            window.run("/voice pause")
            await waitUntil("the pause removes the preview") { window.draft == "Scritto" }
            #expect(window.voiceDictationUpdate?.change == .removed)
            #expect(!window.voiceDictation.isActive)
            #expect(await window.waitUntilIdle())

            // So does off.
            window.run("/voice resume")
            #expect(await window.waitUntilIdle())
            await runtime.waitForVoice()
            await controller.hear("ancora")
            await waitUntil("the preview shows") { window.draft == "Scritto ancora" }
            window.run("/voice off")
            await waitUntil("off removes the preview") { window.draft == "Scritto" }
            #expect(await window.waitUntilIdle())
        }
    }

    @Test("Dictated text that reads as a command runs as a plain prompt, also from the queue, never as a command")
    func slashTextIsAPlainPrompt() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)

            await controller.send("/exit now")
            await waitUntil("the text runs as a prompt") { await backend.prompts.last == "/exit now" }
            #expect(await window.waitUntilIdle())
            #expect(!window.closeRequested)
            #expect(!window.transcript.contains { $0.content == .commandLine("/exit now") })

            // While a prompt runs, it waits in the queue as a plain prompt.
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            await controller.send("/help me")
            await waitUntil("the plain prompt waits") { window.queuedLines.last?.text == "/help me" }
            #expect(window.queuedLines.last?.isPlainPrompt == true)
            await backend.release()
            await waitUntil("the queued plain prompt runs") { await backend.prompts.last == "/help me" }
            #expect(await window.waitUntilIdle())
            #expect(!window.transcript.contains { $0.content == .commandLine("/help me") })
        }
    }

    @Test("A full queue refuses a dictated plain prompt with the voice text, and a dictated line with the typed one")
    func fullQueue() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)

            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            for index in 0..<ZenWindowSession.queueCapacity {
                window.draft = "Queued \(index)"
                window.submitDraft()
            }
            #expect(window.queuedLines.count == ZenWindowSession.queueCapacity)

            await controller.send("/plain")
            await waitUntil("the plain prompt is refused") {
                Self.lastRow(of: window) == .local(text: ZenWindowSession.voiceQueueFullMessage, isFailure: true)
            }
            #expect(ZenWindowSession.voiceQueueFullMessage == "ZenCODE: prompt queue is full; voice prompt was not queued.")
            await controller.send("dictated line")
            await waitUntil("the line is refused") {
                Self.lastRow(of: window) == .local(text: ZenWindowSession.queueFullMessage, isFailure: true)
            }
            #expect(window.queuedLines.count == ZenWindowSession.queueCapacity)
            #expect(!window.queuedLines.contains { $0.text == "/plain" || $0.text == "dictated line" })

            for line in window.queuedLines {
                window.removeQueuedLine(line.id)
            }
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts == ["Long"])
        }
    }

    // MARK: Reading aloud

    @Test("Esc stops a reading and keeps the draft; while a turn runs it stops the turn and the reading")
    func escapeStopsTheReading() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)

            window.draft = "Alpha"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await waitUntil("the answer is read") { window.voiceState.isSpeaking }
            let interruptions = await controller.interruptions
            window.draft = "Bozza"
            window.handleEscape()
            await waitUntil("Esc stops the reading") { await controller.interruptions == interruptions + 1 }
            await waitUntil("nothing is read") { !window.voiceState.isSpeaking }
            #expect(window.draft == "Bozza")

            // Nothing is read and no line runs: Esc leaves voice alone.
            window.handleEscape()
            await runtime.waitForVoice()
            #expect(await controller.interruptions == interruptions + 1)
            #expect(window.draft == "Bozza")

            // While a turn runs: the turn and the reading stop.
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            window.handleEscape()
            await waitUntil("the turn is stopped") { backend.lifecycle.events.contains(.heldTurnCancelled) }
            await waitUntil("the reading is stopped") { await controller.interruptions == interruptions + 2 }
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.contains { $0.content == .local(text: ZenWindowSession.turnCancelledText, isFailure: false) })
        }
    }

    @Test("The main agent's comment before a tool call is read during its turn only; never the thinking")
    func commentaryDuringTheTurn() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            let call = DirectAgentToolCall(id: "read-1", name: "local.readFile", argumentsObject: [:], argumentsJSON: "{}")
            await backend.script(prompt: "Inspect", events: [
                .thought("Thinking about it."),
                .content("Reading the file."),
                .toolCallStarted(call),
                .toolCallCompleted(call, DirectAgentToolResult(output: "ok", summary: "ok")),
            ])

            window.draft = "Inspect"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await waitUntil("the comment and the answer are read") {
                await controller.spokenTexts == ["Reading the file.", "Scripted answer to Inspect"]
            }
            #expect(await controller.spoken.map(\.rendering) == [.answer, .answer])
            await controller.finishReading()
            await runtime.waitForVoice()

            // A comment after the turn ended is dropped.
            window.voiceHost.post(.commentary("Too late.", host: window.voiceHost))
            await runtime.waitForVoice()
            #expect(await controller.spokenTexts == ["Reading the file.", "Scripted answer to Inspect"])
        }
    }

    @Test("A /plan turn reads the Planner's response aloud, not the coordinator's own text")
    func planTurnReadsThePlannerResponse() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            let questions = "Planner questions\n1. Which language should the parser read?"

            // The Planner answers while the /plan turn runs.
            await backend.hold()
            window.draft = "/plan Build a parser"
            window.submitDraft()
            await backend.waitUntilHeld()
            await backend.setSubAgents([Self.planner(output: questions, root: window.current.sessionID)])
            await backend.release()
            #expect(await window.waitUntilIdle())

            await waitUntil("the Planner's response is read") { await controller.spokenTexts == [questions] }
            #expect(await backend.prompts.count == 1)
            #expect(await !controller.spokenTexts.contains("Scripted answer to Build a parser"))
        }
    }

    @Test("A turn adopted from Telegram reads, when it ends, the answer it showed the window; nothing when it showed none")
    func adoptedTurnAnswerIsRead() async throws {
        try await withVoice { runtime, _, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            window.adoptedTelegramTurnSleep = Self.quickSleep
            let call = DirectAgentToolCall(id: "read-1", name: "local.readFile", argumentsObject: [:], argumentsJSON: "{}")

            // The turn from Telegram that `/telegram off` adopted, still
            // running: what it presents from now on reaches the window.
            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            await window.presenter.beginAdoptedTurn()
            window.watchAdoptedTelegramTurn(reservation.promptID)
            await window.presenter.presentAssistantContent("Checking the file.")
            await window.presenter.presentToolCallStarted(call)
            await window.presenter.presentAssistantContent("All done.")
            await window.presenter.presentFinalResponse(
                DirectAgentResponse(text: "Checking the file.All done.", stopReason: "end_turn", modelID: "zen-app-model")
            )
            await Self.releasePrompt(reservation, in: runtime.sessionHost)
            #expect(await window.waitUntilIdle())
            #expect(window.adoptedTelegramPromptID == nil)
            // Its comment while it ran, then the text after its last tool call.
            await waitUntil("the adopted turn's answer is read") {
                await controller.spokenTexts == ["Checking the file.", "All done."]
            }
            await controller.finishReading()
            await runtime.waitForVoice()

            // An adopted turn that presented no final response reads nothing.
            let silent = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            await window.presenter.beginAdoptedTurn()
            window.watchAdoptedTelegramTurn(silent.promptID)
            await window.presenter.presentAssistantContent("Partial")
            await Self.releasePrompt(silent, in: runtime.sessionHost)
            #expect(await window.waitUntilIdle())
            await runtime.waitForVoice()
            #expect(await controller.spokenTexts == ["Checking the file.", "All done."])
        }
    }

    @Test("A new session in the active window is a new target: the reading stops; the instruction stays")
    func newSessionIsANewTarget() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            window.draft = "Alpha"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await waitUntil("the answer is read") { window.voiceState.isSpeaking }
            let interruptions = await controller.interruptions
            let epoch = window.current.epoch

            window.startNewSession()
            await waitUntil("the new session is followed") { window.current.epoch != epoch }
            #expect(await window.waitUntilIdle())
            await waitUntil("the reading stops") { await controller.interruptions == interruptions + 1 }

            window.draft = "Beta"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await backend.turnInstructions.last == Self.instruction)
        }
    }

    @Test("A live message by voice goes out through the window's mention path, to the coordinator or an active agent")
    func liveMessageByVoice() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            let room = try await Self.room(of: window, runtime)
            let chat = await backend.sharedChat()
            try await chat.registerCoordinator(roomID: room)
            try await chat.registerAgent(id: Self.agentID, name: Self.agentName, roomID: room)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)

            await controller.send("message to the coordinator: status?")
            await waitUntil("the message reaches the room") { await backend.sentSharedChatMessages.count == 1 }
            let toCoordinator = try #require(await backend.sentSharedChatMessages.last)
            #expect(toCoordinator.destination == .coordinator)
            #expect(toCoordinator.text == "status?")
            #expect(toCoordinator.rootSessionID == room)
            await waitUntil("voice confirms") { await controller.spokenTexts.last == "Sent." }
            await controller.finishReading()

            await controller.send("message to Reviewer: check the diff")
            await waitUntil("the message reaches the agent") { await backend.sentSharedChatMessages.count == 2 }
            let toAgent = try #require(await backend.sentSharedChatMessages.last)
            #expect(toAgent.destination == .direct([Self.agentID]))
            #expect(toAgent.text == "check the diff")
            await runtime.waitForVoice()
            // With the backend live from startup, the coordinator message can
            // start its automatic turn while voice delivers the direct one.
            // Wait for that legitimate turn before asserting that neither live
            // message added a prompt of its own.
            #expect(await window.waitUntilIdle())
            let promptsAfterLiveMessages = await backend.prompts
            #expect(promptsAfterLiveMessages.count == 2)
            #expect(promptsAfterLiveMessages.first == "Hello")
            #expect(promptsAfterLiveMessages.last?.contains("status?") == true)
            #expect(window.draft.isEmpty)
        }
    }

    // MARK: - Helpers

    /// The last row of the transcript.
    private static func lastRow(of window: ZenWindowSession) -> ZenTranscriptItem.Content? {
        window.transcript.last?.content
    }

    /// Runs `line` as typed and waits until the window and voice mode are
    /// done with it.
    private static func run(_ line: String, in window: ZenWindowSession, _ runtime: ZenAppRuntime) async throws {
        window.draft = line
        window.submitDraft()
        #expect(await window.waitUntilIdle())
        await runtime.waitForVoice()
    }

    /// The controller `/voice on` created last.
    private static func controller(_ controllers: ZenTestVoiceControllers) async throws -> ZenTestVoiceController {
        try #require(controllers.latest)
    }

    /// A window ready for its first line.
    private static func open(_ runtime: ZenAppRuntime, _ workspace: URL) async throws -> ZenWindowSession {
        let window = try await runtime.openWindow(workspace: workspace)
        await waitUntil("the window shows its session") { window.snapshot != nil }
        #expect(await window.waitUntilIdle())
        return window
    }

    /// The room of the window's session, observed once one prompt ran (so
    /// the backend exists).
    private static func room(of window: ZenWindowSession, _ runtime: ZenAppRuntime) async throws -> String {
        window.draft = "Hello"
        window.submitDraft()
        #expect(await window.waitUntilIdle())
        await waitUntil("the room is observed") { window.sharedChatObservation.observation != nil }
        return try #require(await runtime.sessionHost.incarnation(in: window.slotID)?.sessionID)
    }

    /// The Planner of a `/plan` turn of the root session `root`, done, with
    /// `output` as its response.
    private static func planner(output: String, root: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "planner-1",
            rootSessionID: root,
            name: "plan-author",
            role: AgentProfileRole.planner.title,
            profileRole: .planner,
            status: .idle,
            pending: false,
            latestOutput: output,
            latestOutputRevision: 1,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// A short real sleep between two reads of an adopted turn's reservation.
    private static let quickSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .milliseconds(5))
    }

    /// Reserves the slot's prompt, as a turn from Telegram does.
    @ChatSessionActor
    private static func reservePrompt(in sessionHost: ChatSessionHost, slotID: ChatSlotID) throws -> ChatPromptReservation {
        try sessionHost.reservePrompt(in: slotID)
    }

    /// Releases the prompt, as the channel does when its turn ends.
    @ChatSessionActor
    private static func releasePrompt(_ reservation: ChatPromptReservation, in sessionHost: ChatSessionHost) {
        sessionHost.releasePrompt(reservation)
    }

    /// Makes the voice context wait at `gate` before the requests `matches`
    /// selects; `nil` lets every request through.
    @ChatSessionActor
    private static func hold(
        _ voice: ZenAppVoice,
        at gate: ZenGate?,
        when matches: @escaping @Sendable (ZenVoiceRequest) -> Bool
    ) {
        guard let gate else {
            voice.requestWillHandle = nil
            return
        }
        voice.requestWillHandle = { request in
            if matches(request) {
                await gate.pass()
            }
        }
    }

    private nonisolated static let model = AgentSettingsModelManifest(
        id: "zen-app-model",
        kind: .remoteAPI,
        modelID: "local/zen-app-model"
    )

    /// A runtime over the scripted backend and the test voice controllers,
    /// a hosted configuration, and a temporary support directory and
    /// workspace.
    private func withVoice(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, ZenTestVoiceControllers, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-voice-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await Self.compose(workspace: workspace, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, ZenTestVoiceControllers, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: model.id,
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [model],
            workingDirectory: workspace,
            appMode: true
        )
        let backend = ZenScriptedBackend()
        let controllers = ZenTestVoiceControllers()
        let runtime = await ZenAppRuntime(
            configuration: configuration,
            featureRuntime: nil,
            userHomeDirectoryURL: nil,
            backendFactory: { _, _ in backend },
            voiceSession: controllers.session,
            openExternal: { _ in }
        )
        do {
            try await body(runtime, backend, controllers, workspace)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}
