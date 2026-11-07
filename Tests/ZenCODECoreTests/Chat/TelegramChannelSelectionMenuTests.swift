//
//  TelegramChannelSelectionMenuTests.swift
//  ZenCODE
//
//  The `/sessions`, `/models`, `/think` and `/agents` selection menus of a
//  ``TelegramChannel``: the pure builders (token, tick mask, keyboards, the
//  64-byte callback data, the 90-entry cap), the cards the commands send
//  (`/agents` is a single choice of the active agent, like `/models` and
//  `/think`), the taps (stale menus, the `/sessions` deletion list edited in
//  place, applies run as the channel's task and refused while it is busy),
//  and the controller APIs the taps apply through. The channel is linked by
//  hand to chat 42, as in the ingress tests: no control service is started,
//  and the system messages and menu cards are recorded through the seams.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel selection menus", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelSelectionMenuTests {
    private typealias Support = TelegramChannelTestSupport
    private typealias Fixtures = ChatTestFixtures
    private typealias Button = TerminalTelegramInlineKeyboardButton

    /// The receipt the card seam answers with.
    private static let cardReceipt = 91
    /// The message every recorded tap sits on (``ownerMessage(_:callbackData:)``).
    private static let tappedMessageID = 78

    // MARK: - Builders

    @Test
    func theTokenIsDeterministicAndFollowsTheEntries() {
        // FNV-1a (32 bits) reference values: the empty input and "a".
        #expect(TelegramChannel.selectionMenuToken(itemIDs: []) == "811c9dc5")
        #expect(TelegramChannel.selectionMenuToken(itemIDs: ["a"]) == "e40c292c")
        let token = TelegramChannel.selectionMenuToken(itemIDs: ["alpha", "beta"])
        #expect(token.count == 8)
        #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(token == TelegramChannel.selectionMenuToken(itemIDs: ["alpha", "beta"]))
        #expect(token != TelegramChannel.selectionMenuToken(itemIDs: ["beta", "alpha"]))
        #expect(token != TelegramChannel.selectionMenuToken(itemIDs: ["alpha", "beta", "gamma"]))
        #expect(token != TelegramChannel.selectionMenuToken(itemIDs: ["alpha", "beta"], context: "model"))
        #expect(TelegramChannel.selectionMenuToken(itemIDs: ["low"], context: "a")
            != TelegramChannel.selectionMenuToken(itemIDs: ["low"], context: "b"))
    }

    @Test
    func theMaskRoundTripsAndAToggleFlipsOneEntry() {
        #expect(TelegramChannel.selectionMenuMask([true, false, true]) == "5")
        #expect(TelegramChannel.selectionMenuMask([false, false, false, false, true]) == "01")
        #expect(TelegramChannel.selectionMenuTicks(mask: "f", count: 4) == [true, true, true, true])
        let ticks = (0..<45).map { $0 % 3 == 0 }
        let mask = TelegramChannel.selectionMenuMask(ticks)
        #expect(mask.count == 12)
        #expect(TelegramChannel.selectionMenuTicks(mask: mask, count: 45) == ticks)
        var flipped = ticks
        flipped[7].toggle()
        let flippedTicks = TelegramChannel.selectionMenuTicks(
            mask: TelegramChannel.selectionMenuMask(flipped), count: 45
        )
        #expect(flippedTicks.map { read in ticks.indices.filter { read[$0] != ticks[$0] } } == [7])
        // A mask that cannot be read names no ticks.
        #expect(TelegramChannel.selectionMenuTicks(mask: "5", count: 5) == nil)
        #expect(TelegramChannel.selectionMenuTicks(mask: "8", count: 3) == nil)
        #expect(TelegramChannel.selectionMenuTicks(mask: "A", count: 4) == nil)
        #expect(TelegramChannel.selectionMenuTicks(mask: "g", count: 4) == nil)
    }

    @Test
    func everyCallbackDataFitsTelegramsLimitAndListsShowAtMostNinetyEntries() {
        let longID = String(repeating: "x", count: 120)
        let many = ChatChoiceList(
            title: "Many",
            items: (0..<250).map {
                ChatChoiceItem(id: "\(longID)-\($0)", title: "Item \($0)", group: "Group")
            },
            selectedIDs: ["\(longID)-3"]
        )
        let menus: [TelegramSelectionMenu] = [
            TelegramChannel.modelsMenu(many),
            TelegramChannel.thinkMenu(many, modelID: longID),
            TelegramChannel.agentPickerMenu(many),
            TelegramChannel.sessionsActionMenu(),
            TelegramChannel.savedSessionsLoadMenu(many),
            TelegramChannel.savedSessionsDeleteMenu(many, ticks: Array(repeating: true, count: 90)),
            TelegramChannel.checkpointRestoreMenu(many, sessionName: longID),
        ]
        for menu in menus {
            let buttons = menu.keyboard.joined()
            #expect(buttons.count <= 100)
            for button in buttons {
                #expect(button.callbackData.utf8.count <= 64, "\(button.callbackData)")
                #expect(TelegramChannel.isSelectionMenuCallback(button.callbackData))
            }
        }

        // A long list shows its first 90 entries and says so.
        let models = TelegramChannel.modelsMenu(many)
        #expect(models.keyboard.count == 90)
        #expect(models.text == "Many\nTap the model to use for this session.\nShowing 90 of 250.")
        #expect(models.keyboard[0][0].callbackData.hasSuffix(":0"))
        #expect(models.keyboard[3][0].text == "✓ Group · Item 3")
        let delete = TelegramChannel.savedSessionsDeleteMenu(
            many, ticks: Array(repeating: false, count: 90)
        )
        #expect(delete.keyboard.count == 91)
        #expect(delete.text.hasSuffix("Showing 90 of 250."))
        // The checkpoint entries show the last 90, by their index in the tree.
        let restore = TelegramChannel.checkpointRestoreMenu(many, sessionName: "notes")
        #expect(restore.keyboard.count == 90)
        #expect(restore.keyboard[0][0].text == "Item 160")
        #expect(restore.keyboard[89][0].callbackData.hasSuffix(":249"))
        #expect(restore.text.hasSuffix("Showing 90 of 250."))
    }

    // MARK: - Commands

    /// Each command sends its menu, built from the controller's; arguments
    /// are refused, and the plain words stay prompts.
    @Test
    func eachCommandSendsItsMenu() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-commands-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            for line in ["/sessions", "/models", "/think", "/agents", "/models@zencode_bot"] {
                #expect(await channel.lineAction(for: line, lease: pair.lease) == .handled, "\(line)")
            }
            #expect(pair.texts.values.isEmpty)

            let thinking = try #require(try controller.thinkingChoices())
            let agentsMenu = TelegramChannel.agentPickerMenu(try controller.agentChoices())
            let modelsMenu = TelegramChannel.modelsMenu(controller.modelChoices())
            #expect(pair.cards.values == [
                TelegramChannel.sessionsActionMenu(),
                modelsMenu,
                TelegramChannel.thinkMenu(thinking, modelID: Fixtures.beta.id),
                agentsMenu,
                modelsMenu,
            ].map { MenuCard(text: $0.text, markup: $0.replyMarkup) })
            #expect(Self.keyboard(of: pair.cards.values[0]).joined().map(\.text) == [
                "Load", "New", "Save", "Compact", "Delete", "Restore checkpoint",
            ])
            // The level in effect is marked: Beta's default.
            #expect(Self.keyboard(of: pair.cards.values[2]).joined().map(\.text) == [
                "✓ \(AgentThinkingSelection.low.menuTitle)", AgentThinkingSelection.high.menuTitle,
            ])
            // `/agents` is a single choice of the active agent, one per profile.
            let agentButtons = Self.keyboard(of: pair.cards.values[3]).joined()
            let activeName = try #require(controller.selection.agent?.displayName)
            #expect(agentButtons.count == (try controller.agentChoices()).items.count)
            #expect(agentButtons.filter { $0.text.hasPrefix("✓ ") }.map(\.text) == ["✓ \(activeName)"])
            #expect(agentButtons.allSatisfy { $0.callbackData.hasPrefix("zencode:agents:p:") })

            #expect(await channel.lineAction(for: "/models x", lease: pair.lease) == .handled)
            #expect(await channel.lineAction(for: "/agents list", lease: pair.lease) == .handled)
            #expect(pair.texts.values == [
                "ZenCODE: /models does not accept arguments.",
                "ZenCODE: /agents does not accept arguments.",
            ])
            #expect(await channel.lineAction(for: "models", lease: pair.lease) == .runPrompt("models"))
            #expect(await channel.lineAction(for: "agents", lease: pair.lease) == .runPrompt("agents"))
            #expect(pair.cards.values.count == 5)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Taps

    /// A `/think` tap applies the level through the controller.
    @Test
    func aThinkingTapAppliesTheLevel() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-think-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            _ = await channel.lineAction(for: "/think", lease: pair.lease)
            let rows = Self.keyboard(of: try #require(pair.cards.values.first))
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[1][0].callbackData))
            let task = try #require(channel.activeTurnTask)
            await task.value
            #expect(controller.selection.thinkingOverride == .high)
            // The level only updates the session: the chat gets the confirmation.
            #expect(pair.texts.values == ["ZenCODE: thinking set to \(AgentThinkingSelection.high.menuTitle)."])
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
    /// workspace, with the hosted models Alpha and Beta (Beta current) and
    /// the default agent profiles, linked by hand to chat 42 on the route of
    /// `room`: no control service is started, and the system messages and
    /// the menu cards are recorded through the seams.
    /// A test that switches the agent gives the `sessionRunner` that recreates
    /// the session and a terminal without `stdinIsTerminal`, which asks no
    /// question about the folder.
    private static func linked(
        room: String,
        sessionRunner: AgentCoreSessionRunner? = nil,
        stdinIsTerminal: Bool = true
    ) async throws -> Linked {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-menus-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let terminal = try Support.makeTerminal(
            transport: TelegramChannelTestTransport(botID: 1),
            sessionRunner: sessionRunner,
            workingDirectory: workspace,
            hostedModelID: Fixtures.beta.id,
            availableModels: Fixtures.hostedModels,
            stdinIsTerminal: stdinIsTerminal
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

    /// The rows of the inline keyboard of `card`.
    private static func keyboard(of card: MenuCard) -> [[Button]] {
        keyboard(of: card.markup)
    }

    private static func keyboard(of markup: TerminalTelegramReplyMarkup) -> [[Button]] {
        guard case let .inlineKeyboard(rows) = markup else { return [] }
        return rows
    }

    /// `count` agent entries `Agent <n>` with IDs ending in `idSuffix`, the
    /// first one current, none associated.
    private static func agentChoices(count: Int, idSuffix: String) -> ChatChoiceList {
        ChatChoiceList(
            title: "Agents",
            items: (0..<count).map {
                ChatChoiceItem(id: "agent-\($0)-\(idSuffix)", title: "Agent \($0)", isCurrent: $0 == 0)
            }
        )
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

// MARK: - Controller APIs

/// The controller APIs a channel that presents the selection menus itself
/// applies the choices through, against the answers of the terminal's menus.
@Suite("Chat session channel-presented selections", .serialized)
struct ChatSessionChannelSelectionTests {
    private typealias Fixtures = ChatTestFixtures

    @Test
    func modelThinkingAgentAndSavedSessionSelectionsApplyThroughTheController() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession()

            // Alpha, the current model, has no configurable thinking.
            #expect(await controller.applyThinkingSelection(id: "high")
                == ChatCommandOutcome(notices: [.thinkingNotSupported(model: Fixtures.alpha)]))
            #expect(await controller.applyModelSelection(id: "missing")
                == ChatCommandOutcome(notices: [.operationFailed(description: "Unknown model 'missing'.")]))
            #expect(await controller.applyModelSelection(id: Fixtures.beta.id) == ChatCommandOutcome())
            #expect(controller.currentEffectiveModelID() == Fixtures.beta.id)
            #expect(try controller.thinkingMenuModelID() == Fixtures.beta.id)

            #expect(await controller.applyThinkingSelection(id: "high") == ChatCommandOutcome())
            #expect(controller.selection.thinkingOverride == .high)
            #expect(await controller.applyThinkingSelection(id: "max") == ChatCommandOutcome(notices: [
                .operationFailed(description: "Unknown thinking level 'max'."),
            ]))
            #expect(controller.selection.thinkingOverride == .high)

            #expect(await controller.applyAgentSelection(id: ChatSessionController.agentChoiceID(Fixtures.reviewer))
                == ChatCommandOutcome(notices: [.agentSwitched(Fixtures.reviewer)]))
            #expect(await controller.applyAgentSelection(id: "ghost")
                == ChatCommandOutcome(notices: [.operationFailed(description: "Unknown agent 'ghost'.")]))

            #expect(await controller.loadSavedSessionSelection(named: "missing")
                == ChatCommandOutcome(notices: [.savedSessionNotFound(name: "missing")]))
            #expect(try controller.checkpointEntryMenu() == .unavailable(.noActiveSavedSession))
        }
    }
}

// MARK: - Backend
