//
//  ZenVoiceWindowTests+CommandAndActiveWindow.swift
//  ZenAppSessionTests
//
//  Tests of /voice in the app over a scripted backend and a test voice
//  controller: the command texts, the app-wide state, and the switch,
//  routing, and close of the active window.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

extension ZenVoiceWindowTests {
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

    @Test("A window Telegram drives refuses dictation, a dictated command, and a live message by voice, with the dormant text; the dictation goes back to the draft")
    func dormantWindowRefusesVoiceInput() async throws {
        try await withVoice { runtime, backend, controllers, workspace in
            let window = try await Self.open(runtime, workspace)
            try await Self.run("/voice on", in: window, runtime)
            let controller = try await Self.controller(controllers)
            window.isDrivenFromTelegram = true

            // A live message by voice is refused by the session's admission,
            // which never sees its text: unlike a dictated line or prompt it
            // does not go back to the draft (a known limit, out of scope).
            let steps: [(utterance: String, draft: String)] = [
                ("che ore sono?", "che ore sono?"),
                ("/exit", "/exit"),
                ("message to the coordinator: stop", ""),
            ]
            for (utterance, draft) in steps {
                // The voice send takes the whole draft: clear what the last
                // refusal put back, or it would go out with this utterance.
                window.draft = ""
                let refusals = window.transcript.filter { $0.content == Self.dormantRefusal }.count
                await controller.send(utterance)
                await runtime.waitForVoice()
                await waitUntil("\(utterance) is refused") {
                    window.transcript.filter { $0.content == Self.dormantRefusal }.count == refusals + 1
                }
                #expect(window.draft == draft)
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
            // No instruction goes out before the controller listens.
            await waitUntil("voice mode listens") { runtime.voiceState == VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false) }

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
            #expect(first.voiceDictation.preview != nil)
            let interruptions = await controller.interruptions

            runtime.windowDidBecomeActive(second)
            await runtime.waitForVoice()
            await waitUntil("voice follows the second window") { second.isVoiceWindow }
            // The old window keeps the words as ordinary text; voice forgets them.
            #expect(first.draft == "Nota: ciao")
            #expect(first.voiceDictation.preview == nil)
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
            #expect(first.voiceDictation.preview == nil)
            #expect(second.voiceDictation.preview == nil)

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
            #expect(first.voiceDictation.preview == nil)
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
            #expect(first.voiceDictation.preview == nil)

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
}
