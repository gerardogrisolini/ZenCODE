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

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct ZenVoiceWindowTests {
    static let instruction = "Voice mode is on: the user is listening and your final answer is read aloud. Answer in short sentences. While you work, briefly comment on what you are doing as you do it. Keep any format the request requires."
    static let dormantRefusal = ZenTranscriptItem.Content.local(
        text: "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.",
        isFailure: true
    )
    static let agentID = "agent-1"
    static let agentName = "Reviewer"

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
            #expect(window.voiceDictation.preview != nil)

            // An edit turns the dictation into text; voice forgets it.
            window.draft = "Nota: ciao mondo!"
            #expect(window.voiceDictation.preview == nil)
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
            #expect(window.voiceDictation.preview == nil)
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

    @Test("A full queue refuses a dictated plain prompt with the voice text, and a dictated line with the typed one; each goes back to the draft")
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
            #expect(window.draft.isEmpty)

            await controller.send("/plain")
            await waitUntil("the plain prompt is refused") {
                Self.lastRow(of: window) == .local(text: ZenWindowSession.voiceQueueFullMessage, isFailure: true)
            }
            #expect(ZenWindowSession.voiceQueueFullMessage == "ZenCODE: prompt queue is full; voice prompt was not queued.")
            #expect(window.draft == "/plain")
            // The voice send takes the whole draft: clear the restored prompt,
            // or it would go out with the next utterance.
            window.draft = ""
            await controller.send("dictated line")
            await waitUntil("the line is refused") {
                Self.lastRow(of: window) == .local(text: ZenWindowSession.queueFullMessage, isFailure: true)
            }
            #expect(window.draft == "dictated line")
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
            let call = DirectAgentToolCall(id: "read-1", name: "local.read", argumentsObject: [:], argumentsJSON: "{}")
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
            let call = DirectAgentToolCall(id: "read-1", name: "local.read", argumentsObject: [:], argumentsJSON: "{}")

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
            await waitUntil("voice mode listens") { window.voiceState == VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false) }
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
    static func lastRow(of window: ZenWindowSession) -> ZenTranscriptItem.Content? {
        window.transcript.last?.content
    }

    /// Runs `line` as typed and waits until the window and voice mode are
    /// done with it.
    static func run(_ line: String, in window: ZenWindowSession, _ runtime: ZenAppRuntime) async throws {
        window.draft = line
        window.submitDraft()
        #expect(await window.waitUntilIdle())
        await runtime.waitForVoice()
    }

    /// The controller `/voice on` created last.
    static func controller(_ controllers: ZenTestVoiceControllers) async throws -> ZenTestVoiceController {
        try #require(controllers.latest)
    }

    /// A window ready for its first line.
    static func open(_ runtime: ZenAppRuntime, _ workspace: URL) async throws -> ZenWindowSession {
        let window = try await runtime.openWindow(workspace: workspace)
        await waitUntil("the window shows its session") { window.snapshot != nil }
        #expect(await window.waitUntilIdle())
        return window
    }

    /// The room of the window's session, observed once one prompt ran (so
    /// the backend exists).
    static func room(of window: ZenWindowSession, _ runtime: ZenAppRuntime) async throws -> String {
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

    private nonisolated static let model = AgentSettingsModelManifest(
        id: "zen-app-model",
        kind: .remoteAPI,
        modelID: "local/zen-app-model"
    )

    /// A runtime over the scripted backend and the test voice controllers,
    /// a hosted configuration, and a temporary support directory and
    /// workspace.
    func withVoice(
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
