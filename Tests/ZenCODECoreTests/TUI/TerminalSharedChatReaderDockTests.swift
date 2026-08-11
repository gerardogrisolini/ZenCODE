//
//  TerminalSharedChatReaderDockTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private final class SharedChatCapturedOutput: Sendable {
    private let storage = Mutex("")

    func append(_ text: String) {
        storage.withLock { $0 += text }
    }

    var text: String { storage.withLock { $0 } }

    func clear() { storage.withLock { $0 = "" } }
}

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

    @Test
    func blockingObservationSupervisorPacesStreamsThatEndImmediately() async {
        let harness = SharedChatObservationHarness()
        await harness.setFinishesImmediately(true)
        let box = SharedChatSupervisorBox()
        let supervisor = harnessSupervisor(roomID: "room-a", harness: harness) { attempt in
            await harness.recordBackoff(attempt)
            // Third strike: stop instead of pausing. This keeps the test fast
            // and proves the pause is the only thing between re-attachments.
            if attempt >= 3 {
                await box.stop()
            }
        }
        await box.set(supervisor)

        await supervisor.start()

        #expect(await waitUntil { await harness.backoffAttempts.count == 3 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await harness.backoffAttempts == [1, 2, 3])
        #expect(await harness.attachedIDs.count == 3)
        #expect(await harness.detachedIDs.count == 3)
        #expect(await supervisor.currentObservation() == nil)
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

        #expect(buffer.unreadCount == 1)
        #expect(buffer.selectedMessageID == first.id)
        buffer.navigate(.lastMessage)
        #expect(buffer.selectedMessageID == newest.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func advancingToLastMessageClearsUnreadAfterNewArrival() {
        let first = message(11)
        let second = message(12)
        let newest = message(13)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append([first, second])
        buffer.openReader()
        buffer.navigate(.previousMessage)
        buffer.append([newest])

        buffer.navigate(.nextMessage)
        #expect(buffer.selectedMessageID == second.id)
        #expect(buffer.unreadCount == 1)
        buffer.navigate(.nextMessage)
        #expect(buffer.selectedMessageID == newest.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func openingReaderStartsAtFirstUnreadMessageAndConsumesExistingUnread() {
        let messages = (21...23).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(messages)
        #expect(buffer.unreadCount == messages.count)

        buffer.openReader()

        #expect(buffer.isReaderOpen)
        #expect(buffer.selectedMessageID == messages.first?.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func openingReaderWithoutUnreadStartsAtNewestMessage() {
        let messages = (25...27).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(messages)
        buffer.markRead()

        buffer.openReader()

        #expect(buffer.selectedMessageID == messages.last?.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func openingReaderStartsAtFirstUnreadAfterReadHistory() {
        let readMessages = (28...30).map(message)
        let unreadMessages = (31...32).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(readMessages)
        buffer.markRead()
        buffer.append(unreadMessages)

        #expect(buffer.unreadCount == unreadMessages.count)
        #expect(buffer.readerOpeningMessageID == unreadMessages.first?.id)

        buffer.openReader()

        #expect(buffer.selectedMessageID == unreadMessages.first?.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func readerRetainsTranscriptMessageWithoutDuplicatingIt() {
        let incoming = message(24)
        // Transcript replays remain invisible to the main terminal transcript,
        // but enter the reader as one unread, idempotent history entry.
        var buffer = TerminalSharedChatReadingBuffer()
        #expect(buffer.append([incoming]) == [incoming])
        #expect(buffer.messages.map(\.id) == [incoming.id])
        #expect(buffer.unreadCount == 1)
        #expect(buffer.append([incoming]).isEmpty)
        #expect(buffer.messages.map(\.id) == [incoming.id])
        #expect(buffer.unreadCount == 1)
    }

    @Test
    func dockNavigationToNewestMessageClearsUnreadBadge() {
        var dock = TerminalSharedChatReaderDock()
        dock.replace(entries: [entry(31), entry(32)], unreadCount: 2)
        dock.navigate(.firstMessage, viewportRows: 2, width: 80)
        #expect(dock.unreadCount == 2)

        dock.navigate(.lastMessage, viewportRows: 2, width: 80)

        #expect(dock.selectedIndex == 1)
        #expect(dock.unreadCount == 0)
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
    func statusBarRemovesCompactDockWhenHistoryBecomesEmpty() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: true)
        #expect(await statusBar.state.sharedChatReaderDock?.entries.count == 1)
        await statusBar.navigateSharedChatReader(.lastMessage)
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        #expect(await statusBar.state.sharedChatReaderDock == nil)
    }

    @Test
    func openingReaderExplicitlySelectsNewestDockEntry() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.setSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 2,
            isExpanded: false
        )
        await statusBar.navigateSharedChatReader(.firstMessage)

        await statusBar.setSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 0,
            isExpanded: true,
            selection: .message(entry(2).id)
        )

        #expect(await statusBar.state.sharedChatReaderDock?.selectedIndex == 1)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 0)
    }

    @Test
    func removingHiddenEmptyReaderClearsItsActiveObservation() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let observation = UUID()
        await statusBar.setSharedChatReader(
            entries: [], unreadCount: 0, isExpanded: false, observationID: observation
        )
        #expect(await statusBar.state.sharedChatReaderDock == nil)
        #expect(await statusBar.state.sharedChatReaderObservationID == observation)

        await statusBar.removeSharedChatReader()

        #expect(await statusBar.state.sharedChatReaderDock == nil)
        #expect(await statusBar.state.sharedChatReaderObservationID == nil)
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

    @Test
    func retiredObservationCannotCollapseReplacementDock() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let retired = UUID()
        let replacement = UUID()
        await statusBar.setSharedChatReader(
            entries: [entry(1)], unreadCount: 1, isExpanded: true, observationID: retired
        )
        await statusBar.setSharedChatReader(
            entries: [entry(2)], unreadCount: 1, isExpanded: true, observationID: replacement
        )

        await statusBar.collapseSharedChatReader(ownedBy: retired)

        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(await statusBar.state.sharedChatReaderDock?.entries.first?.id == entry(2).id)
    }

    @Test
    func compactDockIsHiddenAtZeroMessagesForAnActiveObservation() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        output.clear()

        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)

        #expect(await statusBar.state.sharedChatReaderDock == nil)
        #expect(await statusBar.reservedRowsForOverlay() == 6)
        #expect(!output.text.contains("Chat · 0 messages"))
    }

    @Test
    func compactDockRefreshesUnreadCountWithoutExpanding() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        output.clear()

        await statusBar.setSharedChatReader(entries: [entry(1), entry(2)], unreadCount: 2, isExpanded: false)

        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await statusBar.state.sharedChatReaderDock?.entries.count == 2)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 2)
        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        // The compact header increases the bottom overlay from six to seven rows,
        // so the transcript must be constrained to rows 1...2 on a 9-row terminal.
        #expect(output.text.contains("\u{1B}[1;2r"))
        #expect(output.text.contains("Chat · 2 messages · 2 unread"))
        #expect(!output.text.contains("Ctrl+Y read"))
        #expect(output.text.contains("╭─ "))
        #expect(output.text.contains("─╮"))
        let palette = TerminalStyle.SharedChat.palette(for: TerminalMarkdownPalette.detected.appearance)
        #expect(output.text.contains(palette.border))
        #expect(!output.text.contains("Author: Agent 1"))
    }

    @Test
    func openEmptyReaderShowsCompactStateAndClosingHidesIt() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        output.clear()

        let didOpen = await statusBar.expandSharedChatReader(
            entries: [],
            unreadCount: 0
        )

        #expect(didOpen)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(output.text.contains("Chat · 0 messages"))
        #expect(!output.text.contains("Ctrl+Y"))
        #expect(!output.text.contains("↑/↓ scroll"))

        output.clear()
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)

        #expect(await statusBar.state.sharedChatReaderDock == nil)
        #expect(await statusBar.reservedRowsForOverlay() == 6)
        #expect(!output.text.contains("Chat · 0 messages"))
    }

    @Test
    func shortTerminalDegradesDockToHeaderWithoutReducingScrollableRows() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        output.clear()

        await statusBar.setSharedChatReader(entries: [entry(1, text: "a very long message that would otherwise need several rows")], unreadCount: 1, isExpanded: true)

        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        #expect(output.text.contains("Chat"))
        #expect(!output.text.contains("↑/↓ scroll"))
    }

    @Test
    func shortTerminalKeepsCompactDockWithinOneReservedRow() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 20)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        output.clear()

        await statusBar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: false)

        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        #expect(output.text.contains("Chat"))
    }

    @Test
    func shortTerminalCapsSuggestionsBeforeConsumingScrollableRows() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(
            text: "draft",
            cursorIndex: 5,
            modeText: "Chat",
            helpText: "Enter",
            suggestionLines: (1...6).map { "suggestion \($0)" }
        )

        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(output.text.contains("suggestion 1"))
        #expect(!output.text.contains("suggestion 2"))
    }

    @Test
    func compactDockOutranksSuggestionOnMinimumTerminal() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(
            text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter",
            suggestionLines: ["suggestion"]
        )
        output.clear()

        await statusBar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: false)

        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        #expect(output.text.contains("Chat · 1 message · 1 unread"))
        #expect(!output.text.contains("Ctrl+Y read"))
        #expect(!output.text.contains("suggestion"))
        // One reserved row cannot show a payload row, so the transaction must
        // refuse to commit rather than silently consume the unread badge.
        let didExpand = await statusBar.expandSharedChatReader(
            entries: [entry(1)],
            unreadCount: 0,
            selection: .message(entry(1).id)
        )
        #expect(!didExpand)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 1)
    }

    @Test
    func expandingReaderCommitsSelectionAndPayloadRowsInOneTransaction() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 20, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 2,
            isExpanded: false
        )
        output.clear()

        let didExpand = await statusBar.expandSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 0,
            selection: .message(entry(2).id)
        )

        #expect(didExpand)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(await statusBar.state.sharedChatReaderDock?.selectedIndex == 1)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 0)
        // The same operation that reported success also painted the payload.
        #expect(output.text.contains("Author: Agent 2 → Coordinator"))
        #expect(output.text.contains("\(TerminalStyle.Text.muted)Author: Agent 2 → Coordinator"))
        #expect(output.text.contains("\(TerminalStyle.Text.primary)body"))
        #expect(output.text.contains("↑/↓ scroll · ←/→ message · Home/End first/last"))
        // A live refresh of an open reader still preserves the reading position.
        await statusBar.navigateSharedChatReader(.firstMessage)
        await statusBar.setSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 1,
            isExpanded: true
        )
        #expect(await statusBar.state.sharedChatReaderDock?.selectedIndex == 0)
    }

    @Test
    func expandingReaderDoesNotCommitWhileAResizeIsPending() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 20, columns: 80, isResizePending: true)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 2,
            isExpanded: false
        )
        output.clear()

        // Geometry is known-stale and every render is suppressed, so no payload
        // row can have been shown: the transaction must not commit or consume.
        let duringResize = await statusBar.expandSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 0,
            selection: .message(entry(2).id)
        )

        #expect(!duringResize)
        #expect(output.text.isEmpty)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 2)

        await statusBar.configureForTesting(row: 20, columns: 80)
        let afterResize = await statusBar.expandSharedChatReader(
            entries: [entry(1), entry(2)],
            unreadCount: 0,
            selection: .message(entry(2).id)
        )

        #expect(afterResize)
        #expect(await statusBar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 0)
    }

    @Test
    func minimumHeightPanelKeepsUnreadCounterInsideTheModeRow() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        // 8 rows is the smallest geometry `minimumRowsLocked` accepts with a
        // panel, and there chrome + status + editor + scroll fill the screen.
        await statusBar.configureForTesting(row: 8, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter send")
        output.clear()

        await statusBar.setSharedChatReader(entries: [entry(1), entry(2)], unreadCount: 2, isExpanded: false)

        // No reserved dock row is taken and the transcript keeps its minimum…
        #expect(await statusBar.reservedRowsForOverlay() == 6)
        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        // …so the counter degrades into the existing mode row, and leads it so
        // truncation can never be what removes it.
        #expect(output.text.contains("Chat: 2 unread · Ctrl+Y read · Chat · Enter send"))
        #expect(!output.text.contains("Chat · 2 messages · 2 unread"))

        output.clear()
        await statusBar.setSharedChatReader(entries: [entry(1), entry(2), entry(3)], unreadCount: 3, isExpanded: false)

        #expect(output.text.contains("Chat: 3 unread · Ctrl+Y read"))
        #expect(await statusBar.reservedRowsForOverlay() == 6)

        output.clear()
        await statusBar.removeSharedChatReader()

        #expect(!output.text.contains("Chat:"))
        #expect(await statusBar.reservedRowsForOverlay() == 6)
    }

    @Test
    func tallDraftAndDockShareBudgetWhilePreservingScrollableRows() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 11, columns: 80)
        let draft = String(repeating: "draft ", count: 100)
        await statusBar.updateInputPanel(text: draft, cursorIndex: draft.count, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(entries: [entry(1, text: "body")], unreadCount: 1, isExpanded: true)

        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        #expect(await statusBar.reservedRowsForOverlay() == 9)
        #expect(output.text.contains("↑/↓ scroll · ←/→ message · Home/End first/last"))
    }

    @Test
    func navigationRewritesReservedRegionWhenSelectedMessageChangesDockHeight() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 16, columns: 40)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        let long = entry(1, text: String(repeating: "long wrapped message ", count: 30))
        let short = entry(2, text: "short")
        await statusBar.setSharedChatReader(entries: [long, short], unreadCount: 2, isExpanded: true)
        let oldReservedRows = await statusBar.reservedRowsForOverlay()
        output.clear()

        await statusBar.navigateSharedChatReader(.previousMessage)

        let newReservedRows = await statusBar.reservedRowsForOverlay()
        #expect(newReservedRows > oldReservedRows)
        #expect(output.text.contains(String(repeating: "\n", count: newReservedRows - oldReservedRows)))
        #expect(output.text.contains("\u{1B}[1;\(16 - newReservedRows)r"))
    }
}
