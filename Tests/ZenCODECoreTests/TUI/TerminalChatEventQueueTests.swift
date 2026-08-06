//
//  TerminalChatEventQueueTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatEventQueueTests {
    @Test
    func synchronousInputIngressPreservesToggleBeforeSubmit() async {
        let queue = TerminalChatEventQueue()
        queue.send(.input(.toggleAccessModeRequested))
        queue.send(.input(.submitted("prompt")))

        var iterator = queue.events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        if case .some(.input(.toggleAccessModeRequested)) = first {
            // Expected first event.
        } else {
            Issue.record("Expected access-mode toggle before submit")
        }
        if case let .some(.input(.submitted(prompt))) = second {
            #expect(prompt == "prompt")
        } else {
            Issue.record("Expected submitted prompt after access-mode toggle")
        }
    }

    @Test
    func bufferedTogglePrecedesQueuedPromptStartAfterGenerationCompletes() async {
        let queue = TerminalChatEventQueue()
        queue.send(
            .generationCompleted(
                .failure(
                    TerminalChatGenerationFailure(
                        message: "",
                        isCancellation: false,
                        origin: .local,
                        fileChangeSummary: nil
                    )
                )
            )
        )
        queue.send(.input(.toggleAccessModeRequested))

        var iterator = queue.events.makeAsyncIterator()
        let completed = await iterator.next()
        // The runtime enqueues this only after handling generation completion;
        // any input already buffered must remain ahead of it.
        queue.send(.startNextQueuedPrompt)
        let control = await iterator.next()
        let queuedPromptStart = await iterator.next()

        if case .some(.generationCompleted(_)) = completed {
            // Expected completion event.
        } else {
            Issue.record("Expected generation completion first")
        }
        if case .some(.input(.toggleAccessModeRequested)) = control {
            // Expected buffered control event before queue advancement.
        } else {
            Issue.record("Expected toggle before queued prompt start")
        }
        if case .some(.startNextQueuedPrompt) = queuedPromptStart {
            // Expected queue advancement last.
        } else {
            Issue.record("Expected queued prompt start after buffered controls")
        }
    }

    @Test
    func sharedChatEventsQueuedBeforeSessionSwapRemainBoundToTheirOriginalRoom() async {
        let retiredRoomID = "terminal-before-resume"
        let resumedRoomID = "terminal-after-resume"
        let staleTrigger = AgentSharedChatAutoTrigger(
            roomID: retiredRoomID,
            messages: [],
            prompt: "stale shared-chat prompt"
        )
        let queue = TerminalChatEventQueue()
        // These events model a producer that yielded just before `/new` or
        // `/resume` re-bound the observer. FIFO ordering preserves them, so the
        // consumer must use their room rather than the latest session id.
        queue.send(.sharedChatMessages(roomID: retiredRoomID, messages: []))
        queue.send(.sharedChatParticipantsChanged(roomID: retiredRoomID))
        queue.send(.sharedChatAutoTrigger(staleTrigger))
        queue.send(.sharedChatMessages(roomID: resumedRoomID, messages: []))

        var iterator = queue.events.makeAsyncIterator()
        var queuedEvents: [TerminalChatRuntimeEvent] = []
        for _ in 0..<4 {
            if let event = await iterator.next() {
                queuedEvents.append(event)
            }
        }

        guard queuedEvents.count == 4 else {
            Issue.record("Expected all room-bound shared-chat events from the FIFO")
            return
        }
        #expect(queuedEvents.map(\.sharedChatRoomID) == [
            retiredRoomID,
            retiredRoomID,
            retiredRoomID,
            resumedRoomID
        ])
        #expect(queuedEvents.filter {
            $0.sharedChatRoomID == resumedRoomID
        }.count == 1)
        // This is the same predicate used by the terminal loop after a
        // `/resume`: the old observer/event is stale even before the rebind
        // task is processed, while the event from the resumed room is valid.
        #expect(!queuedEvents[0].belongsToActiveSharedChatRoom(
            observedRoomID: retiredRoomID,
            sessionID: resumedRoomID
        ))
        #expect(queuedEvents[3].belongsToActiveSharedChatRoom(
            observedRoomID: resumedRoomID,
            sessionID: resumedRoomID
        ))

        guard case let .sharedChatAutoTrigger(queuedTrigger) = queuedEvents[2] else {
            Issue.record("Expected the stale trigger to remain identifiable in the queue")
            return
        }
        #expect(queuedTrigger.roomID == retiredRoomID)
        #expect(queuedEvents[2].sharedChatRoomID != resumedRoomID)
    }

    @Test
    func finishTerminatesTheStreamAndDropsLaterEvents() async {
        let queue = TerminalChatEventQueue()
        queue.send(.input(.submitted("before teardown")))
        queue.finish()

        // Producers that outlive the runtime loop (Telegram forwarder, a voice
        // task being cancelled) must not buffer into a stream nobody drains.
        #expect(queue.isFinished)
        #expect(!queue.send(.input(.submitted("after teardown"))))

        var received: [String] = []
        for await event in queue.events {
            if case let .input(.submitted(line)) = event {
                received.append(line)
            }
        }
        // The stream terminates instead of suspending forever, and only the
        // pre-teardown event was delivered.
        #expect(received == ["before teardown"])
    }

    @Test
    func finishIsIdempotent() {
        let queue = TerminalChatEventQueue()
        queue.finish()
        queue.finish()
        #expect(queue.isFinished)
    }

}
