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

    // MARK: - Bounded ingress

    /// The Core bounds every observer stream; without a bound here the same
    /// growth would simply move into the task that forwards those events into
    /// the terminal. Under overflow the evictable roster events go first, oldest
    /// first; a shared-chat message is never evicted (backpressure guarantees it
    /// reaches every active observer).
    @Test
    func overflowEvictsOldestEvictableRenderEventsFirst() async {
        let queue = TerminalChatEventQueue(capacity: 3)
        queue.send(.sharedChatMessages(roomID: "room", messages: []))
        queue.send(.sharedChatParticipantsChanged(roomID: "room"))
        queue.send(.input(.submitted("operator work")))
        queue.send(.sharedChatParticipantsChanged(roomID: "room"))

        #expect(queue.bufferedEventCount == 3)
        #expect(queue.evictedEventCount == 1)

        var iterator = queue.events.makeAsyncIterator()
        var delivered: [TerminalChatRuntimeEvent] = []
        for _ in 0 ..< 3 {
            if let event = await iterator.next() {
                delivered.append(event)
            }
        }
        // The non-evictable shared-chat message survives; the oldest evictable
        // roster event was evicted, leaving the newest roster event last.
        #expect(delivered.count == 3)
        if case .sharedChatMessages = delivered[0] {} else {
            Issue.record("Expected the shared-chat message to survive overflow")
        }
        if case .input(.submitted("operator work")) = delivered[1] {} else {
            Issue.record("Expected operator work to survive the overflow")
        }
        if case .sharedChatParticipantsChanged = delivered[2] {} else {
            Issue.record("Expected the newest roster event to survive")
        }
    }

    /// An auto-trigger is a coordination decision. It is never evicted into a
    /// second local recovery queue: when no slot is available, its forwarding
    /// producer receives `rejectedFull` and immediately declines it to Core.
    @Test
    func fullQueueRejectsAutoTriggerForExplicitCoreRecovery() {
        let queue = TerminalChatEventQueue(capacity: 1)
        let first = AgentSharedChatAutoTrigger(
            roomID: "room",
            messages: [],
            prompt: "first"
        )
        let second = AgentSharedChatAutoTrigger(
            roomID: "room",
            messages: [],
            prompt: "second"
        )
        queue.send(.sharedChatAutoTrigger(first))
        let result = queue.offer(.sharedChatAutoTrigger(second))

        #expect(queue.bufferedEventCount == 1)
        #expect(queue.bufferedEventCount <= queue.capacity)
        #expect(result == .rejectedFull)
        #expect(queue.rejectedEventCount == 1)
    }

    /// Input and lifecycle events have no recovery copy. The producer waits for
    /// a bounded queue slot, so neither event is silently dropped and the queue
    /// never becomes a soft/unbounded bound under saturation.
    @Test
    func nonDroppableInputAndLifecycleBackpressureAtHardCapacity() async {
        let queue = TerminalChatEventQueue(capacity: 1)
        queue.send(.input(.submitted("one")))
        let lifecycleProducer = Task {
            await queue.sendWithBackpressure(.startNextQueuedPrompt)
        }

        #expect(queue.evictedEventCount == 0)
        #expect(queue.bufferedEventCount == 1)
        #expect(queue.bufferedEventCount <= queue.capacity)

        var iterator = queue.events.makeAsyncIterator()
        if case let .some(.input(.submitted(line))) = await iterator.next() {
            #expect(line == "one")
        } else {
            Issue.record("Expected the original non-droppable input")
        }
        #expect(await lifecycleProducer.value)
        if case .some(.startNextQueuedPrompt) = await iterator.next() {
            // Expected lifecycle event after the consumer freed a slot.
        } else {
            Issue.record("Expected the backpressured lifecycle event")
        }
        #expect(queue.bufferedEventCount <= queue.capacity)
    }

    /// Telegram forwarding is a single finite producer. A full runtime FIFO
    /// suspends that producer instead of accepting a growing backlog or losing a
    /// remote prompt before `queuedPrompts` can apply its own admission policy.
    @Test
    func telegramProducerBackpressuresUntilRuntimeQueueDrains() async {
        let queue = TerminalChatEventQueue(capacity: 1)
        let telegram = TerminalTelegramIncomingMessage(
            chatID: 7,
            userID: 9,
            text: "remote prompt",
            voice: nil,
            messageID: 11,
            chatTitle: "Test chat",
            username: "remote"
        )
        queue.send(.input(.submitted("occupies the only slot")))
        let producer = Task {
            await queue.sendWithBackpressure(.telegramMessage(telegram))
        }

        try? await Task.sleep(for: .milliseconds(20))
        #expect(queue.bufferedEventCount == 1)
        #expect(queue.bufferedEventCount <= queue.capacity)

        var iterator = queue.events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await producer.value)
        if case let .some(.telegramMessage(delivered)) = await iterator.next() {
            #expect(delivered == telegram)
        } else {
            Issue.record("Expected Telegram message after backpressure release")
        }
    }

    /// Completed voice transcriptions are bounded by the voice registry, then
    /// use the same runtime backpressure as Telegram text rather than dropping a
    /// transcript when the terminal is temporarily busy.
    @Test
    func voiceCompletionBackpressuresUntilRuntimeQueueDrains() async {
        let queue = TerminalChatEventQueue(capacity: 1)
        let voice = TerminalVoicePromptResult(
            origin: .telegram(chatID: 7),
            outcome: .success("transcribed prompt")
        )
        queue.send(.input(.submitted("occupies the only slot")))
        let producer = Task {
            await queue.sendWithBackpressure(.voicePromptCompleted(voice))
        }

        var iterator = queue.events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await producer.value)
        if case let .some(.voicePromptCompleted(delivered)) = await iterator.next() {
            #expect(delivered.origin == .telegram(chatID: 7))
            if case let .success(prompt) = delivered.outcome {
                #expect(prompt == "transcribed prompt")
            } else {
                Issue.record("Expected the successful voice transcript")
            }
        } else {
            Issue.record("Expected voice completion after backpressure release")
        }
        #expect(queue.bufferedEventCount <= queue.capacity)
    }

    @Test
    func queuedPromptsRejectOverflowWithoutChangingFIFO() {
        var prompts = TerminalQueuedPromptBuffer(capacity: 2)
        let first = TerminalQueuedPrompt(text: "first", origin: .local)
        let second = TerminalQueuedPrompt(text: "second", origin: .local)
        let overflow = TerminalQueuedPrompt(text: "overflow", origin: .local)

        let acceptedFirst = prompts.enqueue(first)
        let acceptedSecond = prompts.enqueue(second)
        let acceptedOverflow = prompts.enqueue(overflow)
        let countAtCapacity = prompts.count
        let dequeuedFirst = prompts.dequeue()
        let dequeuedSecond = prompts.dequeue()
        let dequeuedEmpty = prompts.dequeue()

        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(!acceptedOverflow)
        #expect(countAtCapacity == 2)
        #expect(prompts.count == 0)
        #expect(dequeuedFirst == first)
        #expect(dequeuedSecond == second)
        #expect(dequeuedEmpty == nil)
    }

    /// A reader suspended on an empty queue is handed the next event directly,
    /// so the bound never interferes with a healthy consumer.
    @Test
    func suspendedReaderReceivesTheNextEventInOrder() async {
        let queue = TerminalChatEventQueue(capacity: 2)
        let reader = Task { () -> TerminalChatRuntimeEvent? in
            var iterator = queue.events.makeAsyncIterator()
            return await iterator.next()
        }
        try? await Task.sleep(for: .milliseconds(20))
        queue.send(.input(.submitted("late arrival")))

        if case let .some(.input(.submitted(line))) = await reader.value {
            #expect(line == "late arrival")
        } else {
            Issue.record("Expected the suspended reader to receive the event")
        }
        #expect(queue.evictedEventCount == 0)
    }
}
