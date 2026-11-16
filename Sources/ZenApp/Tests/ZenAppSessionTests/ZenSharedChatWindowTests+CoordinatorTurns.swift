//
//  ZenSharedChatWindowTests+CoordinatorTurns.swift
//  ZenAppSessionTests
//
//  Tests of the shared chat of a window over a scripted backend and a real
//  room bus: the reader, the hidden coordinator turn, a trigger declined
//  while busy, and the claims acquired while a line starts or not granted.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

extension ZenSharedChatWindowTests {
    @Test("Room messages reach the reader with their unread state; the operator's own are not unread")
    func messagesReachTheReader() async throws {
        try await withRoom { runtime, backend, window, room, chat in
            let handle = try await Self.agentHandle(in: window)
            #expect(window.sharedChatParticipants[Self.agentID]?.name == Self.agentName)
            #expect(window.sharedChatParticipants.values.contains { $0.kind == .operator })
            #expect(window.mentionSuggestions.prefix(2).map(\.handle) == ["coordinator", "all"])
            #expect(!window.sharedChat.isPresented)

            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Build is green")
            await waitUntil("the message reaches the reader") { window.sharedChat.messages.count == 1 }
            #expect(window.sharedChat.unreadCount == 1)
            #expect(window.sharedChat.isPresented)
            #expect(window.sharedChat.headerText == "Chat · 1 message · 1 new")
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)

            window.toggleSharedChatReader()
            #expect(window.sharedChat.isReaderOpen)
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)
            #expect(window.sharedChat.selectedIndex.map { window.sharedChat.messages[$0].text } == "Build is green")
            #expect(window.sharedChat.headerText == "Chat · 1/1 · 0 new")

            // The operator answers the agent: delivered by id, kept as read.
            window.draft = "\(handle)thanks"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            let sent = try #require(await backend.sentSharedChatMessages.first)
            #expect(sent.destination == .direct([Self.agentID]))
            #expect(sent.text == "thanks")
            #expect(sent.rootSessionID == room)
            await waitUntil("the operator's message reaches the reader") { window.sharedChat.messages.count == 2 }
            #expect(window.sharedChat.messages.last?.id == sent.messageID)
            #expect(window.sharedChat.messages.last?.sender.kind == .operator)
            #expect(window.sharedChat.unreadCount == 0)
            #expect(window.sharedChat.selectedIndex.map { window.sharedChat.messages[$0].text } == "Build is green")
            window.navigateSharedChat(.next)
            #expect(window.sharedChat.selectedIndex.map { window.sharedChat.messages[$0].text } == "thanks")
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)

            window.toggleSharedChatReader()
            #expect(!window.sharedChat.isReaderOpen)
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)
            #expect(!window.sharedChat.isPresented)
            // No turn ran for any of it.
            #expect(await backend.prompts == ["Hello"])
            #expect(window.history.entries == ["Hello", "\(handle)thanks"])
        }
    }

    @Test("A message for the coordinator runs a hidden coordinator turn: its prompt reaches the model, not the transcript")
    func coordinatorMessageRunsAHiddenTurn() async throws {
        try await withRoom { _, backend, window, room, chat in
            await backend.script(prompt: "Need a decision", events: [])
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the coordinator turn reaches the model") { await backend.prompts.count == 2 }
            #expect(await window.waitUntilIdle())
            let prompt = try #require(await backend.prompts.last)
            #expect(prompt.contains("[Live chat messages]"))
            #expect(prompt.contains("Need a decision"))
            await waitUntil("the turn's answer shows") {
                window.transcript.contains {
                    $0.content == .assistantText("Scripted answer to Need a decision", isStreaming: false)
                }
            }
            #expect(!window.transcript.contains { item in
                if case let .userPrompt(text, _, _) = item.content { return text.contains("Need a decision") }
                return false
            })
            #expect(window.sharedChat.messages.map(\.text) == ["Need a decision"])
            #expect(window.sharedChat.unreadCount == 1)
            #expect(window.history.entries == ["Hello"])
            #expect(window.queuedLines.isEmpty)
        }
    }

    @Test("A trigger reaching a busy window is declined, then runs once, after the line ends")
    func triggerWhileBusyIsDeclined() async throws {
        try await withRoom { _, backend, window, room, chat in
            let gate = ZenGate()
            window.sharedChatTriggerWillResolve = { await gate.pass() }
            await backend.script(prompt: "Ping", events: [])
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Ping")
            await waitUntil("the trigger reaches the window") { await gate.reached }

            // The window gets busy before it answers the trigger.
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            await backend.waitUntilHeld()
            await gate.open()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await backend.prompts == ["Hello", "First"])
            #expect(window.queuedLines.isEmpty)

            await backend.release()
            await waitUntil("the coordinator turn runs after the line") { await backend.prompts.count == 3 }
            #expect(await window.waitUntilIdle())
            let prompts = await backend.prompts
            #expect(prompts.last?.contains("Ping") == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await backend.prompts.count == 3)
            #expect(window.transcript.contains {
                $0.content == .assistantText("Scripted answer to Ping", isStreaming: false)
            })
        }
    }

    @Test("A coordinator turn stopped before it starts gives its claim back: the messages run again once idle")
    func stoppedCoordinatorTurnGivesItsClaimBack() async throws {
        try await withRoom { _, backend, window, room, chat in
            let gate = ZenGate()
            window.turnDidReserve = { await gate.pass() }
            await backend.script(prompt: "Ping", events: [])
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Ping")
            await waitUntil("the coordinator turn reserved its prompt") { await gate.reached }
            #expect(window.isBusy)

            window.stop()
            await gate.open()
            await waitUntil("the stopped turn shows") {
                window.transcript.contains { $0.content == .local(text: ZenWindowSession.turnCancelledText, isFailure: false) }
            }
            // Given back, the batch is offered again and runs once.
            await waitUntil("the coordinator turn runs again") { await backend.prompts.count == 2 }
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.last?.contains("Ping") == true)
            await waitUntil("the turn's answer shows") {
                window.transcript.contains {
                    $0.content == .assistantText("Scripted answer to Ping", isStreaming: false)
                }
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await backend.prompts.count == 2)
        }
    }

    @Test("A claim acquired while a line starts is given back ahead of the line's idle declaration; the batch runs once")
    func claimAcquiredWhileALineStarts() async throws {
        try await withRoom { _, backend, window, room, chat in
            let claim = ZenGate()
            let giveBack = ZenGate()
            let reserve = ZenGate()
            window.sharedChatClaimWillResolve = { resolution in
                if resolution == .started {
                    await claim.pass()
                } else {
                    await giveBack.pass()
                }
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the claim is on its way") { await claim.reached }
            #expect(!window.isBusy)

            // A line starts meanwhile; its turn waits before it reaches the
            // Core, so the room is still idle when the claim lands.
            window.turnDidReserve = { await reserve.pass() }
            window.draft = "First"
            window.submitDraft()
            await waitUntil("the line reserved its prompt") { await reserve.reached }
            #expect(window.isBusy)
            await claim.open()

            // On the chain, the claim lands ahead of the line's busy
            // declaration, so the Core grants it; one sent off the chain
            // would land behind it and be refused. Acquired by a busy window,
            // the claim is given back, and the trigger's answer waits for the
            // give-back: the barrier, handled after the trigger, cannot show
            // first.
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Barrier")
            await waitUntil("the window answers the trigger") {
                await giveBack.reached || window.sharedChat.messages.contains { $0.text == "Barrier" }
            }
            #expect(await giveBack.reached, "the claim was not granted: it landed behind the line's busy declaration")
            #expect(!window.sharedChat.messages.contains { $0.text == "Barrier" })

            // The line ends while the give-back waits: its idle declaration
            // queues behind the give-back, so it cannot release the claim and
            // lose the batch.
            await reserve.open()
            await waitUntil("the line ends") { !window.isBusy }
            #expect(await backend.prompts == ["Hello", "First"])
            await giveBack.open()

            await waitUntil("the batch runs after the line") { await backend.prompts.count == 3 }
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.last?.contains("Need a decision") == true)
            await Self.expectNextTurnCarriesOnly(
                "Second question",
                notCarrying: "Need a decision",
                window: window,
                backend: backend,
                chat: chat,
                room: room
            )
        }
    }

    @Test("A claim the Core does not grant starts nothing; the batch runs once, after the line")
    func claimNotAcquiredStartsNothing() async throws {
        try await withRoom { _, backend, window, room, chat in
            let claim = ZenGate()
            window.sharedChatClaimWillResolve = { resolution in
                if resolution == .started {
                    await claim.pass()
                }
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the claim is on its way") { await claim.reached }

            // A line's turn reaches the Core first: the room is busy when the
            // claim lands, so the claim is not granted.
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            await backend.waitUntilHeld()
            await claim.open()
            // Handled after the trigger: once it shows, the window answered it.
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Barrier")
            await waitUntil("the barrier reaches the reader") {
                window.sharedChat.messages.contains { $0.text == "Barrier" }
            }
            #expect(await backend.prompts == ["Hello", "First"])
            #expect(window.queuedLines.isEmpty)
            #expect(!window.transcript.contains { item in
                if case .local(_, isFailure: true) = item.content { return true }
                return false
            })

            await backend.release()
            await waitUntil("the batch runs after the line") { await backend.prompts.count == 3 }
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.last?.contains("Need a decision") == true)
            await Self.expectNextTurnCarriesOnly(
                "Second question",
                notCarrying: "Need a decision",
                window: window,
                backend: backend,
                chat: chat,
                room: room
            )
        }
    }
}
