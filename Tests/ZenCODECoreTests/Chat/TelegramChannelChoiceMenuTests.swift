//
//  TelegramChannelChoiceMenuTests.swift
//  ZenCODE
//
//  The generic menus of a ``TelegramChannel`` (`chooseOne`, `chooseMany`):
//  the pure builders (the text with its group headings, the keyboards, the
//  64-byte callback data, the 90-entry cap) and the reading of a tap, then
//  the menus asked in the chat: a tap answers and removes the keyboard, a tap
//  on the menu of an earlier request is out of date while the menu keeps
//  waiting, Cancel answers `nil`, the ticks of a multiple choice are edited in
//  place and Done answers the ticked items, any other message is asked to
//  choose and runs nothing, the taps pass the busy gate, and a cancelled
//  request or a channel that stops reading answers `nil`. The channel is
//  linked by hand to chat 42, as in the selection-menu tests: no control
//  service is started, and the system messages and menu cards are recorded
//  through the seams.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel choice menus", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelChoiceMenuTests {
    private typealias Support = TelegramChannelTestSupport
    private typealias Fixtures = ChatTestFixtures
    private typealias Button = TerminalTelegramInlineKeyboardButton

    /// The receipt the card seam answers with.
    private static let cardReceipt = 91
    /// The message every recorded tap sits on (``ownerMessage(_:callbackData:)``).
    private static let tappedMessageID = 78

    /// Two grouped entries to resume, one without detail, then one more.
    private static let items = [
        ChatChoiceItem(id: "resume:a", title: "alpha", detail: "2 pending", group: "Resume"),
        ChatChoiceItem(id: "resume:b", title: "beta", group: "Resume"),
        ChatChoiceItem(id: "fresh", title: "Start fresh", detail: "leave it", group: "Other actions"),
    ]

    // MARK: - Builders

    /// A long list shows its first 90 entries and says so, and every
    /// callback data fits in Telegram's 64 bytes, with its own prefix.
    @Test
    func everyCallbackDataFitsTelegramsLimitAndListsShowAtMostNinetyEntries() {
        let items = (0 ..< 250).map {
            ChatChoiceItem(id: "item-\($0)", title: "Item \($0)", isCurrent: $0 == 3)
        }
        let token = TelegramChannel.selectionMenuToken(
            itemIDs: items.map(\.id), context: UUID().uuidString
        )
        let one = TelegramChannel.chooseOneMenu(title: "Many", items: items, selectedIDs: [], token: token)
        let many = TelegramChannel.chooseManyMenu(
            title: "Many", items: items, ticks: Array(repeating: true, count: 90), token: token
        )
        #expect(one.keyboard.count == 91)
        #expect(many.keyboard.count == 91)
        #expect(one.keyboard[3][0].text == "✓ Item 3")
        #expect(one.keyboard[89][0].callbackData.hasSuffix(":89"))
        #expect(one.text.hasSuffix("Item 89\n\nTap an option.\nShowing 90 of 250."))
        #expect(many.text.hasSuffix("Showing 90 of 250."))
        for button in (one.keyboard + many.keyboard).joined() {
            #expect(button.callbackData.utf8.count <= TelegramChannel.selectionMenuCallbackDataLimit)
            #expect(button.callbackData.hasPrefix(TelegramChannel.choiceMenuCallbackPrefix))
            #expect(!TelegramChannel.isSelectionMenuCallback(button.callbackData))
        }
    }

    /// A tap is read against the waiting menu: its token, its kind, the
    /// index or the mask of its shown entries. Done keeps the selected
    /// entries the menu could not show.
    @Test
    func aTapIsReadAgainstTheWaitingMenu() {
        func tap(_ data: String, multiple: Bool, items: [ChatChoiceItem] = Self.items,
                 selected: Set<String> = []) -> TelegramChoiceMenuTap? {
            TelegramChannel.choiceMenuTap(
                TelegramChannel.selectionMenuFields(data, prefix: "zencode:choice:") ?? [],
                items: items, isMultipleChoice: multiple, selectedIDs: selected, token: "0123abcd"
            )
        }
        #expect(tap("zencode:choice:s:0123abcd:2", multiple: false) == .choose(["fresh"]))
        #expect(tap("zencode:choice:x:0123abcd", multiple: false) == .cancel)
        #expect(tap("zencode:choice:x:0123abcd", multiple: true) == .cancel)
        #expect(tap("zencode:choice:t:0123abcd:5", multiple: true) == .retick([true, false, true]))
        #expect(tap("zencode:choice:c:0123abcd:3", multiple: true) == .choose(["resume:a", "resume:b"]))
        #expect(tap("zencode:choice:c:0123abcd:0", multiple: true) == .choose([]))
        for stale in [
            "zencode:choice:s:00000000:0", "zencode:choice:s:0123abcd:3", "zencode:choice:s:0123abcd",
            "zencode:choice:t:0123abcd:0", "zencode:choice:c:0123abcd:1",
            "zencode:choice:x:0123abcd:1", "zencode:choice:x", "zencode:choice:", "zencode:choice:q:0123abcd",
        ] {
            #expect(tap(stale, multiple: false) == nil, "\(stale)")
        }
        for stale in [
            "zencode:choice:s:0123abcd:0", "zencode:choice:t:0123abcd:8", "zencode:choice:c:0123abcd:00",
            "zencode:choice:t:00000000:0", "zencode:choice:c:0123abcd:A",
        ] {
            #expect(tap(stale, multiple: true) == nil, "\(stale)")
        }

        let long = (0 ..< 95).map { ChatChoiceItem(id: "item-\($0)", title: "Item \($0)") }
        let firstTicked = TelegramChannel.selectionMenuMask([true] + Array(repeating: false, count: 89))
        #expect(tap(
            "zencode:choice:c:0123abcd:\(firstTicked)", multiple: true, items: long,
            selected: ["item-1", "item-92"]
        ) == .choose(["item-0", "item-92"]))
    }

    // MARK: - Refusals

    /// One menu at a time: a request while another waits is refused at once
    /// and sends nothing; so is a request without a route to the chat, or
    /// without entries.
    @Test
    func aRequestIsRefusedWhileAnotherWaitsOrWithoutARoute() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-refused-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            #expect(await channel.chooseOne(title: "Empty", items: [], selectedID: nil) == nil)
            #expect(await channel.chooseMany(title: "Empty", items: [], selectedIDs: []) == nil)
            #expect(pair.cards.values.isEmpty)

            let waiting = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            #expect(await channel.chooseOne(title: "Other", items: Self.items, selectedID: nil) == nil)
            #expect(await channel.chooseMany(title: "Other", items: Self.items, selectedIDs: []) == nil)
            #expect(pair.cards.values.count == 1)
            let rows = Self.keyboard(of: try #require(pair.cards.values.first))
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[1][0].callbackData))
            #expect(await waiting.value == "resume:b")

            let lease = channel.activeRouteLease
            channel.activeRouteLease = nil
            #expect(await channel.chooseOne(title: "Pick", items: Self.items, selectedID: nil) == nil)
            channel.activeRouteLease = lease
            channel.controlState.isActive = false
            #expect(await channel.chooseMany(title: "Pick", items: Self.items, selectedIDs: []) == nil)
            #expect(pair.cards.values.count == 1)
            #expect(channel.pendingChoiceReader == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    private struct Linked {
        let terminal: TerminalChat
        let channel: TelegramChannel
        let lease: TerminalTelegramRouteLease
        let workspace: URL
        let texts = TelegramTestRecorder<String>()
        let cards = TelegramTestRecorder<MenuCard>()

        func remove() {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// A message with a reply markup, as the card seam receives it.
    private struct MenuCard: Equatable, Sendable {
        let text: String
        let markup: TerminalTelegramReplyMarkup
    }

    /// The Telegram channel of a terminal of session `room`, in a UUID-named
    /// workspace, linked by hand to chat 42 on the route of `room`: no
    /// control service is started, and the system messages and the menu
    /// cards are recorded through the seams.
    private static func linked(room: String) async throws -> Linked {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-choices-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let terminal = try Support.makeTerminal(
            transport: TelegramChannelTestTransport(botID: 1),
            workingDirectory: workspace,
            hostedModelID: Fixtures.beta.id,
            availableModels: Fixtures.hostedModels
        )
        terminal.sessionID = room
        let channel = terminal.telegramChannel
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: nil, roomID: room),
            generation: 1,
            effectiveMessageThreadID: nil
        )
        await channel.router.refresh(
            linkedChatID: 42, ownerUserID: 7,
            routes: [AgentTelegramRouteManifest(roomID: room, generation: 1)]
        )
        channel.linkedChatID = 42
        channel.linkedUserID = 7
        channel.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID()
        )
        channel.activeRouteLease = lease
        let pair = Linked(terminal: terminal, channel: channel, lease: lease, workspace: workspace)
        let (texts, cards, receipt) = (pair.texts, pair.cards, cardReceipt)
        channel.onTelegramSystemMessage = { text, _ in
            texts.append(text)
            return true
        }
        channel.onTelegramMentionPickerMessage = { text, _, markup in
            cards.append(MenuCard(text: text, markup: markup))
            return receipt
        }
        return pair
    }

    /// Starts `request` on the channel of `pair` in a task of its own and
    /// returns the task once the menu it asks for reached the chat.
    private static func choosing<Answer: Sendable>(
        in pair: Linked,
        _ request: @escaping @Sendable @ChatSessionActor (TelegramChannel) async -> Answer
    ) async throws -> Task<Answer, Never> {
        let channel = pair.channel
        let cards = pair.cards
        let sent = cards.values.count
        let task = Task { @ChatSessionActor in
            await request(channel)
        }
        try await Support.waitUntil { cards.values.count > sent }
        try #require(cards.values.count > sent)
        return task
    }

    /// The rows of the inline keyboard of `card`.
    private static func keyboard(of card: MenuCard) -> [[Button]] {
        keyboard(of: card.markup)
    }

    private static func keyboard(of markup: TerminalTelegramReplyMarkup) -> [[Button]] {
        guard case let .inlineKeyboard(rows) = markup else { return [] }
        return rows
    }

    /// A tap of the owner in chat 42 on the message ``tappedMessageID``, or a
    /// text line when `text` is given.
    private static func ownerMessage(
        _ text: String? = nil,
        callbackData: String? = nil
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, topicID: nil, chatKind: .privateChat,
            text: text, voice: nil, messageID: tappedMessageID, chatTitle: "Test", username: "operator",
            replyToMessageID: nil,
            callbackQueryID: callbackData.map { _ in "callback-1" }, callbackData: callbackData,
            stoppedMessageGenerationDraftID: nil, attachment: nil
        )
    }
}
