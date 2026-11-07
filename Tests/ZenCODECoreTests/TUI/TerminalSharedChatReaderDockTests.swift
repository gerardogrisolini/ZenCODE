//
//  TerminalSharedChatReaderDockTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Drives `TerminalSharedChatObservationSupervisor` through the same seam the
/// blocking input loop uses in production: real `AsyncStream` observations that
/// can be ended, cancelled or replaced, instead of a bookkeeping set.
private actor SharedChatObservationHarness {
    private(set) var attachedRooms: [String] = []
    private(set) var attachedIDs: [UUID] = []
    private(set) var detachedIDs: [UUID] = []
    private(set) var handledEventCount = 0
    private(set) var backoffAttempts: [Int] = []
    private var continuations: [UUID: AsyncStream<AgentSharedChatCoordinatorEvent>.Continuation] = [:]
    /// Reproduces a backend that keeps closing the observation immediately.
    private var finishesImmediately = false

    func setFinishesImmediately(_ value: Bool) {
        finishesImmediately = value
    }

    func attach(roomID: String) -> AgentSharedChatCoordinator.Observation {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentSharedChatCoordinatorEvent>.makeStream()
        attachedRooms.append(roomID)
        attachedIDs.append(id)
        continuations[id] = continuation
        if finishesImmediately {
            continuation.finish()
        }
        return AgentSharedChatCoordinator.Observation(id: id, roomID: roomID, events: stream)
    }

    func detach(_ observation: AgentSharedChatCoordinator.Observation) {
        detachedIDs.append(observation.id)
        continuations.removeValue(forKey: observation.id)?.finish()
    }

    func handle(_ event: AgentSharedChatCoordinatorEvent) {
        handledEventCount += 1
    }

    func recordBackoff(_ attempt: Int) {
        backoffAttempts.append(attempt)
    }

    func yield(_ event: AgentSharedChatCoordinatorEvent, to id: UUID) {
        continuations[id]?.yield(event)
    }

    func finishStream(_ id: UUID) {
        continuations[id]?.finish()
    }
}

/// Lets the injected backoff stop the supervisor it belongs to, so the
/// hot-loop guard can be proven without sleeping through real delays.
private actor SharedChatSupervisorBox {
    private var supervisor: TerminalSharedChatObservationSupervisor?

    func set(_ supervisor: TerminalSharedChatObservationSupervisor) {
        self.supervisor = supervisor
    }

    func stop() async {
        await supervisor?.stop()
    }
}

@Suite
struct TerminalSharedChatReaderDockTests {
    private func entry(_ number: Int, text: String = "body") -> TerminalSharedChatReaderEntry {
        TerminalSharedChatReaderEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!, route: "Agent \(number) → Coordinator", text: text)
    }

    private func message(_ number: Int) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: "reader-room",
            sender: AgentSharedChat.Participant(
                id: "agent-\(number)",
                name: "Agent \(number)",
                kind: .agent
            ),
            recipientIDs: ["coordinator:reader-room"],
            text: "message \(number)"
        )
    }

    private func operatorMessage(_ number: Int) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: "reader-room",
            sender: AgentSharedChat.Participant(
                id: AgentSharedChat.operatorID(for: "reader-room"),
                name: "operator",
                kind: .operator
            ),
            recipientIDs: ["coordinator:reader-room"],
            text: "operator message \(number)"
        )
    }

    private func harnessSupervisor(
        roomID: String,
        harness: SharedChatObservationHarness,
        backoff: (@Sendable (Int) async -> Void)? = nil
    ) -> TerminalSharedChatObservationSupervisor {
        TerminalSharedChatObservationSupervisor(
            roomID: roomID,
            environment: TerminalSharedChatObservationSupervisor.Environment(
                attach: { await harness.attach(roomID: $0) },
                detach: { await harness.detach($0) },
                handleEvent: { event, _ in await harness.handle(event) },
                backoff: backoff ?? { await harness.recordBackoff($0) }
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    @Test
    func blockingObservationSupervisorReattachesAfterAnUncancelledEnd() async {
        let harness = SharedChatObservationHarness()
        let supervisor = harnessSupervisor(roomID: "room-a", harness: harness)

        await supervisor.start()
        #expect(await harness.attachedRooms == ["room-a"])
        let first = await harness.attachedIDs[0]

        // A delivered event proves the pump is the production path and makes
        // the end below a healthy one, which must recover without pacing.
        await harness.yield(.participantsChanged([]), to: first)
        #expect(await waitUntil { await harness.handledEventCount == 1 })

        // The stream ends by itself: no cancellation, same room, and no input
        // is ever submitted afterwards.
        await harness.finishStream(first)

        #expect(await waitUntil { await harness.attachedIDs.count == 2 })
        let detached = await harness.detachedIDs
        let rooms = await harness.attachedRooms
        let currentID = await supervisor.currentObservation()?.id
        let secondID = await harness.attachedIDs[1]
        #expect(detached == [first])
        #expect(rooms == ["room-a", "room-a"])
        #expect(currentID == secondID)
        #expect(await supervisor.recoveryCount == 1)
        #expect(await harness.backoffAttempts.isEmpty)

        await supervisor.stop()
    }

    @Test
    func blockingObservationSupervisorFollowsRoomSwapAndStopsWithoutReattaching() async {
        let harness = SharedChatObservationHarness()
        let supervisor = harnessSupervisor(roomID: "room-a", harness: harness)

        await supervisor.start()
        let first = await harness.attachedIDs[0]

        await supervisor.follow(roomID: "room-b")
        #expect(await harness.attachedRooms == ["room-a", "room-b"])
        #expect(await harness.detachedIDs == [first])

        // Same-room follow is a no-op: recovery owns that path, not the loop.
        await supervisor.follow(roomID: "room-b")
        #expect(await harness.attachedRooms == ["room-a", "room-b"])

        let second = await harness.attachedIDs[1]
        await supervisor.stop()

        #expect(await harness.detachedIDs == [first, second])
        #expect(await supervisor.currentObservation() == nil)
        // Cancellation is local teardown, never a reason to attach again.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await harness.attachedIDs.count == 2)
        #expect(await supervisor.recoveryCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func blockingObservationSupervisorPacesStreamsThatEndImmediately() async throws {
        let harness = SharedChatObservationHarness()
        await harness.setFinishesImmediately(true)
        let backoffs = AsyncStream<Int>.makeStream()
        let releases = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        defer {
            backoffs.continuation.finish()
            releases.continuation.finish()
            stopped.continuation.finish()
        }
        let box = SharedChatSupervisorBox()
        let supervisor = harnessSupervisor(roomID: "room-a", harness: harness) { attempt in
            await harness.recordBackoff(attempt)
            backoffs.continuation.yield(attempt)
            // Hold each retry until the test observes the detached subscription.
            // The test drives progress; elapsed wall time is only an anti-hang guard.
            var permits = releases.stream.makeAsyncIterator()
            _ = await permits.next()
            if attempt >= 3 || Task.isCancelled {
                await box.stop()
                stopped.continuation.yield(())
                stopped.continuation.finish()
            }
        }
        await box.set(supervisor)

        await supervisor.start()
        var attempts = backoffs.stream.makeAsyncIterator()
        for expectedAttempt in 1...3 {
            let attempt = try #require(await attempts.next())
            #expect(attempt == expectedAttempt)
            // A replacement cannot attach until this backoff is released.
            #expect(await harness.attachedIDs.count == expectedAttempt)
            #expect(await harness.detachedIDs.count == expectedAttempt)
            #expect(await supervisor.currentObservation() == nil)
            releases.continuation.yield(())
        }
        var completion = stopped.stream.makeAsyncIterator()
        try #require(await completion.next() != nil)

        #expect(await harness.backoffAttempts == [1, 2, 3])
        #expect(await harness.attachedIDs.count == 3)
        #expect(await harness.detachedIDs.count == 3)
        #expect(await supervisor.recoveryCount == 2)
        #expect(await supervisor.currentObservation() == nil)
    }

    @Test
    func operatorMessagesRemainInReaderHistoryWithoutBecomingUnread() {
        let outbound = operatorMessage(1)
        var buffer = TerminalSharedChatReadingBuffer()

        #expect(buffer.append([outbound]) == [outbound])
        #expect(buffer.messages.map(\.id) == [outbound.id])
        #expect(buffer.unreadCount == 0)
        #expect(buffer.readerOpeningMessageID == outbound.id)

        buffer.openReader()

        #expect(buffer.selectedMessageID == outbound.id)
        #expect(buffer.unreadCount == 0)

        buffer.closeReader()
        buffer.append([operatorMessage(2)])
        #expect(buffer.unreadCount == 0)
    }

    /// Voice mode consumes exactly the message it read aloud, by identity.
    @Test
    func markingOneMessageReadByIdentityConsumesOnlyThatMessage() {
        let first = message(1)
        let second = message(2)
        let outbound = operatorMessage(3)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append([first, outbound, second])
        #expect(buffer.unreadCount == 2)
        #expect(buffer.isUnread(first.id))
        #expect(buffer.isUnread(second.id))
        #expect(!buffer.isUnread(outbound.id))

        buffer.markRead(id: second.id)
        #expect(buffer.unreadCount == 1)
        #expect(!buffer.isUnread(second.id))
        #expect(buffer.isUnread(first.id))
        #expect(buffer.readerOpeningMessageID == first.id)

        // Unknown, operator or already-read identifiers change nothing.
        buffer.markRead(id: UUID())
        buffer.markRead(id: outbound.id)
        buffer.markRead(id: second.id)
        #expect(buffer.unreadCount == 1)

        buffer.markRead(id: first.id)
        #expect(buffer.unreadCount == 0)
        #expect(!buffer.isUnread(first.id))
        // A replay of a read message never reopens it.
        #expect(buffer.append([first, second]).isEmpty)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func operatorMessagesDoNotShiftUnreadBoundaryWhenInterleaved() {
        let first = message(1)
        let outbound = operatorMessage(2)
        let second = message(3)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append([first, outbound, second])

        #expect(buffer.unreadCount == 2)
        #expect(buffer.readerOpeningMessageID == first.id)

        buffer.openReader()
        #expect(buffer.selectedMessageID == first.id)
        #expect(buffer.unreadCount == 1)

        buffer.navigate(.nextMessage)
        #expect(buffer.selectedMessageID == outbound.id)
        #expect(buffer.unreadCount == 1)

        buffer.navigate(.nextMessage)
        #expect(buffer.selectedMessageID == second.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func selectingLastMessageMarksArrivalsReadAfterReaderWasOpened() {
        let first = message(1)
        let second = message(2)
        let newest = message(3)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append([first, second])
        buffer.openReader()
        buffer.navigate(.previousMessage)

        buffer.append([newest])

        #expect(buffer.unreadCount == 2)
        #expect(buffer.selectedMessageID == first.id)
        buffer.navigate(.lastMessage)
        #expect(buffer.selectedMessageID == newest.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func openingReaderStartsAtFirstUnreadMessageAndConsumesOnlyVisibleMessage() {
        let messages = (21...23).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(messages)
        #expect(buffer.unreadCount == messages.count)

        buffer.openReader()

        #expect(buffer.isReaderOpen)
        #expect(buffer.selectedMessageID == messages.first?.id)
        #expect(buffer.unreadCount == messages.count - 1)
    }

    @Test
    func readingBufferAndDockDecreaseUnreadCountAsMessagesAreVisited() {
        let messages = (41...43).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(messages)

        #expect(buffer.readerOpeningUnreadCount == 2)
        buffer.openReader()
        #expect(buffer.selectedMessageID == messages[0].id)
        #expect(buffer.unreadCount == 2)

        buffer.navigate(.nextMessage)
        #expect(buffer.selectedMessageID == messages[1].id)
        #expect(buffer.unreadCount == 1)
        buffer.navigate(.previousMessage)
        #expect(buffer.unreadCount == 1)

        var dock = TerminalSharedChatReaderDock()
        dock.replace(
            entries: (41...43).map { entry($0) },
            unreadCount: 2,
            selection: .message(entry(41).id)
        )
        dock.navigate(.nextMessage, viewportRows: 2, width: 80)
        #expect(dock.selectedIndex == 1)
        #expect(dock.unreadCount == 1)
        dock.navigate(.previousMessage, viewportRows: 2, width: 80)
        #expect(dock.unreadCount == 1)
    }

    @Test
    func replacementIsBoundedAndKeepsSelectedMessageWhenItStillExists() {
        var dock = TerminalSharedChatReaderDock()
        let entries = (1...(TerminalSharedChatReadingBuffer.capacity + 2)).map { entry($0) }
        dock.replace(entries: entries, unreadCount: entries.count)

        #expect(dock.entries.count == TerminalSharedChatReadingBuffer.capacity)
        #expect(dock.entries.first?.route.contains("3") == true)
        #expect(dock.selectedIndex == TerminalSharedChatReadingBuffer.capacity - 1)
        #expect(dock.unreadCount == TerminalSharedChatReadingBuffer.capacity)
    }

    @Test
    func layoutWrapsOneSelectedMessageAndClampsScroll() {
        var dock = TerminalSharedChatReaderDock()
        dock.replace(entries: [entry(1, text: "one two three four five six")], unreadCount: 1)
        let rows = dock.rows(width: 7)
        #expect(rows.first?.contains("Author: Agent 1") == true)
        #expect(rows.last == "")
        #expect(rows.count > 1)

        dock.navigate(.scrollDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == 1)
        dock.navigate(.pageDown, viewportRows: 2, width: 7)
        dock.navigate(.pageDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == max(0, rows.count - 2))
    }

    @Test
    func explicitReplacementSelectionResetsScrollButLivePreservationDoesNot() {
        var dock = TerminalSharedChatReaderDock()
        let long = entry(40, text: "one two three four five six")
        let short = entry(41, text: "short")
        let entries = [long, short]

        // `replace` selects the newest entry, whose body is one row: scroll
        // back onto the long entry first, otherwise no offset can exist at all.
        dock.replace(entries: entries, unreadCount: 2)
        #expect(dock.selectedIndex == 1)
        dock.navigate(.previousMessage, viewportRows: 2, width: 7)
        #expect(dock.selectedIndex == 0)
        #expect(dock.rows(width: 7).count > 2)

        dock.navigate(.scrollDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == 1)

        // A live refresh must leave the operator exactly where they were.
        dock.replace(entries: entries, unreadCount: 2, selection: .preserve)
        #expect(dock.selectedIndex == 0)
        #expect(dock.scrollOffset == 1)

        // An explicit selection of a different entry is a navigation: it
        // changes the selected message and rewinds to the top of it.
        dock.replace(entries: entries, unreadCount: 2, selection: .message(short.id))
        #expect(dock.selectedIndex == 1)
        #expect(dock.scrollOffset == 0)

        // Reopening can explicitly select the same newest ID. It is still an
        // explicit navigation and must not restore a stale scroll position.
        dock.replace(entries: [long], unreadCount: 1, selection: .message(long.id))
        dock.navigate(.scrollDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == 1)
        dock.replace(entries: [long], unreadCount: 1, selection: .message(long.id))
        #expect(dock.scrollOffset == 0)
    }

    @Test
    func retiredObservationCannotRemoveReplacementDock() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let retired = UUID()
        let replacement = UUID()
        await statusBar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: false, observationID: retired)
        await statusBar.setSharedChatReader(entries: [entry(2)], unreadCount: 1, isExpanded: false, observationID: replacement)

        await statusBar.removeSharedChatReader(ownedBy: retired)

        #expect(await statusBar.state.sharedChatReaderDock?.entries.first?.id == entry(2).id)
    }

    @Test
    func authoritativeCollapseReconcilesStaleExpansionWithoutReplacingDockState() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let observation = UUID()
        let entries = [entry(1), entry(2)]
        await statusBar.setSharedChatReader(
            entries: entries,
            unreadCount: 2,
            isExpanded: false,
            observationID: observation
        )

        // Simulate the refresh that resumed after resize and re-expanded the
        // same observation before the queued collapse reached its consumer.
        await statusBar.setSharedChatReader(
            entries: entries,
            unreadCount: 2,
            isExpanded: true,
            observationID: observation
        )
        await statusBar.collapseSharedChatReader(ownedBy: observation)

        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await statusBar.state.sharedChatReaderDock?.entries == entries)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 2)

        // Replaying the FIFO event is harmless.
        await statusBar.collapseSharedChatReader(ownedBy: observation)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await statusBar.state.sharedChatReaderDock?.entries == entries)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 2)
    }
}
