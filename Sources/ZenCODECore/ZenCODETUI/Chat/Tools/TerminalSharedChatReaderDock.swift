//
//  TerminalSharedChatReaderDock.swift
//  ZenCODE
//

import Foundation

/// Terminal-local, bounded shared-chat history used exclusively by the input
/// panel reader. It is intentionally absent from session snapshots.
struct TerminalSharedChatReadingBuffer: Sendable {
    static let capacity = AgentSharedChat.maximumRetainedMessagesPerRoom

    private(set) var messages: [AgentSharedChat.Message] = []
    /// Reader history is deliberately independent from the scrolling transcript.
    /// Outbound and inbound messages both arrive through the room observation and
    /// remain readable here without being appended to that transcript.
    private var messageIDs: Set<UUID> = []
    private(set) var unreadCount = 0
    /// The message currently selected by the open reader. Keeping an identity
    /// rather than an array offset lets new arrivals leave the selection in
    /// place while the bounded history grows.
    private(set) var selectedMessageID: UUID?
    private(set) var isReaderOpen = false

    /// The message the reader should show when it opens. Unread messages are
    /// retained as a suffix of the bounded history, so the first unread entry
    /// is the oldest message in that suffix. With no unread arrivals, opening
    /// still starts at the newest message as it did before.
    var readerOpeningMessageID: UUID? {
        guard !messages.isEmpty else { return nil }
        let targetIndex: Int
        if unreadCount > 0 {
            targetIndex = max(0, messages.count - min(unreadCount, messages.count))
        } else {
            targetIndex = messages.count - 1
        }
        return messages[targetIndex].id
    }

    /// Adds transcript messages once per `Message.id` and returns the entries
    /// newly retained by the reader. The return value lets callers avoid
    /// refreshing an open dock for a replay without coupling this reader's
    /// history to card-rendering deduplication.
    @discardableResult
    mutating func append(_ newMessages: [AgentSharedChat.Message]) -> [AgentSharedChat.Message] {
        let appended = newMessages.filter { messageIDs.insert($0.id).inserted }
        guard !appended.isEmpty else { return [] }
        messages.append(contentsOf: appended)
        if messages.count > Self.capacity {
            let overflow = messages.count - Self.capacity
            let evicted = Array(messages.prefix(overflow))
            messages.removeFirst(overflow)
            messageIDs.subtract(evicted.map(\.id))
        }
        unreadCount = min(messages.count, unreadCount + appended.count)

        guard isReaderOpen else { return appended }
        // `TerminalSharedChatReaderDock.replace` selects the newest message
        // when the previous selection fell out of the bounded history. Mirror
        // that fallback here so an automatic move to the last message also
        // advances the read marker.
        guard let selectedMessageID,
              messages.contains(where: { $0.id == selectedMessageID }) else {
            self.selectedMessageID = messages.last?.id
            unreadCount = 0
            return appended
        }
        return appended
    }

    /// Opens the reader at the first unread retained message when one exists.
    /// Opening remains an explicit read action, so existing arrivals are
    /// consumed after the visible reader state is committed. With no unread
    /// arrivals, opening starts at the newest retained message as before.
    mutating func openReader() {
        isReaderOpen = true
        selectedMessageID = readerOpeningMessageID
        markRead()
    }

    mutating func closeReader() {
        isReaderOpen = false
        selectedMessageID = nil
    }

    /// Retained for callers that explicitly consume the whole buffer.
    mutating func markRead() { unreadCount = 0 }

    /// Applies message-selection navigation to the reader state. Scrolling
    /// within a message intentionally does not change the read marker: only
    /// selecting/reaching the newest message means all retained arrivals have
    /// been seen.
    mutating func navigate(_ action: TerminalSharedChatReaderAction) {
        guard isReaderOpen, !messages.isEmpty else { return }
        let currentIndex = selectedMessageID.flatMap { id in
            messages.firstIndex { $0.id == id }
        } ?? (messages.count - 1)
        var targetIndex = currentIndex

        switch action {
        case .previousMessage:
            targetIndex = max(0, currentIndex - 1)
        case .nextMessage:
            targetIndex = min(messages.count - 1, currentIndex + 1)
        case .firstMessage:
            targetIndex = 0
        case .lastMessage:
            targetIndex = messages.count - 1
        case .scrollUp, .scrollDown, .pageUp, .pageDown:
            return
        }

        selectedMessageID = messages[targetIndex].id
        if targetIndex == messages.count - 1 {
            markRead()
        }
    }
}

struct TerminalSharedChatReaderEntry: Sendable, Equatable {
    let id: UUID
    let route: String
    let text: String

    init(id: UUID, route: String, text: String) {
        self.id = id
        self.route = route
        self.text = text
    }

    init(message: AgentSharedChat.Message, participantMap: [String: AgentSharedChat.Participant]) {
        id = message.id
        route = TerminalChat.sharedChatIncomingCardRoute(for: message, participantMap: participantMap)
        text = message.text
    }
}

/// Pure layout/state model for the docked reader. Terminal drawing stays in
/// `TerminalStatusBar`; this type makes selection, wrapping and scrolling
/// deterministic and independent of TTY ownership.
struct TerminalSharedChatReaderDock: Sendable, Equatable {
    var entries: [TerminalSharedChatReaderEntry] = []
    var selectedIndex = 0
    var scrollOffset = 0
    var unreadCount = 0
    /// An attached shared-chat observation keeps this dock present while it is
    /// compact; expanding it only changes how that same state is rendered.
    var isExpanded = false

    enum Selection: Sendable, Equatable {
        /// Keep the entry the operator is reading when it remains retained.
        case preserve
        /// Apply an explicit reader selection (used when opening the reader).
        case message(UUID?)
    }

    mutating func replace(
        entries: [TerminalSharedChatReaderEntry],
        unreadCount: Int,
        selection: Selection = .preserve
    ) {
        let selectedID = self.entries.indices.contains(selectedIndex) ? self.entries[selectedIndex].id : nil
        self.entries = Array(entries.suffix(TerminalSharedChatReadingBuffer.capacity))
        self.unreadCount = min(self.entries.count, max(0, unreadCount))
        let requestedID: UUID?
        let isExplicitSelection: Bool
        switch selection {
        case .preserve:
            requestedID = selectedID
            isExplicitSelection = false
        case let .message(id):
            requestedID = id
            isExplicitSelection = true
        }
        if let requestedID, let index = self.entries.firstIndex(where: { $0.id == requestedID }) {
            selectedIndex = index
            // A programmatic selection is a navigation action just like the
            // arrow keys, even when it names the already-selected entry.
            // Live `.preserve` refreshes, on the other hand, leave the reader
            // exactly where the operator was scrolling.
            if isExplicitSelection {
                scrollOffset = 0
            }
        } else {
            selectedIndex = max(0, self.entries.count - 1)
            scrollOffset = 0
        }
        clamp(viewportRows: 1, width: 1)
    }

    mutating func navigate(_ action: TerminalSharedChatReaderAction, viewportRows: Int, width: Int) {
        guard !entries.isEmpty else { return }
        switch action {
        case .previousMessage: selectedIndex = max(0, selectedIndex - 1); scrollOffset = 0
        case .nextMessage: selectedIndex = min(entries.count - 1, selectedIndex + 1); scrollOffset = 0
        case .firstMessage: selectedIndex = 0; scrollOffset = 0
        case .lastMessage: selectedIndex = entries.count - 1; scrollOffset = 0
        case .scrollUp: scrollOffset -= 1
        case .scrollDown: scrollOffset += 1
        case .pageUp: scrollOffset -= max(1, viewportRows)
        case .pageDown: scrollOffset += max(1, viewportRows)
        }
        clamp(viewportRows: viewportRows, width: width)
        // Message navigation to the newest entry is the read boundary. Keep
        // this local to the pure dock model so callers that only drive the
        // status bar still get the same marker semantics as the input loop.
        switch action {
        case .previousMessage, .nextMessage, .firstMessage, .lastMessage:
            if selectedIndex == entries.count - 1 {
                unreadCount = 0
            }
        case .scrollUp, .scrollDown, .pageUp, .pageDown:
            break
        }
    }

    func rows(width: Int) -> [String] {
        guard entries.indices.contains(selectedIndex) else { return [] }
        let entry = entries[selectedIndex]
        let route = TerminalChat.sharedChatTerminalSafeText(entry.route).replacingOccurrences(of: "\n", with: " ")
        return ["Author: \(route)"]
            + TerminalChat.sharedChatWrappedRows(TerminalChat.sharedChatTerminalSafeText(entry.text), width: max(1, width))
            + [""]
    }

    mutating func clamp(viewportRows: Int, width: Int) {
        selectedIndex = min(max(0, selectedIndex), max(0, entries.count - 1))
        let maximum = max(0, rows(width: width).count - max(1, viewportRows))
        scrollOffset = min(max(0, scrollOffset), maximum)
    }
}

public enum TerminalSharedChatReaderAction: Sendable, Equatable {
    case previousMessage, nextMessage, firstMessage, lastMessage
    case scrollUp, scrollDown, pageUp, pageDown
}
