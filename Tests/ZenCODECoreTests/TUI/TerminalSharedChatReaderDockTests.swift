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
    func openingReaderStartsAtNewestMessageAndConsumesExistingUnread() {
        let messages = (21...23).map(message)
        var buffer = TerminalSharedChatReadingBuffer()
        buffer.append(messages)
        #expect(buffer.unreadCount == messages.count)

        buffer.openReader()

        #expect(buffer.isReaderOpen)
        #expect(buffer.selectedMessageID == messages.last?.id)
        #expect(buffer.unreadCount == 0)
    }

    @Test
    func readerRetainsPreRenderedTranscriptMessageWithoutDuplicatingIt() {
        let outbound = message(24)
        var renderedIDs = TerminalChat.SharedChatRenderedMessageIDs()
        let renderedSynchronously = renderedIDs.insert(outbound.id)
        #expect(renderedSynchronously) // Card was rendered synchronously.

        // The later transcript replay is suppressed for card rendering, but
        // still enters the reader as one unread, idempotent history entry.
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [outbound],
            renderedMessageIDs: &renderedIDs
        ).isEmpty)
        var buffer = TerminalSharedChatReadingBuffer()
        #expect(buffer.append([outbound]) == [outbound])
        #expect(buffer.messages.map(\.id) == [outbound.id])
        #expect(buffer.unreadCount == 1)
        #expect(buffer.append([outbound]).isEmpty)
        #expect(buffer.messages.map(\.id) == [outbound.id])
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
        #expect(rows.first?.contains("Message") == true)
        #expect(rows.count > 2)

        dock.navigate(.scrollDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == 1)
        dock.navigate(.pageDown, viewportRows: 2, width: 7)
        #expect(dock.scrollOffset == max(0, rows.count - 2))
    }

    @Test
    func statusBarOwnsExpandedDockWithoutExternalTerminalReader() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: true)
        #expect(await statusBar.state.sharedChatReaderDock?.entries.count == 1)
        await statusBar.navigateSharedChatReader(.lastMessage)
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        #expect(await statusBar.state.sharedChatReaderDock == nil)
    }

    @Test
    func emptyReaderOpensAndShowsZeroMessages() async {
        let output = SharedChatCapturedOutput()
        let statusBar = TerminalStatusBar(isEnabled: true) { output.append($0) }
        await statusBar.configureForTesting(row: 9, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        output.clear()

        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: true)

        #expect(await statusBar.state.sharedChatReaderDock?.entries.isEmpty == true)
        #expect(output.text.contains("Shared chat · 0 messages · Ctrl+Y close"))
        #expect(output.text.contains("╭─ "))
        #expect(output.text.contains("╯"))
        let palette = TerminalStyle.SharedChat.palette(for: TerminalMarkdownPalette.detected.appearance)
        #expect(output.text.contains(palette.border))
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
        #expect(output.text.contains("Shared chat"))
        #expect(!output.text.contains("↑/↓ scroll"))
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
