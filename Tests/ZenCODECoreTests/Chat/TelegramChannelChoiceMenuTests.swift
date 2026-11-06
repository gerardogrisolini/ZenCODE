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
//  service is started, and the system messages, menu cards and keyboard
//  edits are recorded through the seams.
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

    @Test
    func theChannelOffersSingleAndMultipleChoicesButNoFocusedOne() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-capabilities-\(UUID().uuidString)")
            defer { pair.remove() }
            #expect(pair.channel.capabilities == [
                .toolConsent, .textInput, .attachmentPicker, .singleChoice, .multipleChoice,
            ])
            #expect(!pair.channel.capabilities.contains(.focusedMultipleChoice))
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// The text lists the items under their group headings, then the
    /// instruction; a single choice marks the selected entry, a multiple
    /// choice ticks its entries and each toggle carries the flipped mask.
    @Test
    func theMenusListTheItemsUnderTheirGroups() {
        let one = TelegramChannel.chooseOneMenu(
            title: "Pick", items: Self.items, selectedIDs: ["resume:b"], token: "0123abcd"
        )
        #expect(one.text == """
            Pick

            Resume
            alpha — 2 pending
            beta

            Other actions
            Start fresh — leave it

            Tap an option.
            """)
        #expect(one.keyboard == [
            [Button(text: "alpha", callbackData: "zencode:choice:s:0123abcd:0")],
            [Button(text: "✓ beta", callbackData: "zencode:choice:s:0123abcd:1")],
            [Button(text: "Start fresh", callbackData: "zencode:choice:s:0123abcd:2")],
            [Button(text: "Cancel", callbackData: "zencode:choice:x:0123abcd")],
        ])

        let many = TelegramChannel.chooseManyMenu(
            title: "Pick", items: Self.items, ticks: [false, true, false], token: "0123abcd"
        )
        #expect(many.text.hasSuffix("Start fresh — leave it\n\nTap the entries to select, then Done."))
        #expect(many.keyboard == [
            [Button(text: "☐ alpha", callbackData: "zencode:choice:t:0123abcd:3")],
            [Button(text: "☑ beta", callbackData: "zencode:choice:t:0123abcd:0")],
            [Button(text: "☐ Start fresh", callbackData: "zencode:choice:t:0123abcd:6")],
            [
                Button(text: "Done", callbackData: "zencode:choice:c:0123abcd:2"),
                Button(text: "Cancel", callbackData: "zencode:choice:x:0123abcd"),
            ],
        ])

        // Ungrouped entries have no heading; the current one is marked.
        let plain = TelegramChannel.chooseOneMenu(
            title: "Models",
            items: [
                ChatChoiceItem(id: "a", title: "A"),
                ChatChoiceItem(id: "b", title: "B", detail: "fast", isCurrent: true),
            ],
            selectedIDs: [], token: "0123abcd"
        )
        #expect(plain.text == "Models\n\nA\nB — fast\n\nTap an option.")
        #expect(plain.keyboard.joined().map(\.text) == ["A", "✓ B", "Cancel"])
    }

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

    // MARK: - Single choice

    /// `chooseOne` sends the menu and waits; a tap answers the entry's ID and
    /// removes the keyboard of its message. The answered menu is out of date.
    @Test
    func aTapAnswersTheSingleChoiceAndRemovesTheKeyboard() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-one-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let task = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: "resume:a")
            }
            let card = try #require(pair.cards.values.first)
            #expect(card.text == TelegramChannel.choiceMenuText(
                title: "Pick", items: Self.items, instruction: "Tap an option."
            ))
            let rows = Self.keyboard(of: card)
            #expect(rows.joined().map(\.text) == ["✓ alpha", "beta", "Start fresh", "Cancel"])
            #expect(channel.pendingChoiceReader != nil)
            #expect(channel.hasPendingReader)

            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[2][0].callbackData))))
            #expect(await task.value == "fresh")
            #expect(channel.pendingChoiceReader == nil)
            #expect(pair.edits.values == [KeyboardEdit(markup: nil, chatID: 42, messageID: Self.tappedMessageID)])
            #expect(pair.texts.values.isEmpty)

            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[0][0].callbackData))
            #expect(pair.texts.values == [TelegramChannel.choiceMenuOutOfDateText])
            #expect(pair.texts.values == ["ZenCODE: this menu is out of date."])
            #expect(pair.edits.values.count == 1)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// Each request has its own token: a tap on the menu of an earlier
    /// request, or data the waiting menu does not have, is out of date and
    /// changes nothing; the menu keeps waiting for its own tap.
    @Test
    func aTapWithAStaleTokenIsRefusedAndTheMenuKeepsWaiting() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-stale-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let first = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            let firstRows = Self.keyboard(of: try #require(pair.cards.values.first))
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: firstRows[3][0].callbackData))
            #expect(await first.value == nil)

            let second = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            let secondRows = Self.keyboard(of: try #require(pair.cards.values.last))
            #expect(secondRows[0][0].callbackData != firstRows[0][0].callbackData)
            let token = String(secondRows[0][0].callbackData.split(separator: ":")[3])
            let stale = [
                firstRows[1][0].callbackData,
                firstRows[3][0].callbackData,
                "zencode:choice:s:\(token):99",
                "zencode:choice:t:\(token):0",
                "zencode:choice:c:\(token):0",
                "zencode:choice:x:\(token):1",
                "zencode:choice:q",
            ]
            for data in stale {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: data))))
            }
            #expect(pair.texts.values == Array(repeating: TelegramChannel.choiceMenuOutOfDateText, count: stale.count))
            #expect(pair.edits.values.count == 1)
            #expect(channel.pendingChoiceReader != nil)

            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: secondRows[1][0].callbackData))
            #expect(await second.value == "resume:b")
            #expect(pair.edits.values.count == 2)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// Cancel answers `nil` and removes the keyboard, in a single and in a
    /// multiple choice; nothing is said.
    @Test
    func cancelAnswersNilAndRemovesTheKeyboard() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-cancel-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let one = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            let oneRows = Self.keyboard(of: try #require(pair.cards.values.last))
            #expect(oneRows.last?.map(\.text) == ["Cancel"])
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: oneRows[3][0].callbackData))
            #expect(await one.value == nil)

            let many = try await Self.choosing(in: pair) {
                await $0.chooseMany(title: "Delete", items: Self.items, selectedIDs: ["fresh"])
            }
            let manyRows = Self.keyboard(of: try #require(pair.cards.values.last))
            #expect(manyRows.last?.map(\.text) == ["Done", "Cancel"])
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: manyRows[3][1].callbackData))
            #expect(await many.value == nil)

            #expect(pair.edits.values == Array(
                repeating: KeyboardEdit(markup: nil, chatID: 42, messageID: Self.tappedMessageID), count: 2
            ))
            #expect(pair.texts.values.isEmpty)
            #expect(channel.pendingChoiceReader == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Multiple choice

    /// `chooseMany` ticks its selected entries; each toggle edits the
    /// keyboard of the same message in place, and Done answers the ticked
    /// entries and removes the keyboard.
    @Test
    func theTicksAreEditedInPlaceAndDoneAnswersTheTickedEntries() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-many-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let task = try await Self.choosing(in: pair) {
                await $0.chooseMany(title: "Delete", items: Self.items, selectedIDs: ["resume:b"])
            }
            let card = try #require(pair.cards.values.first)
            #expect(card.text.hasSuffix("Tap the entries to select, then Done."))
            let rows = Self.keyboard(of: card)
            #expect(rows.joined().map(\.text) == ["☐ alpha", "☑ beta", "☐ Start fresh", "Done", "Cancel"])

            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[0][0].callbackData))
            let ticked = Self.keyboard(of: try #require(pair.edits.values.last?.markup))
            #expect(ticked.joined().map(\.text) == ["☑ alpha", "☑ beta", "☐ Start fresh", "Done", "Cancel"])
            #expect(pair.edits.values.last?.messageID == Self.tappedMessageID)
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: ticked[1][0].callbackData))
            let unticked = Self.keyboard(of: try #require(pair.edits.values.last?.markup))
            #expect(unticked.joined().map(\.text) == ["☑ alpha", "☐ beta", "☐ Start fresh", "Done", "Cancel"])
            #expect(channel.pendingChoiceReader != nil)
            #expect(pair.cards.values.count == 1)

            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: unticked[3][0].callbackData))
            #expect(await task.value == ["resume:a"])
            #expect(pair.edits.values.count == 3)
            #expect(pair.edits.values.last == KeyboardEdit(markup: nil, chatID: 42, messageID: Self.tappedMessageID))
            #expect(pair.texts.values.isEmpty)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - While a menu waits

    /// While a menu waits, a prompt, a remote command, or a menu command is
    /// asked to choose and runs nothing; once it is answered, a prompt runs
    /// again.
    @Test
    func aMessageWhileAMenuWaitsIsAskedToChooseAndStartsNoTurn() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-gate-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let prompts = TelegramTestRecorder<String>()
            channel.onRunTurnForTesting = { prompt, _, _ in
                prompts.append(prompt)
            }
            let task = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            let lines = ["Hello from the chat", "/status", "/models", "/start", "/plan"]
            for line in lines {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(line))))
            }
            #expect(pair.texts.values == Array(repeating: TelegramChannel.choicePendingText, count: lines.count))
            #expect(pair.texts.values.first == "Choose an option from the menu above.")
            #expect(prompts.values.isEmpty)
            #expect(channel.promptQueue.isEmpty)
            #expect(channel.activeTurnTask == nil)
            #expect(pair.cards.values.count == 1)
            #expect(channel.pendingChoiceReader != nil)

            let rows = Self.keyboard(of: try #require(pair.cards.values.first))
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[0][0].callbackData))
            #expect(await task.value == "resume:a")
            #expect(await channel.handleIncomingMessage(Self.ownerMessage("Hello from the chat")))
            try await Support.waitUntil { !prompts.values.isEmpty }
            #expect(prompts.values == ["Hello from the chat"])
            await channel.activeTurnTask?.value
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// While the session generates, a menu still takes its taps, before the
    /// busy gate, and the other messages are asked to choose.
    @Test
    func theTapsPassTheBusyGateWhileTheSessionGenerates() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-busy-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let reservation = try pair.terminal.sessionHost.reservePrompt(in: pair.terminal.terminalSlotID)
            #expect(channel.isSessionGenerating)
            let task = try await Self.choosing(in: pair) {
                await $0.chooseMany(title: "Delete", items: Self.items, selectedIDs: [])
            }
            let rows = Self.keyboard(of: try #require(pair.cards.values.first))
            _ = await channel.handleIncomingMessage(Self.ownerMessage("Hello"))
            #expect(pair.texts.values == [TelegramChannel.choicePendingText])
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[2][0].callbackData))
            let ticked = Self.keyboard(of: try #require(pair.edits.values.last?.markup))
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: ticked[3][0].callbackData))
            #expect(await task.value == ["fresh"])
            #expect(!pair.texts.values.contains(TelegramChannel.busyMessageText))
            pair.terminal.sessionHost.releasePrompt(reservation)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Refusals

    /// Cancelling the task that waits answers `nil`, and so does a channel
    /// that stops reading the chat (``TelegramChannel/cancelPendingReaders()``).
    @Test
    func cancellingTheWaitingTaskOrStoppingTheChannelAnswersNil() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "choice-cancelled-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let cancelled = try await Self.choosing(in: pair) {
                await $0.chooseOne(title: "Pick", items: Self.items, selectedID: nil)
            }
            cancelled.cancel()
            #expect(await cancelled.value == nil)
            #expect(channel.pendingChoiceReader == nil)

            let stopped = try await Self.choosing(in: pair) {
                await $0.chooseMany(title: "Delete", items: Self.items, selectedIDs: [])
            }
            channel.cancelPendingReaders()
            #expect(await stopped.value == nil)
            #expect(channel.pendingChoiceReader == nil)
            #expect(!channel.hasPendingReader)
            #expect(pair.edits.values.isEmpty)
            await pair.terminal.sessionHost.shutdown()
        }
    }

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
        let edits = TelegramTestRecorder<KeyboardEdit>()

        func remove() {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// A message with a reply markup, as the card seam receives it.
    private struct MenuCard: Equatable, Sendable {
        let text: String
        let markup: TerminalTelegramReplyMarkup
    }

    /// A keyboard edit, as the edit seam receives it.
    private struct KeyboardEdit: Equatable, Sendable {
        let markup: TerminalTelegramReplyMarkup?
        let chatID: Int64
        let messageID: Int
    }

    /// The Telegram channel of a terminal of session `room`, in a UUID-named
    /// workspace, linked by hand to chat 42 on the route of `room`: no
    /// control service is started, and the system messages, the menu cards,
    /// and the keyboard edits are recorded through the seams.
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
        let (texts, cards, edits, receipt) = (pair.texts, pair.cards, pair.edits, cardReceipt)
        channel.onTelegramSystemMessage = { text, _ in
            texts.append(text)
            return true
        }
        channel.onTelegramMentionPickerMessage = { text, _, markup in
            cards.append(MenuCard(text: text, markup: markup))
            return receipt
        }
        channel.onTelegramReplyMarkupEditForTesting = { markup, chatID, messageID in
            edits.append(KeyboardEdit(markup: markup, chatID: chatID, messageID: messageID))
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
