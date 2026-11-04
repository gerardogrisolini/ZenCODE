//
//  ZenSharedChatPanel.swift
//  ZenApp
//
//  The shared-chat panel of a window, above the composer in the
//  conversation: the terminal's reader dock. Closed, it shows
//  one row while messages wait unread; open, it shows one message at a time,
//  with its author and route, and the reader keys of the terminal (← → Home
//  End between messages, ↑ ↓ to scroll the message), even while the composer
//  has the focus. ⌃Y and the Session menu open and close it.
//

import Foundation
import Observation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// What the shared-chat panel shows.
enum ZenSharedChatPanelState: Equatable {
    /// Nothing: the reader is closed and every message is read.
    case hidden
    /// The reader is closed and messages wait unread: one row that opens it.
    case unread(header: String)
    /// The reader is open on an empty history.
    case empty(header: String)
    /// The reader shows a message.
    case message(ZenSharedChatPanelMessage)
}

/// The message the open reader shows, ready for the panel.
struct ZenSharedChatPanelMessage: Equatable {
    let id: UUID
    /// The panel's title: `Chat · i/N · U new`.
    let header: String
    /// `Author: <route>` on one line, made inert.
    let author: String
    /// The message text, made inert: plain text, never Markdown.
    let text: String
    /// A message precedes it: ‹ is enabled.
    let canShowPrevious: Bool
    /// A message follows it: › is enabled.
    let canShowNext: Bool
}

/// What a reader key does in the window.
enum ZenSharedChatKeyAction: Equatable {
    /// Move the reader's selection.
    case navigate(ZenSharedChatReader.Navigation)
    /// Scroll the message shown.
    case scroll(ZenSharedChatScrollDirection)
}

/// The direction of a scroll of the message shown.
enum ZenSharedChatScrollDirection: Equatable {
    case up
    case down
}

/// A request to scroll the message shown, one line per request: every
/// request is a new value, so a held key scrolls once per repeat.
struct ZenSharedChatScrollRequest: Equatable {
    /// Bumped by every request.
    private(set) var serial = 0
    /// The direction of the latest request.
    private(set) var direction: ZenSharedChatScrollDirection = .down

    mutating func request(_ direction: ZenSharedChatScrollDirection) {
        serial &+= 1
        self.direction = direction
    }
}

/// The scroll requests of a window's panel, owned by the bottom chrome and
/// observed by the message view alone, so a scroll redraws nothing else.
@MainActor
@Observable
final class ZenSharedChatScroller {
    private(set) var request = ZenSharedChatScrollRequest()

    func scroll(_ direction: ZenSharedChatScrollDirection) {
        request.request(direction)
    }
}

/// The geometry of the message's scroll view the panel reads: its height
/// shrinks to the text, and a line scroll stays inside the text.
struct ZenSharedChatScrollMetrics: Equatable {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0

    init(offsetY: CGFloat = 0, contentHeight: CGFloat = 0, containerHeight: CGFloat = 0) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height
        )
    }

    /// The largest offset: the end of the text at the bottom of the view.
    var maximumOffset: CGFloat {
        max(0, contentHeight - containerHeight)
    }

    /// The offset one line up or down, clamped to the text.
    func offset(scrolling direction: ZenSharedChatScrollDirection, lineHeight: CGFloat) -> CGFloat {
        let step = direction == .up ? -lineHeight : lineHeight
        return min(max(0, offsetY + step), maximumOffset)
    }
}

/// What the shared-chat panel decides, apart from the views.
enum ZenSharedChatPanelLogic {
    /// The hint of the closed panel.
    static let readHint = "⌃Y read"
    /// The hint of the open panel.
    static let closeHint = "⌃Y close"
    /// The lines of text the message shows at most before it scrolls.
    static let maximumVisibleLines = 12

    /// The panel for `reader`: hidden unless the reader is open or messages
    /// wait unread; the open reader shows its selected message (the newest
    /// when nothing is selected, as its header counts).
    static func state(
        for reader: ZenSharedChatReader,
        participants: [String: AgentSharedChat.Participant],
        timeZone: TimeZone = .current
    ) -> ZenSharedChatPanelState {
        guard reader.isPresented else { return .hidden }
        guard reader.isReaderOpen else { return .unread(header: reader.headerText) }
        let messages = reader.messages
        guard !messages.isEmpty else { return .empty(header: reader.headerText) }
        let index = reader.selectedIndex ?? messages.count - 1
        let message = messages[index]
        return .message(ZenSharedChatPanelMessage(
            id: message.id,
            header: reader.headerText,
            author: authorLine(for: message, participants: participants, timeZone: timeZone),
            text: SharedChatMentionParser.terminalSafeText(message.text),
            canShowPrevious: index > 0,
            canShowNext: index < messages.count - 1
        ))
    }

    /// The panel's title.
    static func header(for state: ZenSharedChatPanelState) -> String? {
        switch state {
        case .hidden: nil
        case let .unread(header), let .empty(header): header
        case let .message(message): message.header
        }
    }

    /// The shortcut hint next to the title: `⌃Y read` closed, `⌃Y close`
    /// open.
    static func hint(for state: ZenSharedChatPanelState) -> String? {
        switch state {
        case .hidden: nil
        case .unread: readHint
        case .empty, .message: closeHint
        }
    }

    /// The author row of the terminal's reader: `Author: <route>`, on one
    /// line and inert.
    static func authorLine(
        for message: AgentSharedChat.Message,
        participants: [String: AgentSharedChat.Participant],
        timeZone: TimeZone = .current
    ) -> String {
        let route = SharedChatMessageLabel.route(for: message, participantMap: participants, timeZone: timeZone)
        return "Author: \(SharedChatMentionParser.inlineTerminalSafeText(route))"
    }

    /// The height of the message's scroll view: the text's, at least one
    /// line and at most ``maximumVisibleLines``.
    static func textHeight(contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, lineHeight), lineHeight * CGFloat(maximumVisibleLines))
    }

    // MARK: Keys

    /// The window's reader keys act while the reader is open in the
    /// conversation, even on an empty history, as in the terminal.
    static func consumesReaderKeys(isReaderOpen: Bool, selectedTab: ZenWindowTab) -> Bool {
        isReaderOpen && selectedTab == .chat
    }

    /// What `key` does: `nil` while the window's reader keys do not act.
    static func action(
        for key: ZenReaderKey,
        isReaderOpen: Bool,
        selectedTab: ZenWindowTab
    ) -> ZenSharedChatKeyAction? {
        guard consumesReaderKeys(isReaderOpen: isReaderOpen, selectedTab: selectedTab) else { return nil }
        return switch key {
        case .previousMessage: .navigate(.previous)
        case .nextMessage: .navigate(.next)
        case .firstMessage: .navigate(.first)
        case .lastMessage: .navigate(.last)
        case .scrollUp: .scroll(.up)
        case .scrollDown: .scroll(.down)
        }
    }

    /// The window's handler of a reader key: performs its action and returns
    /// `true` (consumed), or returns `false` while the reader keys do not
    /// act, so the key keeps its ordinary meaning.
    @MainActor
    static func handle(
        _ key: ZenReaderKey,
        isReaderOpen: Bool,
        selectedTab: ZenWindowTab,
        navigate: (ZenSharedChatReader.Navigation) -> Void,
        scroll: (ZenSharedChatScrollDirection) -> Void
    ) -> Bool {
        switch action(for: key, isReaderOpen: isReaderOpen, selectedTab: selectedTab) {
        case nil:
            return false
        case let .navigate(navigation)?:
            navigate(navigation)
        case let .scroll(direction)?:
            scroll(direction)
        }
        return true
    }

    // MARK: Menu

    /// The title of the Session menu item, after what a click does: it
    /// closes the reader only when it is open in the conversation; from a
    /// sub-agent tab it shows the conversation with the reader open.
    static func menuTitle(isReaderOpen: Bool, selectedTab: ZenWindowTab) -> String {
        consumesReaderKeys(isReaderOpen: isReaderOpen, selectedTab: selectedTab)
            ? "Hide Chat Reader"
            : "Show Chat Reader"
    }
}

/// The shared-chat panel of a window: nothing while hidden, otherwise one
/// glass card in the chrome's container. It reads the reader and the
/// participants in its own body. Its buttons never take the focus, so the
/// composer keeps it.
struct ZenSharedChatPanel: View {
    let session: ZenWindowSession
    let scroller: ZenSharedChatScroller
    /// The window's reader keys, for a focus inside the panel (the selected
    /// text of a message).
    let readerKey: @MainActor (ZenReaderKey) -> Bool

    @Environment(\.zenPalette) private var palette

    var body: some View {
        let state = ZenSharedChatPanelLogic.state(
            for: session.sharedChat,
            participants: session.sharedChatParticipants
        )
        if state != .hidden {
            card(state)
        }
    }

    private func card(_ state: ZenSharedChatPanelState) -> some View {
        let header = ZenSharedChatPanelLogic.header(for: state) ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            headerRow(state, header: header)
            if case let .message(message) = state {
                Text(verbatim: message.author)
                    .font(.callout)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                ZenSharedChatMessageText(message: message, scroller: scroller)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(palette.chatBorder.opacity(0.12)), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(palette.chatBorder.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onKeyPress(
            keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end],
            phases: [.down, .repeat]
        ) { press in
            guard let key = ZenComposerLogic.readerKey(for: press.key, modifiers: press.modifiers),
                  readerKey(key) else {
                return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chat messages"))
        .accessibilityValue(Text(header))
    }

    @ViewBuilder
    private func headerRow(_ state: ZenSharedChatPanelState, header: String) -> some View {
        let hint = ZenSharedChatPanelLogic.hint(for: state) ?? ""
        switch state {
        case .hidden:
            EmptyView()
        case .unread:
            // The whole row opens the reader.
            Button {
                session.toggleSharedChatReader()
            } label: {
                HStack(spacing: 8) {
                    title(header)
                    Spacer(minLength: 8)
                    hintText(hint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Read the chat messages (⌃Y)")
            .accessibilityLabel(Text("Read chat messages"))
            .accessibilityValue(Text(header))
        case .empty:
            HStack(spacing: 8) {
                title(header)
                Spacer(minLength: 8)
                hintText(hint)
                closeButton
            }
        case let .message(message):
            HStack(spacing: 8) {
                title(header)
                Spacer(minLength: 8)
                hintText(hint)
                navigationButton(
                    systemImage: "chevron.left",
                    label: "Previous message",
                    help: "Previous message (←)",
                    isEnabled: message.canShowPrevious,
                    navigation: .previous
                )
                navigationButton(
                    systemImage: "chevron.right",
                    label: "Next message",
                    help: "Next message (→)",
                    isEnabled: message.canShowNext,
                    navigation: .next
                )
                closeButton
            }
        }
    }

    private func title(_ header: String) -> some View {
        Text(verbatim: header)
            .font(.callout.weight(.semibold))
            .foregroundStyle(palette.chatTitle)
            .lineLimit(1)
    }

    private func hintText(_ hint: String) -> some View {
        Text(verbatim: hint)
            .font(.caption)
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
    }

    private func navigationButton(
        systemImage: String,
        label: String,
        help: String,
        isEnabled: Bool,
        navigation: ZenSharedChatReader.Navigation
    ) -> some View {
        Button {
            session.navigateSharedChat(navigation)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.chatTitle)
        .focusable(false)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(Text(label))
    }

    private var closeButton: some View {
        Button {
            session.toggleSharedChatReader()
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.textMuted)
        .focusable(false)
        .help("Close the chat reader (⌃Y)")
        .accessibilityLabel(Text("Close chat reader"))
    }
}

/// The text of the message shown: plain, selectable, in a scroll view that
/// shrinks to the text up to ``ZenSharedChatPanelLogic/maximumVisibleLines``.
/// It scrolls one line per request of the window's ↑/↓, and back to the top
/// for every other message.
private struct ZenSharedChatMessageText: View {
    let message: ZenSharedChatPanelMessage
    let scroller: ZenSharedChatScroller

    @Environment(\.zenPalette) private var palette
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 16
    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ZenSharedChatScrollMetrics()

    var body: some View {
        ScrollView(.vertical) {
            Text(verbatim: message.text)
                .font(.body)
                .foregroundStyle(palette.chatBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: ZenSharedChatPanelLogic.textHeight(contentHeight: metrics.contentHeight, lineHeight: lineHeight))
        .onScrollGeometryChange(for: ZenSharedChatScrollMetrics.self, of: ZenSharedChatScrollMetrics.init) { _, new in
            metrics = new
        }
        .onChange(of: message.id) { _, _ in
            position.scrollTo(edge: .top)
        }
        .onChange(of: scroller.request) { _, request in
            position.scrollTo(y: metrics.offset(scrolling: request.direction, lineHeight: lineHeight))
        }
    }
}
