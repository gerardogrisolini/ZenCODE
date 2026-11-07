//
//  ACPTelegramChannelTests.swift
//  ZenCODE
//
//  An ACP session whose slot is handed to Telegram with `/telegram on`,
//  through a scripted Bot API: the turns the linked chat starts run with the
//  editor's composition and end up in the history `session/load` replays,
//  their consent is decided in the chat, `/status` is answered there, the
//  editor's `session/cancel` stops them (a prompt the editor sends meanwhile
//  keeps its reservation) and the next `/telegram off` catches up with them,
//  they run in the environment of the editor's own prompts (the client's text
//  file system, the agent's skills) and are refused once the session closed
//  or while its close drains, a busy session names the turn from Telegram,
//  the notices of the attach follow the activation text in the reply of
//  `/telegram on`, and the controller's task-graph observer runs while
//  Telegram drives the slot, quiesces at the end of every turn from the
//  chat, and stops with `/telegram off` and the bridge's shutdown. Nothing
//  reaches the network; every test runs in a UUID support directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ACPTelegramChannelTests {
    private static let activationReply = "Telegram remote control is active.\nLinked chat: Test"

    /// A turn from the linked chat runs with the editor's composition (the
    /// session's configuration plus the purpose's tools, the same write the
    /// editor's prompt made), presents nothing on the ACP wire, and is in the
    /// history the runner keeps, so `/telegram off` catches up with it and
    /// `session/load` replays it next to the editor's turns.
    @Test
    func telegramTurnsRunWithTheEditorsCompositionAndSessionLoadReplaysThem() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root, editorPromptsFirst: true)
            let backend = fixture.backend
            let editorWrite = try #require(await backend.sessionWrites.last)
            let wireCountBeforeTelegram = fixture.wire.count
            let sentBefore = await fixture.transport.sentMessages.count

            try await fixture.transport.deliver("Hello from Telegram")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            #expect(await backend.prompts == ["Hello from the editor", "Hello from Telegram"])
            // The same composition as the editor's prompt.
            #expect(await backend.sessionWrites.count > 1)
            #expect(await backend.sessionWrites.last == editorWrite)
            #expect(editorWrite.systemPrompt == "ACP Telegram test")
            // Nothing of the turn reached the editor.
            #expect(fixture.wire.count == wireCountBeforeTelegram)
            #expect(fixture.wire.permissionRequestIDs.isEmpty)

            // The way back: the stop text, then what the editor did not see.
            let offStart = fixture.wire.count
            await fixture.prompt("/telegram off", id: 3, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: 3) == "end_turn")
            #expect(fixture.lastAgentText(from: offStart) == """
                Telegram remote control stopped.
                Catch-up from Telegram:
                You: Hello from Telegram
                ZenCODE: reply
                """)

            // `session/load` of the live session replays the runner's history,
            // the turn from Telegram included, in order.
            let loadStart = fixture.wire.count
            await fixture.loadSession(sessionID: sessionID, id: 4)
            #expect(fixture.wire.response(id: 4)?["result"] != nil)
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk", from: loadStart)
                == ["Hello from the editor", "Hello from Telegram"])
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: loadStart)
                == ["reply", "reply"])
            await fixture.bridge.shutdown()
        }
    }

    /// A gated tool of a turn from the chat is asked in the chat only, where
    /// `/allow ID` decides it; the editor is asked nothing. The remote
    /// `/status` is answered in the chat too, without a turn.
    @Test
    func aTelegramTurnsConsentIsDecidedWithAllowInTheChatAndStatusIsAnsweredThere() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            let wireCount = fixture.wire.count

            let status = await channel.remoteStatusText()
            let statusBefore = await fixture.transport.sentMessages.count
            try await fixture.transport.deliver("/status")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentMessages.count > statusBefore
            })
            #expect(await fixture.transport.sentTexts.dropFirst(statusBefore) == [status])
            #expect(status.hasPrefix("Session active."))
            #expect(await fixture.backend.prompts.isEmpty)

            await fixture.backend.enqueue([.askPermission(command: "echo hi"), .reply("ran")])
            try await fixture.transport.deliver("Run echo hi")
            guard let requestID = await fixture.pendingTelegramPermissionRequestID() else {
                await fixture.bridge.shutdown()
                return
            }
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            try await fixture.transport.deliver("/allow \(requestID)")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await fixture.backend.permissionDecisions == [true])
            #expect(await fixture.transport.sentTexts.contains(
                "✅ Permission \(requestID) allowed once. Continuing."
            ))
            #expect(fixture.wire.count == wireCount)
            #expect(fixture.wire.errorResponses.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    /// The editor cannot take the slot back in the middle of a turn from
    /// Telegram: `/telegram off`, like every prompt, is refused with the text
    /// that names the turn, while the plain busy text of before stays for the
    /// editor's own prompt. `session/cancel` stops the turn (its pending
    /// consent closes, the chat sees `Stopped.`), and the next `/telegram
    /// off` catches up with the prompt and the text streamed so far.
    @Test
    func cancelStopsATelegramTurnAndTheNextTelegramOffCatchesUpWithIt() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            await fixture.backend.enqueue([
                .reply("Working "),
                .askPermission(command: "rm -rf build"),
                .reply("done"),
            ])

            try await fixture.transport.deliver("Clean the build")
            guard await fixture.pendingTelegramPermissionRequestID() != nil else {
                await fixture.bridge.shutdown()
                return
            }

            // Refused, naming the turn from Telegram.
            let busyStart = fixture.wire.count
            await fixture.prompt("/telegram off", id: 3, sessionID: sessionID)
            #expect(fixture.wire.errorMessage(id: 3) == ZenCODEACPBridge.telegramTurnBusyMessage)
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk", from: busyStart).isEmpty)
            await fixture.prompt("Hello?", id: 4, sessionID: sessionID)
            #expect(fixture.wire.errorMessage(id: 4) == ZenCODEACPBridge.telegramTurnBusyMessage)
            #expect(await fixture.backend.prompts == ["Clean the build"])

            // Stopped from the editor.
            let stoppedBefore = await fixture.transport.sentMessages.count
            await fixture.cancel(sessionID: sessionID, id: 5)
            #expect(fixture.wire.response(id: 5)?["result"] != nil)
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(stoppedBefore).contains("Stopped.")
            })
            #expect(await fixture.backend.permissionDecisions == [false])
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.bridge.telegramTestPromptIsReserved(sessionID: sessionID) == false
            })

            // Taken back, with the prompt and the text streamed so far.
            let offStart = fixture.wire.count
            await fixture.prompt("/telegram off", id: 6, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: 6) == "end_turn")
            #expect(fixture.lastAgentText(from: offStart) == """
                Telegram remote control stopped.
                Catch-up from Telegram:
                You: Clean the build
                ZenCODE: Working
                """)
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    /// Outside Telegram the busy text is the one of before: a second
    /// `session/prompt` while the editor's own turn runs is refused with it.
    @Test
    func aSecondEditorPromptKeepsThePlainBusyText() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let sessionID = "acp-telegram-busy-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [sessionID],
                transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            )
            await fixture.backend.enqueue([.reply("Half "), .pause, .reply("done")])
            let turn = Task { await fixture.prompt("Long one", id: 1, sessionID: sessionID) }
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.backend.isPaused })

            await fixture.prompt("Another", id: 2, sessionID: sessionID)
            #expect(fixture.wire.errorMessage(id: 2) == "A prompt is already running for this session.")

            await fixture.backend.release()
            await fixture.finish(turn, id: 1)
            #expect(fixture.wire.stopReason(id: 1) == "end_turn")
            await fixture.bridge.shutdown()
        }
    }

    /// A turn from the linked chat runs inside the text file system the
    /// editor serves, for as long as the session lives, as the editor's own
    /// prompt does: what the turn reads is the editor's buffer, what it
    /// writes goes to the buffer and never past it to the disk. The editor's
    /// next prompt, after `/telegram off`, sees the same environment.
    @Test
    func aTelegramTurnRunsInsideTheEditorsClientFileSystem() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let notes = root.appendingPathComponent("workspace/Notes.txt")
            let editor = ACPTelegramClientFiles(buffers: [notes: "unsaved editor text"])
            let (fixture, sessionID) = try await Self.linkedFixture(root: root, clientFiles: editor)
            let sentBefore = await fixture.transport.sentMessages.count
            await fixture.backend.enqueue([
                .readClientFile(path: "Notes.txt"),
                .writeClientFile(path: "Notes.txt", contents: "written by the turn from Telegram"),
                .reply("done"),
            ])

            try await fixture.transport.deliver("Update the notes")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            let telegramAccesses = await fixture.backend.clientFileAccesses
            #expect(telegramAccesses == [
                .init(hadClientFileSystem: true, readContents: "unsaved editor text"),
                .init(hadClientFileSystem: true, readContents: nil),
            ])
            // The editor's buffer took the write; the disk never saw the file.
            #expect(editor.buffer(at: notes) == "written by the turn from Telegram")
            #expect(editor.writtenPaths == [notes.standardizedFileURL.path])
            #expect(editor.requestedSessionIDs == [sessionID])
            #expect(!FileManager.default.fileExists(atPath: notes.path))

            // The editor's own prompt reads the same through the same access.
            await fixture.prompt("/telegram off", id: 3, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: 3) == "end_turn")
            await fixture.backend.enqueue([.readClientFile(path: "Notes.txt")])
            await fixture.prompt("Read the notes", id: 4, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: 4) == "end_turn")
            let accesses = await fixture.backend.clientFileAccesses
            #expect(accesses.count == 3)
            #expect(accesses.last == .init(
                hadClientFileSystem: true, readContents: "written by the turn from Telegram"
            ))
            #expect(!FileManager.default.fileExists(atPath: notes.path))
            await fixture.bridge.shutdown()
        }
    }

    /// A client that serves no text file system leaves a turn from Telegram
    /// on the disk, as it leaves the editor's prompts: the turn is not given
    /// an access that is not there.
    @Test
    func aTelegramTurnWithoutAClientFileSystemUsesTheDisk() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, _) = try await Self.linkedFixture(root: root)
            let sentBefore = await fixture.transport.sentMessages.count
            let notes = fixture.workingDirectory.appendingPathComponent("Notes.txt")
            await fixture.backend.enqueue([
                .writeClientFile(path: "Notes.txt", contents: "on the disk"),
                .readClientFile(path: "Notes.txt"),
            ])

            try await fixture.transport.deliver("Write the notes")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            #expect(await fixture.backend.clientFileAccesses == [
                .init(hadClientFileSystem: false, readContents: nil),
                .init(hadClientFileSystem: false, readContents: "on the disk"),
            ])
            #expect(try String(contentsOf: notes, encoding: .utf8) == "on the disk")
            await fixture.bridge.shutdown()
        }
    }

    /// A turn from the linked chat selects the skills of the session's agent
    /// before it runs, with the same derivation as the editor's prompt
    /// (`selectedAgentSkills(for:)`), so the agent's skills are there for a
    /// session the editor has not prompted yet.
    @Test
    func aTelegramTurnSelectsTheAgentsSkillsAsTheEditorsPromptDoes() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let skillDirectory = root.appendingPathComponent("skills/release-notes", isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try """
            ---
            name: Release Notes
            description: Writes the release notes.
            ---

            # Release Notes

            Summarize the changes since the last tag.
            """
            .write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let skill = try #require(PromptSkillCatalog.discoverSkills(
                searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
            ).first)
            let agent = AgentProfile(
                id: "skilled",
                name: "Skilled",
                role: .developer,
                skills: [AgentProfileSkill(id: skill.id, canonicalName: skill.canonicalName)]
            )
            let (fixture, sessionID) = try await Self.linkedFixture(root: root, selectedAgent: agent)
            let runner = await fixture.bridge.sessionRunner
            // Nothing is selected before the turn: no editor prompt ran.
            let initialSelection = await runner.promptSkillProvidersBySessionID[sessionID]?.currentSkills()
            #expect(initialSelection?.isEmpty ?? true)
            let sentBefore = await fixture.transport.sentMessages.count

            try await fixture.transport.deliver("Write the release notes")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            let selected = try #require(await runner.promptSkillProvidersBySessionID[sessionID]?.currentSkills())
            #expect(selected.map(\.id) == [skill.id])
            #expect(selected == (await fixture.bridge.selectedAgentSkills(for: agent)))
            await fixture.bridge.shutdown()
        }
    }

    /// A turn the slot's hooks wrap runs inside the client's file system while
    /// the session lives; once the session closed, the controller it was
    /// started on is no longer one the bridge runs, and the hooks refuse the
    /// turn: its composition and its environment throw `sessionNotRunning`,
    /// and its body never runs. Without the session's configuration and
    /// environment the turn would run without the editor's grant, the
    /// client's file system, and the agent's skills, so it does not run at
    /// all.
    @Test
    func aTurnOnAClosedSessionIsRefusedWithoutRunningItsBody() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let notes = root.appendingPathComponent("workspace/Notes.txt")
            let editor = ACPTelegramClientFiles(buffers: [notes: "unsaved editor text"])
            let (fixture, sessionID) = try await Self.linkedFixture(root: root, clientFiles: editor)
            let controller = try #require(await fixture.bridge.telegramTestController(sessionID: sessionID))
            let hooks = await fixture.bridge.slotChannelHooks
            let result = ChatTurnResult(
                response: DirectAgentResponse(text: "ran", stopReason: "end_turn", modelID: "test-model"),
                finalAssistantBlock: nil,
                fileChangeSummary: nil,
                automaticallyCompletedPlan: nil
            )
            let bodies = ACPTelegramBodyRecorder()

            let liveConfiguration = try await hooks.turnSessionConfiguration(for: .normal, controller: controller)
            #expect(liveConfiguration.systemPrompt == "ACP Telegram test")
            let live = try await hooks.runTurnFromAnotherChannel(controller: controller) {
                bodies.record(hadClientFileSystem: ClientTextFileSystem.current != nil)
                return result
            }
            #expect(live.response.text == "ran")
            #expect(bodies.recorded == [true])

            await fixture.bridge.handleMessage([
                "jsonrpc": "2.0", "id": 9, "method": "session/close",
                "params": ["sessionId": sessionID],
            ])
            #expect(fixture.wire.response(id: 9)?["result"] == .object([:]))
            #expect(await fixture.bridge.telegramTestController(sessionID: sessionID) == nil)

            await #expect(throws: ACPTelegramTurnRefusal.sessionNotRunning) {
                try await hooks.turnSessionConfiguration(for: .normal, controller: controller)
            }
            await #expect(throws: ACPTelegramTurnRefusal.sessionNotRunning) {
                try await hooks.runTurnFromAnotherChannel(controller: controller) {
                    bodies.record(hadClientFileSystem: ClientTextFileSystem.current != nil)
                    return result
                }
            }
            #expect(bodies.recorded == [true])
            await fixture.bridge.shutdown()
        }
    }

    /// A message the linked chat sends while the editor's `session/close`
    /// waits for the session's prompt handlers to drain starts no turn: the
    /// close retired the incarnation in the host before its first
    /// suspension, so the turn from Telegram is refused before anything is
    /// reserved, and nothing reaches the backend or the wire. The close then
    /// answers as before.
    @Test
    func aTelegramMessageWhileTheCloseDrainsStartsNoTurn() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            let slotID = try #require(await fixture.bridge.telegramTestSlotID(sessionID: sessionID))
            let host = await fixture.bridge.host
            let wireCount = fixture.wire.count
            // A prompt handler of the session still unwinding keeps the close
            // in its drain.
            let handler = await fixture.bridge.enterPromptHandler(sessionID: sessionID)
            let close = Task {
                await fixture.bridge.handleMessage([
                    "jsonrpc": "2.0", "id": 9, "method": "session/close",
                    "params": ["sessionId": sessionID],
                ])
            }
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.bridge.telegramTestController(sessionID: sessionID) == nil
            })
            // Retired: the slot, still open, takes no reservation.
            #expect(await host.incarnation(in: slotID) != nil)
            await #expect(throws: ChatSessionHostError.noSession) {
                try await host.reservePrompt(in: slotID)
            }

            let sentBefore = await fixture.transport.sentMessages.count
            try await fixture.transport.deliver("Hello while closing")
            try await fixture.transport.deliver("/status")
            // The chat's lines are read in order: `/status` is answered after
            // the first line was admitted, and the task of that line ends.
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.hasPrefix("Session") }
            })
            #expect(await ACPTelegramTestSupport.waitUntil {
                await channel.telegramTestIsIdle
            })
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(await !fixture.transport.sentTexts.contains { $0.contains("ZenCODE completed") })
            #expect(fixture.wire.response(id: 9) == nil)

            await fixture.bridge.leavePromptHandler(sessionID: sessionID, token: handler)
            await close.value
            #expect(fixture.wire.response(id: 9)?["result"] == .object([:]))
            #expect(fixture.wire.count == wireCount + 1)
            #expect(await fixture.backend.prompts.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    /// An editor's `session/cancel` of a turn from Telegram and its next
    /// `session/prompt` (`/telegram off`), started together: the prompt is
    /// reserved after the cancel dropped the turn's reservation and before the
    /// cancel stops the turn in the channel. The stop leaves the prompt's
    /// reservation and the runner alone, so the prompt answers as usual, not
    /// `cancelled`, and the turn from Telegram, paused in the backend, stops.
    @Test
    func aPromptReservedWhileTheCancelStopsATelegramTurnAnswersAsUsual() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            await fixture.backend.enqueue([.reply("Working "), .pause, .reply("done")])
            try await fixture.transport.deliver("Clean the build")
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.backend.isPaused })
            #expect(await fixture.bridge.telegramTestTurnHoldsReservation(sessionID: sessionID))

            let start = fixture.wire.count
            let handlers = await fixture.bridge.telegramTestCancelThenPrompt(
                sessionID: sessionID, cancelID: 5, promptID: 6, text: "/telegram off"
            )
            for handler in handlers {
                await handler.value
            }
            #expect(fixture.wire.response(id: 5)?["result"] == .object([:]))
            #expect(fixture.wire.errorMessage(id: 6) == nil)
            #expect(fixture.wire.stopReason(id: 6) == "end_turn")
            #expect(fixture.lastAgentText(from: start)?.hasPrefix("Telegram remote control stopped.") == true)
            #expect(await fixture.bridge.telegramTestPromptIsReserved(sessionID: sessionID) == false)
            // The turn from Telegram stopped: its task was cancelled, so once
            // the backend lets it go on it ends there, cancelled, without
            // completing (a completed turn would be in the backend's history).
            #expect(await fixture.bridge.telegramTestTurnHoldsReservation(sessionID: sessionID))
            await fixture.backend.release()
            #expect(await ACPTelegramTestSupport.waitUntil {
                await !fixture.bridge.telegramTestTurnHoldsReservation(sessionID: sessionID)
            })
            #expect(await fixture.backend.prompts == ["Clean the build"])
            let history = await fixture.backend.snapshotSession(id: sessionID)?.history ?? []
            #expect(!history.contains { $0.content.contains("done") })
            await fixture.bridge.shutdown()
        }
    }

    /// The notices the channel presents while `/telegram on` attaches it
    /// follow the activation text in the reply: a topic the Bot API refuses
    /// to create is reported there, as the terminal reports it after the
    /// activation text, instead of being dropped. A later `/telegram on`
    /// reports only what its own attach presents.
    @Test
    func telegramOnAppendsTheTopicFailureAfterTheActivationText() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let transport = ACPTelegramScriptedTransport(
                botID: ACPTelegramTestSupport.uniqueBotID(),
                hasTopicsEnabled: true,
                createdTopicIDs: []
            )
            let sessionID = "acp-telegram-topic-failure-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [sessionID], transport: transport
            )

            let reply = await fixture.turnTelegramOn(sessionID: sessionID, id: 1)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            #expect(await channel.isActive)
            #expect(await channel.drivesSlot)
            #expect(await channel.sessionTopic == nil)
            #expect(await channel.noticeSink == nil)
            let lastError = try #require(await channel.controlState.lastError)
            #expect(reply == "\(Self.activationReply)\nZenCODE: \(lastError)")
            #expect(await fixture.backend.prompts.isEmpty)

            let offStart = fixture.wire.count
            await fixture.prompt("/telegram off", id: 2, sessionID: sessionID)
            #expect(fixture.lastAgentText(from: offStart) == "Telegram remote control stopped.")
            let again = try #require(await fixture.turnTelegramOn(sessionID: sessionID, id: 3))
            #expect(again.components(separatedBy: "\n").filter { $0.hasPrefix("ZenCODE: ") }.count == 1)
            #expect(!again.contains("Telegram remote control stopped."))
            await fixture.bridge.shutdown()
        }
    }

    /// `/telegram on` is a prompt of its own, so no turn of the editor is
    /// ever open when the slot changes hands: the slot's presenter has no
    /// turn to move, and the reducer the handover creates starts from the
    /// runner's history, the editor's turns included.
    @Test
    func noEditorTurnIsOpenWhenTheSlotIsHandedOver() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root, editorPromptsFirst: true)
            let state = try #require(await fixture.bridge.telegramTestSlotState(sessionID: sessionID))
            #expect(!state.turnIsOpen)
            #expect(state.movedTurn == nil)
            #expect(state.transcript == ["user: Hello from the editor", "assistant: reply"])
            // The chat received the editor's turns as context.
            let context = try #require(await fixture.transport.sentTexts.first { $0.contains("messages of the session") })
            #expect(context.contains("👤 Hello from the editor"))
            #expect(context.contains("🤖 reply"))
            await fixture.bridge.shutdown()
        }
    }

    /// While Telegram drives an ACP session's slot, the channel runs the
    /// controller's task-graph observer: a change of the graph during a turn
    /// from the chat reaches the chat as the progress card, and nothing of it
    /// the editor; a change outside a turn sends nothing. `/telegram off`
    /// stops the observer: none is left, and a later change sends nothing.
    ///
    /// Every negative check waits on a barrier, never on a fixed delay: the
    /// observer's debounce is a gate the test opens, and the publication it
    /// schedules is awaited; once the observer is stopped, nothing is left
    /// that could publish.
    @Test
    func theTaskGraphOfAnACPSessionReachesTheChatOnlyWhileTelegramDrivesIt() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            let controller = try #require(await fixture.bridge.telegramTestController(sessionID: sessionID))
            await Self.awaitTaskGraphObservationWork(of: channel)
            #expect(await Self.observesTheTaskGraph(channel, controller))
            let gate = DebounceGate()
            await Self.setTaskGraphDebounce(of: controller, to: gate)
            let wireCount = fixture.wire.count

            // Outside a turn there is no audience.
            let sentBefore = await fixture.transport.sentMessages.count
            try await Self.createTaskGraph(on: controller)
            await Self.publishTheNextTaskGraphChange(of: controller, gate: gate, entries: 1)
            #expect(await fixture.transport.sentMessages.count == sentBefore)

            await fixture.backend.enqueue([.pause, .reply("planned")])
            try await fixture.transport.deliver("Plan the work")
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.backend.isPaused })
            try await Self.claimTask("first", on: controller)
            await Self.publishTheNextTaskGraphChange(of: controller, gate: gate, entries: 2)
            let card = await fixture.transport.waitForSentMessage { $0.text.hasPrefix("📋 Task graph") }
            #expect(card?.text.contains("Task first") == true)
            await fixture.backend.release()
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            #expect(fixture.wire.count == wireCount)

            await fixture.prompt("/telegram off", id: 3, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: 3) == "end_turn")
            #expect(await Self.observesNoTaskGraph(channel, controller))
            let sentAfterOff = await fixture.transport.sentMessages.count
            try await Self.claimTask("second", on: controller)
            // No observer is subscribed and no publication is pending: the
            // change has nothing left to publish it.
            #expect(await Self.observesNoTaskGraph(channel, controller))
            #expect(await Self.hasNoPendingTaskGraphPublication(controller))
            #expect(await fixture.transport.sentMessages.count == sentAfterOff)
            await fixture.bridge.shutdown()
        }
    }

    /// On an ACP session's slot the channel quiesces the observer at the end
    /// of every turn it presents, as the terminal does: a change of the graph
    /// whose debounced publication still waits when the turn ends is
    /// published in that turn, before its outcome, with the graph's final
    /// state; the prompt queued meanwhile starts at once, and its turn
    /// receives nothing born of the previous turn's change, even once the
    /// debounce would have elapsed, until its own boundary publishes the
    /// latest graph once more. The observer runs again afterwards.
    @Test
    func theTaskGraphOfAnACPSessionIsPublishedInTheTurnThatChangedIt() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            let controller = try #require(await fixture.bridge.telegramTestController(sessionID: sessionID))
            await Self.awaitTaskGraphObservationWork(of: channel)
            #expect(await Self.observesTheTaskGraph(channel, controller))
            let gate = DebounceGate()
            await Self.setTaskGraphDebounce(of: controller, to: gate)
            try await Self.createTaskGraph(on: controller)
            await Self.publishTheNextTaskGraphChange(of: controller, gate: gate, entries: 1)
            let sentBefore = await fixture.transport.sentMessages.count

            await fixture.backend.enqueue([.pause, .reply("first turn")])
            await fixture.backend.enqueue([.pause, .reply("second turn")])
            try await fixture.transport.deliver("Plan the work")
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.backend.isPaused })
            // A prompt the chat queued, which starts as soon as the session
            // is free.
            #expect(try await Self.queuePrompt("Then go on", on: channel))
            #expect(await Self.queuedPromptCount(channel) == 1)

            // A change whose debounced publication still waits as the turn
            // ends.
            try await Self.claimTask("first", on: controller)
            await gate.waitForEntries(2)
            await fixture.backend.release()
            // The queued prompt starts at once, and its turn pauses.
            #expect(await ACPTelegramTestSupport.waitUntil {
                let prompts = await fixture.backend.prompts.count
                let paused = await fixture.backend.isPaused
                return prompts == 2 && paused
            })
            let expectedCard = try await Self.taskGraphCardText(of: controller)

            // The debounce elapses during the second turn.
            await gate.open()
            await Self.drainPendingTaskGraphPublication(of: controller)
            await Self.flushTurnReporter(of: channel)
            let sentDuringSecondTurn = await fixture.transport.sentMessages.count
            await fixture.backend.release()
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore)
                    .filter { $0.contains("ZenCODE completed") }.count == 2
            })

            let texts = Array(await fixture.transport.sentTexts.dropFirst(sentBefore))
            let secondTurnSoFar = sentDuringSecondTurn - sentBefore
            let firstOutcome = try #require(texts.firstIndex { $0.contains("ZenCODE completed") && $0.contains("first turn") })
            let secondOutcome = try #require(texts.firstIndex { $0.contains("ZenCODE completed") && $0.contains("second turn") })
            let cards = texts.indices.filter { texts[$0].hasPrefix("📋 Task graph") }
            #expect(firstOutcome < secondTurnSoFar && secondTurnSoFar <= secondOutcome)
            // The first turn's card, with the graph's final state, before
            // its outcome.
            let firstTurnCards = cards.filter { $0 < firstOutcome }
            #expect(firstTurnCards.count == 1, "\(texts)")
            #expect(firstTurnCards.first.map { texts[$0] } == expectedCard)
            // Nothing of it in the second turn, even once its debounce
            // elapsed; the second turn's own boundary publishes the graph
            // once more, before its outcome, as every turn boundary does.
            #expect(!cards.contains { firstOutcome < $0 && $0 < secondTurnSoFar }, "\(texts)")
            #expect(cards.filter { $0 > firstOutcome }.allSatisfy { $0 >= secondTurnSoFar && $0 < secondOutcome })
            // The second turn's boundary restarts the observer before its
            // task ends.
            await Self.awaitTurnTasks(of: channel)
            await Self.awaitTaskGraphObservationWork(of: channel)
            #expect(await Self.observesTheTaskGraph(channel, controller))
            await fixture.bridge.shutdown()
        }
    }

    /// Shutting the bridge down while Telegram drives a slot and runs its
    /// task-graph observer leaves no observer behind.
    @Test
    func theBridgeShutdownLeavesNoTaskGraphObserver() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedFixture(root: root)
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            let controller = try #require(await fixture.bridge.telegramTestController(sessionID: sessionID))
            await Self.awaitTaskGraphObservationWork(of: channel)
            #expect(await Self.observesTheTaskGraph(channel, controller))

            await fixture.bridge.shutdown()
            #expect(await Self.observesNoTaskGraph(channel, controller))
            #expect(await !channel.observesTaskGraph)
            #expect(await Self.hasNoPendingTaskGraphPublication(controller))
        }
    }

    // MARK: - Support

    /// Whether `channel` runs `controller`'s task-graph observer.
    @ChatSessionActor
    private static func observesTheTaskGraph(
        _ channel: TelegramChannel, _ controller: ChatSessionController
    ) -> Bool {
        channel.runsTaskGraphObserver
            && channel.taskGraphObservedController === controller
            && controller.taskGraphObserverTask != nil
    }

    /// Waits for the work `channel` queued on its task-graph observer (the
    /// binding `/telegram on` queued synchronously, a quiescence, a
    /// restart): its latest task awaits every earlier one.
    @ChatSessionActor
    private static func awaitTaskGraphObservationWork(of channel: TelegramChannel) async {
        await channel.taskGraphObservationTask?.value
    }

    /// Waits until no task of `channel` runs: the turns from the chat, with
    /// their boundaries, and the queued prompts they start.
    @ChatSessionActor
    private static func awaitTurnTasks(of channel: TelegramChannel) async {
        while let task = channel.activeTurnTask {
            await task.value
        }
    }

    /// Whether neither `channel` nor `controller` keeps a task-graph observer.
    @ChatSessionActor
    private static func observesNoTaskGraph(
        _ channel: TelegramChannel, _ controller: ChatSessionController
    ) -> Bool {
        channel.taskGraphObservationTask == nil
            && channel.taskGraphObservedController == nil
            && controller.taskGraphObserverTask == nil
    }

    /// Whether `controller`'s observer has no debounced publication waiting.
    @ChatSessionActor
    private static func hasNoPendingTaskGraphPublication(_ controller: ChatSessionController) -> Bool {
        controller.taskGraphObserver.pendingPublication == nil
    }

    /// Makes `gate` the debounce of `controller`'s task-graph observer, which
    /// reads it at every graph event.
    @ChatSessionActor
    private static func setTaskGraphDebounce(of controller: ChatSessionController, to gate: DebounceGate) {
        controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
    }

    /// Lets the publication of the graph change the observer received as
    /// its `entries`-th event through the debounce, and waits until it
    /// published.
    @ChatSessionActor
    private static func publishTheNextTaskGraphChange(
        of controller: ChatSessionController, gate: DebounceGate, entries: Int
    ) async {
        await gate.waitForEntries(entries)
        await gate.open()
        await drainPendingTaskGraphPublication(of: controller)
    }

    /// Waits for the debounced publication of `controller`'s observer, if
    /// one is pending.
    @ChatSessionActor
    private static func drainPendingTaskGraphPublication(of controller: ChatSessionController) async {
        await controller.taskGraphObserver.pendingPublication?.value
    }

    /// Waits until the reporter of the turn `channel` presents now, if any,
    /// sent what it queued.
    @ChatSessionActor
    private static func flushTurnReporter(of channel: TelegramChannel) async {
        await channel.activeProgressReporter?.flush()
    }

    /// The prompts from the chat that wait for the session.
    @ChatSessionActor
    private static func queuedPromptCount(_ channel: TelegramChannel) -> Int {
        channel.promptQueue.count
    }

    /// Admits `text` on the link's route of `channel`, as the chat's
    /// ingress does; while a turn runs, it waits in the channel's queue.
    @ChatSessionActor
    private static func queuePrompt(_ text: String, on channel: TelegramChannel) async throws -> Bool {
        let lease = try #require(channel.activeRouteLease)
        return await channel.admitPrompt(text, lease: lease)
    }

    /// The text of the progress card the channel sends for the graph of
    /// `controller` as it is now.
    @ChatSessionActor
    private static func taskGraphCardText(of controller: ChatSessionController) async throws -> String {
        let graph = try #require(try await controller.runtime.taskGraphSnapshot(
            sessionID: controller.sessionID, graphID: nil
        ))
        let tasks = try await controller.runtime.taskOrchestrator.listTasks(
            sessionID: controller.sessionID, graphID: graph.id
        )
        let plainText = TerminalANSIText.stripANSI(
            TerminalChat.taskGraphMarkdown(graph: graph, tasks: tasks, ansiEnabled: false)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return "📋 Task graph\n\n\(plainText)"
    }

    /// Creates an active graph of two tasks, `first` and `second`, in
    /// `controller`'s session.
    @ChatSessionActor
    private static func createTaskGraph(on controller: ChatSessionController) async throws {
        _ = try await controller.runtime.taskOrchestrator.createGraph(
            sessionID: controller.sessionID,
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "first", title: "Task first"),
                TaskDefinition(id: "second", title: "Task second"),
            ]
        )
    }

    /// Claims the task `taskID` of `controller`'s graph, a change of the graph.
    @ChatSessionActor
    private static func claimTask(_ taskID: String, on controller: ChatSessionController) async throws {
        _ = try await controller.runtime.taskOrchestrator.claimTasks(
            sessionID: controller.sessionID,
            claims: [TaskClaim(taskID: taskID, agentID: "worker")]
        )
    }

    /// A bridge with one session, linked to the scripted Bot API by a
    /// `/telegram on` prompt (request 2, after the editor's prompt request 1
    /// when `editorPromptsFirst`; request 1 otherwise). With `clientFiles`
    /// the client advertises a text file system, which the double serves;
    /// `selectedAgent` is the session's agent.
    private static func linkedFixture(
        root: URL,
        editorPromptsFirst: Bool = false,
        selectedAgent: AgentProfile? = nil,
        clientFiles: ACPTelegramClientFiles? = nil
    ) async throws -> (fixture: ACPTelegramBridgeFixture, sessionID: String) {
        let sessionID = "acp-telegram-channel-\(UUID().uuidString)"
        let fixture = try await ACPTelegramBridgeFixture.make(
            root: root,
            sessionIDs: [sessionID],
            selectedAgent: selectedAgent,
            transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
        )
        if let clientFiles {
            try await fixture.bridge.initialize(
                id: .string("initialize"),
                params: ["clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true]]]
            )
            clientFiles.serve(wire: fixture.wire, writer: await fixture.bridge.writer)
        }
        var nextID = 1
        if editorPromptsFirst {
            await fixture.prompt("Hello from the editor", id: nextID, sessionID: sessionID)
            #expect(fixture.wire.stopReason(id: nextID) == "end_turn")
            nextID += 1
        }
        let reply = await fixture.turnTelegramOn(sessionID: sessionID, id: nextID)
        #expect(reply == activationReply)
        #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.pollCount > 0 })
        return (fixture, sessionID)
    }
}

extension ZenCODEACPBridge {
    /// The controller of the live incarnation of `sessionID`.
    fileprivate func telegramTestController(sessionID: String) -> ChatSessionController? {
        sessions[sessionID]?.controller
    }

    /// The host slot of the live session `sessionID`.
    fileprivate func telegramTestSlotID(sessionID: String) -> ChatSlotID? {
        sessions[sessionID]?.slotID
    }

    /// Whether a prompt is reserved on the live incarnation of `sessionID`.
    fileprivate func telegramTestPromptIsReserved(sessionID: String) async -> Bool {
        guard let session = sessions[sessionID] else { return false }
        return await host.liveIncarnation(in: session.slotID, epoch: session.epoch)?.activePromptID != nil
    }

    /// Whether a turn of the Telegram channel of `sessionID`'s slot reserved
    /// the session and has not ended yet.
    fileprivate func telegramTestTurnHoldsReservation(sessionID: String) async -> Bool {
        guard let session = sessions[sessionID] else { return false }
        return await host.telegramTurnHoldsReservation(in: session.slotID)
    }

    /// Starts `session/cancel` (request `cancelID`) and then `session/prompt`
    /// with `text` (request `promptID`) for `sessionID`, from one step of the
    /// bridge and in this order: the cancel runs up to its hop to the host,
    /// which drops the reservation of the turn in progress, before the prompt
    /// runs up to its own, which the host serves next and reserves; the
    /// cancel then resumes first and stops the turn it cancelled, with the
    /// prompt already reserved.
    fileprivate func telegramTestCancelThenPrompt(
        sessionID: String,
        cancelID: Int,
        promptID: Int,
        text: String
    ) -> [Task<Void, Never>] {
        [
            Task {
                await self.handleMessage([
                    "jsonrpc": "2.0", "id": cancelID, "method": "session/cancel",
                    "params": ["sessionId": sessionID] as [String: Any],
                ])
            },
            Task {
                await self.handleMessage([
                    "jsonrpc": "2.0", "id": promptID, "method": "session/prompt",
                    "params": [
                        "sessionId": sessionID,
                        "prompt": [["type": "text", "text": text]] as [[String: Any]],
                    ] as [String: Any],
                ])
            },
        ]
    }

    /// What the slot of `sessionID` knows of its turn in progress and of the
    /// reducer the handover created: for the assertion that ACP never hands
    /// a turn of the editor over.
    fileprivate func telegramTestSlotState(
        sessionID: String
    ) async -> (turnIsOpen: Bool, movedTurn: ChatMovedTurn?, transcript: [String])? {
        guard let session = sessions[sessionID] else { return nil }
        return await host.telegramTestSlotState(in: session.slotID)
    }
}

extension ChatSessionHost {
    fileprivate func telegramTestSlotState(
        in slotID: ChatSlotID
    ) -> (turnIsOpen: Bool, movedTurn: ChatMovedTurn?, transcript: [String])? {
        guard let slot = slots[slotID] else { return nil }
        let transcript = slot.incarnation?.reducer?.snapshot.transcript.compactMap { entry -> String? in
            switch entry.kind {
            case let .userPrompt(text, _, _):
                "user: \(text)"
            case let .assistantText(text):
                "assistant: \(text)"
            default:
                nil
            }
        } ?? []
        return (slot.slotPresenter.isTurnOpen, slot.slotPresenter.movedTurn, transcript)
    }
}

extension TelegramChannel {
    /// Whether the channel runs no task and queues no prompt.
    fileprivate var telegramTestIsIdle: Bool {
        activeTurnTask == nil && promptQueue.isEmpty
    }
}

/// What the bodies handed to the slot's hooks saw around them, in order.
private final class ACPTelegramBodyRecorder: Sendable {
    private let storage = Mutex<[Bool]>([])

    func record(hadClientFileSystem: Bool) {
        storage.withLock { $0.append(hadClientFileSystem) }
    }

    var recorded: [Bool] {
        storage.withLock { $0 }
    }
}
