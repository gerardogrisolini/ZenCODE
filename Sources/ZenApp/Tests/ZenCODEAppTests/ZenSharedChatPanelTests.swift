//
//  ZenSharedChatPanelTests.swift
//  ZenApp
//
//  The pure logic of the shared-chat panel: what it shows for each state of
//  the reader (titles, hints, author row, inert text, ‹ › at the ends), the
//  window's reader keys (consumed only while the reader is open in the
//  conversation), the Session menu title, and the line scroll of the message.
//

import Foundation
import Testing
import ZenAppControls
import ZenAppSession
import ZenCODECore

@testable import ZenCODEApp

// MARK: - Fixtures

private let roomID = "zen-panel-room"
private let operatorID = "operator:\(roomID)"
private let utc = TimeZone.gmt
/// 18:05:09 UTC.
private let sentAt = Date(timeIntervalSince1970: 65_109)

private let worker = AgentSharedChat.Participant(
    id: "agent-1",
    name: "Worker",
    kind: .agent,
    joinedAt: Date(timeIntervalSinceReferenceDate: 0)
)
private let reviewer = AgentSharedChat.Participant(
    id: "agent-2",
    name: "Reviewer",
    kind: .agent,
    joinedAt: Date(timeIntervalSinceReferenceDate: 0)
)
private let human = AgentSharedChat.Participant(
    id: operatorID,
    name: "Operator",
    kind: .operator,
    joinedAt: Date(timeIntervalSinceReferenceDate: 0)
)

/// The encoded shape of `AgentSharedChat.Message`, whose memberwise
/// initializer is internal to the core.
private struct MessageFixture: Encodable {
    let id: UUID
    let roomID: String
    let sender: AgentSharedChat.Participant
    let recipientIDs: [String]
    let text: String
    let sentAt: Date
}

private func message(
    _ text: String,
    from sender: AgentSharedChat.Participant = worker,
    to recipients: [String] = [operatorID]
) throws -> AgentSharedChat.Message {
    let fixture = MessageFixture(
        id: UUID(),
        roomID: roomID,
        sender: sender,
        recipientIDs: recipients,
        text: text,
        sentAt: sentAt
    )
    return try JSONDecoder().decode(AgentSharedChat.Message.self, from: JSONEncoder().encode(fixture))
}

private func reader(_ messages: [AgentSharedChat.Message], open: Bool = false) -> ZenSharedChatReader {
    var reader = ZenSharedChatReader()
    reader.append(messages)
    if open {
        reader.openReader()
    }
    return reader
}

private func state(_ reader: ZenSharedChatReader) -> ZenSharedChatPanelState {
    ZenSharedChatPanelLogic.state(for: reader, participants: [:], timeZone: utc)
}

private func shown(_ state: ZenSharedChatPanelState) -> ZenSharedChatPanelMessage? {
    guard case let .message(message) = state else { return nil }
    return message
}

// MARK: - States

@Suite("Shared-chat panel states")
struct ZenSharedChatPanelStateTests {
    @Test("without messages and with the reader closed the panel is hidden")
    func hiddenWhenEmpty() {
        #expect(state(ZenSharedChatReader()) == .hidden)
        #expect(ZenSharedChatPanelLogic.header(for: .hidden) == nil)
        #expect(ZenSharedChatPanelLogic.hint(for: .hidden) == nil)
    }

    @Test("a closed reader with every message read is hidden: the operator's own messages are never unread")
    func hiddenWhenRead() throws {
        #expect(state(reader([try message("mine", from: human, to: [AgentSharedChat.coordinatorID(for: roomID)])])) == .hidden)

        var read = reader([try message("one")], open: true)
        read.closeReader()
        #expect(read.unreadCount == 0)
        #expect(state(read) == .hidden)
    }

    @Test("a closed reader with unread messages shows one row with the terminal's title and \"⌃Y read\"")
    func unreadRow() throws {
        let two = state(reader([try message("one"), try message("two")]))
        #expect(two == .unread(header: "Chat · 2 messages · 2 new"))
        #expect(ZenSharedChatPanelLogic.header(for: two) == "Chat · 2 messages · 2 new")
        #expect(ZenSharedChatPanelLogic.hint(for: two) == "⌃Y read")

        #expect(state(reader([try message("one")])) == .unread(header: "Chat · 1 message · 1 new"))
    }

    @Test("an open reader on nothing shows \"Chat · 0 messages\" and \"⌃Y close\"")
    func openEmpty() {
        let empty = state(reader([], open: true))
        #expect(empty == .empty(header: "Chat · 0 messages"))
        #expect(ZenSharedChatPanelLogic.header(for: empty) == "Chat · 0 messages")
        #expect(ZenSharedChatPanelLogic.hint(for: empty) == "⌃Y close")
    }

    @Test("an open reader shows its selected message: title i/N, author row, text, \"⌃Y close\"")
    func openMessage() throws {
        let messages = [try message("first"), try message("second"), try message("third")]
        let panel = state(reader(messages, open: true))
        let message = try #require(shown(panel))
        // Opening selects the first unread message and reads it alone.
        #expect(message.id == messages[0].id)
        #expect(message.header == "Chat · 1/3 · 2 new")
        #expect(ZenSharedChatPanelLogic.header(for: panel) == "Chat · 1/3 · 2 new")
        #expect(message.author == "Author: Worker [18:05:09] → Operator")
        #expect(message.text == "first")
        #expect(ZenSharedChatPanelLogic.hint(for: panel) == "⌃Y close")
    }

    @Test("‹ is disabled on the first message and › on the last; both in between; neither for a lone message")
    func buttonsAtTheEnds() throws {
        let messages = [try message("a"), try message("b"), try message("c")]
        var open = reader(messages, open: true)
        open.navigate(.first)
        let first = try #require(shown(state(open)))
        #expect(!first.canShowPrevious)
        #expect(first.canShowNext)

        open.navigate(.next)
        let middle = try #require(shown(state(open)))
        #expect(middle.header == "Chat · 2/3 · 1 new")
        #expect(middle.canShowPrevious)
        #expect(middle.canShowNext)

        open.navigate(.last)
        let last = try #require(shown(state(open)))
        #expect(last.header == "Chat · 3/3 · 0 new")
        #expect(last.canShowPrevious)
        #expect(!last.canShowNext)

        let lone = try #require(shown(state(reader([try message("only")], open: true))))
        #expect(!lone.canShowPrevious)
        #expect(!lone.canShowNext)
    }

    @Test("the route names the recipient: Coordinator, All, a known participant, else Agent")
    func routes() throws {
        let toCoordinator = try message("hi", to: [AgentSharedChat.coordinatorID(for: roomID)])
        #expect(
            ZenSharedChatPanelLogic.authorLine(for: toCoordinator, participants: [:], timeZone: utc)
                == "Author: Worker [18:05:09] → Coordinator"
        )
        let toAll = try message("hi", to: [operatorID, reviewer.id])
        #expect(
            ZenSharedChatPanelLogic.authorLine(for: toAll, participants: [:], timeZone: utc)
                == "Author: Worker [18:05:09] → All"
        )
        let toReviewer = try message("hi", to: [reviewer.id])
        #expect(
            ZenSharedChatPanelLogic.authorLine(for: toReviewer, participants: [reviewer.id: reviewer], timeZone: utc)
                == "Author: Worker [18:05:09] → Reviewer"
        )
        #expect(
            ZenSharedChatPanelLogic.authorLine(for: toReviewer, participants: [:], timeZone: utc)
                == "Author: Worker [18:05:09] → Agent"
        )
        // The participants of the session reach the panel's author row.
        let panel = ZenSharedChatPanelLogic.state(
            for: reader([toReviewer], open: true),
            participants: [reviewer.id: reviewer],
            timeZone: utc
        )
        #expect(try #require(shown(panel)).author == "Author: Worker [18:05:09] → Reviewer")
    }

    @Test("the author row is one inert line and the text is inert plain text, never Markdown")
    func inertText() throws {
        let raw = "**bold** and `code`\nline two \u{1B}[31mred\u{1B}[0m \u{202E}bidi"
        let shownMessage = try #require(shown(state(reader([try message(raw)], open: true))))
        #expect(shownMessage.text == SharedChatMentionParser.terminalSafeText(raw))
        #expect(shownMessage.text.contains("**bold** and `code`"))
        #expect(shownMessage.text.contains("\n"))
        #expect(!shownMessage.text.contains("\u{1B}"))
        #expect(!shownMessage.text.contains("\u{202E}"))

        let oddName = AgentSharedChat.Participant(
            id: "agent-3",
            name: "Two\nLines\u{1B}[1m",
            kind: .agent,
            joinedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let author = ZenSharedChatPanelLogic.authorLine(
            for: try message("hi", from: oddName),
            participants: [:],
            timeZone: utc
        )
        #expect(author.hasPrefix("Author: "))
        #expect(!author.contains("\n"))
        #expect(!author.contains("\u{1B}"))
    }
}

// MARK: - Keys

@Suite("Shared-chat reader keys")
@MainActor
struct ZenSharedChatReaderKeyTests {
    private let keys: [ZenReaderKey] = [
        .previousMessage, .nextMessage, .firstMessage, .lastMessage, .scrollUp, .scrollDown,
    ]

    @Test("while the reader is open in the conversation every reader key maps to its action")
    func mapping() {
        func action(_ key: ZenReaderKey) -> ZenSharedChatKeyAction? {
            ZenSharedChatPanelLogic.action(for: key, isReaderOpen: true, selectedTab: .chat)
        }
        #expect(action(.previousMessage) == .navigate(.previous))
        #expect(action(.nextMessage) == .navigate(.next))
        #expect(action(.firstMessage) == .navigate(.first))
        #expect(action(.lastMessage) == .navigate(.last))
        #expect(action(.scrollUp) == .scroll(.up))
        #expect(action(.scrollDown) == .scroll(.down))
    }

    @Test("the window's handler consumes the keys while the reader is open in the conversation and performs them")
    func consumedWhileOpen() {
        var navigations: [ZenSharedChatReader.Navigation] = []
        var scrolls: [ZenSharedChatScrollDirection] = []
        let consumed = keys.map { key in
            ZenSharedChatPanelLogic.handle(
                key,
                isReaderOpen: true,
                selectedTab: .chat,
                navigate: { navigations.append($0) },
                scroll: { scrolls.append($0) }
            )
        }
        #expect(consumed == Array(repeating: true, count: keys.count))
        #expect(navigations == [.previous, .next, .first, .last])
        #expect(scrolls == [.up, .down])
    }

    @Test("a closed reader, or a sub-agent tab, leaves every key its ordinary meaning")
    func notConsumed() {
        for (isReaderOpen, tab) in [(false, ZenWindowTab.chat), (true, .subAgent("a")), (false, .subAgent("a"))] {
            #expect(!ZenSharedChatPanelLogic.consumesReaderKeys(isReaderOpen: isReaderOpen, selectedTab: tab))
            for key in keys {
                var performed = false
                let consumed = ZenSharedChatPanelLogic.handle(
                    key,
                    isReaderOpen: isReaderOpen,
                    selectedTab: tab,
                    navigate: { _ in performed = true },
                    scroll: { _ in performed = true }
                )
                #expect(!consumed)
                #expect(!performed)
                #expect(ZenSharedChatPanelLogic.action(for: key, isReaderOpen: isReaderOpen, selectedTab: tab) == nil)
            }
        }
        #expect(ZenSharedChatPanelLogic.consumesReaderKeys(isReaderOpen: true, selectedTab: .chat))
    }

    @Test("an open reader on nothing still consumes the keys, as the terminal does")
    func consumedOnEmptyReader() {
        let empty = reader([], open: true)
        var navigations: [ZenSharedChatReader.Navigation] = []
        let consumed = ZenSharedChatPanelLogic.handle(
            .nextMessage,
            isReaderOpen: empty.isReaderOpen,
            selectedTab: .chat,
            navigate: { navigations.append($0) },
            scroll: { _ in }
        )
        #expect(consumed)
        #expect(navigations == [.next])
    }
}

// MARK: - Menu

@Suite("Chat reader menu item")
struct ZenSharedChatMenuTitleTests {
    @Test("the item reads Hide only when a click closes the reader: open in the conversation")
    func titles() {
        #expect(ZenSharedChatPanelLogic.menuTitle(isReaderOpen: true, selectedTab: .chat) == "Hide Chat Reader")
        #expect(ZenSharedChatPanelLogic.menuTitle(isReaderOpen: false, selectedTab: .chat) == "Show Chat Reader")
        // From a sub-agent tab a click shows the conversation with the reader.
        #expect(ZenSharedChatPanelLogic.menuTitle(isReaderOpen: true, selectedTab: .subAgent("a")) == "Show Chat Reader")
        #expect(ZenSharedChatPanelLogic.menuTitle(isReaderOpen: false, selectedTab: .subAgent("a")) == "Show Chat Reader")
    }
}

// MARK: - Scroll

@Suite("Shared-chat message scroll")
struct ZenSharedChatScrollTests {
    @Test("every scroll request is a new value, even in the same direction")
    func requests() {
        var request = ZenSharedChatScrollRequest()
        let initial = request
        request.request(.down)
        let firstDown = request
        request.request(.down)
        #expect(firstDown != initial)
        #expect(request != firstDown)
        #expect(request.direction == .down)
        request.request(.up)
        #expect(request.direction == .up)
        #expect(request.serial == 3)
    }

    @Test("a line scroll moves one line and stays inside the text")
    func lineScroll() {
        let metrics = ZenSharedChatScrollMetrics(offsetY: 0, contentHeight: 400, containerHeight: 192)
        #expect(metrics.maximumOffset == 208)
        #expect(metrics.offset(scrolling: .up, lineHeight: 16) == 0)
        #expect(metrics.offset(scrolling: .down, lineHeight: 16) == 16)

        let nearEnd = ZenSharedChatScrollMetrics(offsetY: 200, contentHeight: 400, containerHeight: 192)
        #expect(nearEnd.offset(scrolling: .down, lineHeight: 16) == 208)
        #expect(nearEnd.offset(scrolling: .up, lineHeight: 16) == 184)

        let fits = ZenSharedChatScrollMetrics(offsetY: 0, contentHeight: 40, containerHeight: 40)
        #expect(fits.maximumOffset == 0)
        #expect(fits.offset(scrolling: .down, lineHeight: 16) == 0)
    }

    @Test("the text's view shrinks to the text, from one line up to twelve")
    func textHeight() {
        #expect(ZenSharedChatPanelLogic.maximumVisibleLines == 12)
        #expect(ZenSharedChatPanelLogic.textHeight(contentHeight: 0, lineHeight: 16) == 16)
        #expect(ZenSharedChatPanelLogic.textHeight(contentHeight: 48, lineHeight: 16) == 48)
        #expect(ZenSharedChatPanelLogic.textHeight(contentHeight: 2_000, lineHeight: 16) == 192)
    }
}
