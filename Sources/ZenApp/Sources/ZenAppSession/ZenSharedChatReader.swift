//
//  ZenSharedChatReader.swift
//  ZenApp
//
//  The window's bounded history of the session's shared chat, read one
//  message at a time, as the terminal's reader dock does.
//

import Foundation
import ZenCODECore

/// The shared-chat messages of a window and what the operator read of them:
/// the port of the terminal's reading buffer (`TerminalSharedChatReadingBuffer`).
/// Transient state of the window: never saved, and reset with a new or loaded
/// session.
///
/// The history is bounded at ``capacity`` messages, each kept once per
/// `Message.id`, the oldest evicted first. Only the messages of the
/// coordinator and of the agents can be unread: the operator's own messages
/// stay in the history, already known to the human who wrote them. The
/// reader shows one message at a time (``selectedMessage``): opening it
/// selects the first unread message, else the newest, and reads it; selecting
/// an unread message reads every message up to it; moving back never makes a
/// message unread again.
public struct ZenSharedChatReader: Sendable, Equatable {
    /// The messages kept at most, the room's own bound.
    public static let capacity = AgentSharedChat.maximumRetainedMessagesPerRoom

    /// A move of the reader's selection, clamped to the history.
    public enum Navigation: Sendable, Equatable {
        /// The message before the selected one.
        case previous
        /// The message after the selected one.
        case next
        /// The oldest message kept.
        case first
        /// The newest message.
        case last
    }

    /// The messages kept, oldest first.
    public private(set) var messages: [AgentSharedChat.Message] = []
    /// The reader is open.
    public private(set) var isReaderOpen = false
    /// The message the open reader shows; `nil` while it is closed or there
    /// is nothing to show. An identity, so arrivals leave it in place.
    public private(set) var selectedMessageID: UUID?

    private var messageIDs: Set<UUID> = []
    private var unreadMessageIDs: Set<UUID> = []

    public init() {}

    /// The messages of the coordinator and the agents not read yet.
    public var unreadCount: Int {
        unreadMessageIDs.count
    }

    /// The position of ``selectedMessageID`` in ``messages``.
    public var selectedIndex: Int? {
        guard let selectedMessageID else { return nil }
        return messages.firstIndex { $0.id == selectedMessageID }
    }

    /// The message the open reader shows.
    public var selectedMessage: AgentSharedChat.Message? {
        selectedIndex.map { messages[$0] }
    }

    /// The panel shows: the reader is open, or there are unread messages.
    public var isPresented: Bool {
        isReaderOpen || unreadCount > 0
    }

    /// The panel's title, the terminal's: `Chat · N messages · U new` while
    /// the reader is closed, `Chat · 0 messages` while it is open on nothing,
    /// `Chat · i/N · U new` while it shows the `i`-th message.
    public var headerText: String {
        guard isReaderOpen else {
            let label = messages.count == 1 ? "message" : "messages"
            return "Chat · \(messages.count) \(label) · \(unreadCount) new"
        }
        guard !messages.isEmpty else {
            return "Chat · 0 messages"
        }
        let position = (selectedIndex ?? messages.count - 1) + 1
        return "Chat · \(position)/\(messages.count) · \(unreadCount) new"
    }

    /// `true` when the message `id` is kept and not read yet.
    public func isUnread(_ id: UUID) -> Bool {
        unreadMessageIDs.contains(id)
    }

    /// Keeps the messages not kept yet (one per `Message.id`), evicting the
    /// oldest beyond ``capacity``, and returns the ones newly kept. An open
    /// reader keeps its selection; when the selected message was evicted, the
    /// newest is selected and every message is read, as in the terminal.
    @discardableResult
    public mutating func append(_ newMessages: [AgentSharedChat.Message]) -> [AgentSharedChat.Message] {
        let appended = newMessages.filter { messageIDs.insert($0.id).inserted }
        guard !appended.isEmpty else { return [] }
        messages.append(contentsOf: appended)
        if messages.count > Self.capacity {
            let evicted = messages.prefix(messages.count - Self.capacity).map(\.id)
            messages.removeFirst(evicted.count)
            messageIDs.subtract(evicted)
            unreadMessageIDs.subtract(evicted)
        }
        let retained = appended.filter { messageIDs.contains($0.id) }
        unreadMessageIDs.formUnion(retained.filter { $0.sender.kind != .operator }.map(\.id))
        if isReaderOpen, selectedIndex == nil {
            selectedMessageID = messages.last?.id
            unreadMessageIDs.removeAll()
        }
        return retained
    }

    /// Opens the reader on the first unread message, else on the newest, and
    /// reads that message alone.
    public mutating func openReader() {
        isReaderOpen = true
        selectedMessageID = messages.first { unreadMessageIDs.contains($0.id) }?.id ?? messages.last?.id
        if let selectedMessageID {
            unreadMessageIDs.remove(selectedMessageID)
        }
    }

    /// Closes the reader; nothing is selected.
    public mutating func closeReader() {
        isReaderOpen = false
        selectedMessageID = nil
    }

    /// Moves the open reader's selection, clamped to the history. Selecting
    /// an unread message reads every message up to and including it; moving
    /// back never makes a message unread again.
    public mutating func navigate(_ action: Navigation) {
        guard isReaderOpen, !messages.isEmpty else { return }
        let currentIndex = selectedIndex ?? (messages.count - 1)
        let targetIndex = switch action {
        case .previous: max(0, currentIndex - 1)
        case .next: min(messages.count - 1, currentIndex + 1)
        case .first: 0
        case .last: messages.count - 1
        }
        let target = messages[targetIndex].id
        selectedMessageID = target
        guard unreadMessageIDs.contains(target) else { return }
        unreadMessageIDs.subtract(messages.prefix(through: targetIndex).map(\.id))
    }

    /// Forgets every message and closes the reader.
    public mutating func reset() {
        self = ZenSharedChatReader()
    }

    /// Reads the message `id` alone, as voice mode does once it read it
    /// aloud; an unknown or already read message changes nothing, and a
    /// message is never made unread again.
    public mutating func markRead(_ id: UUID) {
        unreadMessageIDs.remove(id)
    }
}
