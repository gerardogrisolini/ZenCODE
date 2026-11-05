//
//  TelegramChannelSelectionMenuTests.swift
//  ZenCODE
//
//  The `/sessions`, `/models`, `/think` and `/agents` selection menus of a
//  ``TelegramChannel``: the pure builders (token, tick mask, keyboards, the
//  64-byte callback data, the 90-entry cap, the `/agents` fallback), the
//  cards the commands send, the taps (stale menus, toggles edited in place,
//  applies run as the channel's task and refused while it is busy), and the
//  controller APIs the taps apply through, `chooseProjectAgents()`'s shared
//  answer included. The channel is linked by hand to chat 42, as in the
//  ingress tests: no control service is started, and the system messages,
//  menu cards and keyboard edits are recorded through the seams.
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
    func everyCallbackDataFitsTelegramsLimitAndListsShowAtMostNinetyEntries() throws {
        let longID = String(repeating: "x", count: 120)
        let many = ChatChoiceList(
            title: "Many",
            items: (0..<250).map {
                ChatChoiceItem(id: "\(longID)-\($0)", title: "Item \($0)", group: "Group")
            },
            selectedIDs: ["\(longID)-3"]
        )
        let agents = Self.agentChoices(count: 45, idSuffix: longID)
        let menus: [TelegramSelectionMenu] = [
            TelegramChannel.modelsMenu(many),
            TelegramChannel.thinkMenu(many, modelID: longID),
            TelegramChannel.agentPickerMenu(many),
            try #require(TelegramChannel.projectAgentsMenu(
                agents, ticks: Array(repeating: true, count: 45)
            )),
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

    @Test
    func theAgentsMenuFallsBackToThePickerBeyondTheLimit() throws {
        let three = Self.agentChoices(count: 3, idSuffix: "p")
        let menu = try #require(TelegramChannel.projectAgentsMenu(three, ticks: [true, false, false]))
        let token = TelegramChannel.selectionMenuToken(itemIDs: three.items.map(\.id))
        #expect(menu.keyboard == [
            [
                Button(text: "☑ Agent 0", callbackData: "zencode:agents:t:\(token):0"),
                Button(text: "● Active", callbackData: "zencode:agents:u:\(token):1:0"),
            ],
            [
                Button(text: "☐ Agent 1", callbackData: "zencode:agents:t:\(token):3"),
                Button(text: "Use", callbackData: "zencode:agents:u:\(token):1:1"),
            ],
            [
                Button(text: "☐ Agent 2", callbackData: "zencode:agents:t:\(token):5"),
                Button(text: "Use", callbackData: "zencode:agents:u:\(token):1:2"),
            ],
            [
                Button(text: "Save", callbackData: "zencode:agents:s:\(token):1"),
                Button(text: "Cancel", callbackData: "zencode:agents:x"),
            ],
        ])
        #expect(menu.text.hasPrefix("Agents\n☑ = associated with the project"))

        // 45 profiles take 90 buttons, the most a menu shows; 46 do not fit.
        #expect(TelegramChannel.projectAgentsMenu(
            Self.agentChoices(count: 45, idSuffix: "p"), ticks: Array(repeating: false, count: 45)
        )?.keyboard.count == 46)
        let crowd = Self.agentChoices(count: 46, idSuffix: "p")
        #expect(TelegramChannel.projectAgentsMenu(crowd, ticks: Array(repeating: false, count: 46)) == nil)
        // Ticks for another number of profiles are no menu either.
        #expect(TelegramChannel.projectAgentsMenu(three, ticks: [true]) == nil)
        let picker = TelegramChannel.agentPickerMenu(crowd)
        #expect(picker.keyboard.count == 46)
        #expect(picker.keyboard.allSatisfy {
            $0.count == 1 && $0[0].callbackData.hasPrefix("zencode:agents:p:")
        })
        #expect(picker.keyboard[0][0].text == "✓ Agent 0")
    }

    @Test
    func modelButtonsNameTheirProviderAndMarkTheCurrentModel() {
        let choices = ChatChoiceList(
            title: "Available models",
            items: [
                ChatChoiceItem(id: "a", title: "Alpha", group: "Local"),
                ChatChoiceItem(id: "b", title: "Beta"),
            ],
            selectedIDs: ["b"]
        )
        let token = TelegramChannel.selectionMenuToken(itemIDs: ["a", "b"])
        #expect(TelegramChannel.modelsMenu(choices) == TelegramSelectionMenu(
            text: "Available models\nTap the model to use for this session.",
            keyboard: [
                [Button(text: "Local · Alpha", callbackData: "zencode:models:\(token):0")],
                [Button(text: "✓ Beta", callbackData: "zencode:models:\(token):1")],
            ]
        ))
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
            let projectAgents = try controller.projectAgentChoices()
            let modelsMenu = TelegramChannel.modelsMenu(controller.modelChoices())
            #expect(pair.cards.values == [
                TelegramChannel.sessionsActionMenu(),
                modelsMenu,
                TelegramChannel.thinkMenu(thinking, modelID: Fixtures.beta.id),
                try #require(TelegramChannel.projectAgentsMenu(
                    projectAgents, ticks: TelegramChannel.projectAgentsInitialTicks(projectAgents)
                )),
                modelsMenu,
            ].map { MenuCard(text: $0.text, markup: $0.replyMarkup) })
            #expect(Self.keyboard(of: pair.cards.values[0]).joined().map(\.text) == [
                "Load", "New", "Save", "Compact", "Delete", "Restore checkpoint",
            ])
            // The level in effect is marked: Beta's default.
            #expect(Self.keyboard(of: pair.cards.values[2]).joined().map(\.text) == [
                "✓ \(AgentThinkingSelection.low.menuTitle)", AgentThinkingSelection.high.menuTitle,
            ])

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

    /// A tap on a menu whose entries changed, or whose data cannot be read,
    /// asks to run the command again and changes nothing.
    @Test
    func aStaleTapIsToldTheMenuIsOutOfDate() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-stale-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            let agentsToken = TelegramChannel.selectionMenuToken(
                itemIDs: try controller.projectAgentChoices().items.map(\.id)
            )
            let modelsToken = TelegramChannel.selectionMenuToken(
                itemIDs: controller.modelChoices().items.map(\.id)
            )
            let taps: [(data: String, command: String)] = [
                ("zencode:models:00000000:0", "models"),
                ("zencode:models:\(modelsToken):99", "models"),
                ("zencode:think:00000000:0", "think"),
                ("zencode:agents:t:00000000:0", "agents"),
                ("zencode:agents:u:\(agentsToken):zz:0", "agents"),
                ("zencode:agents:p:00000000:0", "agents"),
                ("zencode:agents:q", "agents"),
                ("zencode:sessions:l:00000000:0", "sessions"),
                ("zencode:sessions:a:bogus", "sessions"),
                ("zencode:sessions:r:00000000:0", "sessions"),
            ]
            for tap in taps {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: tap.data))))
            }
            #expect(pair.texts.values == taps.map {
                TelegramChannel.selectionMenuOutOfDateText(command: $0.command)
            })
            #expect(pair.texts.values.first == "ZenCODE: this menu is out of date. Run /models again.")
            #expect(pair.edits.values.isEmpty)
            #expect(pair.cards.values.isEmpty)
            #expect(channel.activeTurnTask == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A toggle re-ticks the keyboard of its own message and applies
    /// nothing; Save then applies the ticks, and Cancel removes the keyboard
    /// and names the selected agent, as the terminal's cancel.
    @Test
    func anAgentsToggleEditsItsKeyboardInPlaceAndSaveAppliesTheTicks() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-agents-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            _ = await channel.lineAction(for: "/agents", lease: pair.lease)
            let card = try #require(pair.cards.values.first)
            let rows = Self.keyboard(of: card)
            let choices = try controller.projectAgentChoices()
            #expect(choices.items.count >= 2)

            var ticks = TelegramChannel.projectAgentsInitialTicks(choices)
            ticks[1].toggle()
            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: rows[1][0].callbackData))))
            let edited = try #require(TelegramChannel.projectAgentsMenu(choices, ticks: ticks))
            #expect(pair.edits.values == [
                KeyboardEdit(markup: edited.replyMarkup, chatID: 42, messageID: Self.tappedMessageID),
            ])
            #expect(edited.keyboard[1][0].text != rows[1][0].text)
            #expect(pair.texts.values.isEmpty)
            #expect(channel.activeTurnTask == nil)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: pair.workspace) == nil)

            // Save, from the edited keyboard, applies the ticks as the
            // channel's task and keeps the active agent.
            let saveData = try #require(edited.keyboard.last?.first?.callbackData)
            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: saveData))))
            let task = try #require(channel.activeTurnTask)
            await task.value
            let associated = choices.items.indices.filter { ticks[$0] }.map { choices.items[$0].id }
            let expectedKeys = Set(try controller.availableAgents()
                .filter { associated.contains(ChatSessionController.agentChoiceID($0)) }
                .map(ProjectAgentSelectionStore.selectionKey(for:)))
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: pair.workspace) == expectedKeys)
            let agentName = try #require(controller.selection.agent?.displayName)
            #expect(pair.texts.values == ["ZenCODE: agent \(agentName) selected."])
            #expect(channel.activeTurnTask == nil)

            // Cancel removes the keyboard and names the selected agent.
            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:agents:x"))))
            #expect(pair.edits.values.last == KeyboardEdit(markup: nil, chatID: 42, messageID: Self.tappedMessageID))
            #expect(pair.texts.values.last == TelegramChannel.noticeText(.selectedAgent(controller.selection.agent)))
            #expect(channel.activeTurnTask == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A tap that applies a choice is refused with the busy text while a
    /// task of the channel runs or a prompt waits in its queue; a toggle and
    /// a tap that opens a list are not.
    @Test
    func anApplyingTapIsRefusedWhileTheChannelIsBusy() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-busy-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            let choices = try controller.projectAgentChoices()
            let menu = try #require(TelegramChannel.projectAgentsMenu(
                choices, ticks: TelegramChannel.projectAgentsInitialTicks(choices)
            ))
            let modelData = TelegramChannel.modelsMenu(controller.modelChoices()).keyboard[0][0].callbackData

            // A task of the channel runs.
            let hold = Self.holdQueue(of: channel)
            for data in [
                try #require(menu.keyboard.last?.first?.callbackData),
                menu.keyboard[0][1].callbackData,
                modelData,
                "zencode:sessions:a:new",
            ] {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: data))))
            }
            #expect(pair.texts.values == Array(repeating: TelegramChannel.busyMessageText, count: 4))
            #expect(channel.activeTurnTask == hold)
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: menu.keyboard[0][0].callbackData))
            #expect(pair.edits.values.count == 1)
            hold.cancel()
            channel.activeTurnTask = nil

            // A prompt waits in the queue.
            let queued = channel.promptQueue.enqueue(ChatQueuedPrompt(text: "waiting", origin: pair.lease))
            #expect(queued)
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:save"))
            #expect(pair.texts.values.count == 5)
            #expect(pair.texts.values.last == TelegramChannel.busyMessageText)
            #expect(channel.activeTurnTask == nil)
            // Opening a list is not a change.
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:load"))
            #expect(pair.texts.values.last == TelegramChannel.noticeText(.noSavedSessions))
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// While the session generates, the commands and every tap of their
    /// menus are told the session is busy.
    @Test
    func whileTheSessionGeneratesTheMenusAndTheirTapsAreBusy() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-generating-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            channel.onRunTurnForTesting = { prompt, _, _ in
                Issue.record("A busy session ran \(prompt)")
            }
            let reservation = try pair.terminal.sessionHost.reservePrompt(in: pair.terminal.terminalSlotID)
            #expect(channel.isSessionGenerating)
            let messages = ["/sessions", "/models", "/think", "/agents"].map { Self.ownerMessage($0) }
                + [
                    "zencode:models:00000000:0", "zencode:think:00000000:0",
                    "zencode:agents:t:00000000:0", "zencode:agents:x",
                    "zencode:sessions:a:load", "zencode:sessions:dx",
                ].map { Self.ownerMessage(callbackData: $0) }
            for message in messages {
                #expect(!(await channel.handleIncomingMessage(message)))
            }
            #expect(pair.texts.values == Array(repeating: TelegramChannel.busyMessageText, count: messages.count))
            #expect(pair.cards.values.isEmpty)
            #expect(pair.edits.values.isEmpty)
            #expect(channel.promptQueue.isEmpty)
            #expect(channel.activeTurnTask == nil)
            pair.terminal.sessionHost.releasePrompt(reservation)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// The `/sessions` actions: Save, Load, Restore and Delete answer as the
    /// terminal does, and the deletion list is ticked in place and deletes
    /// the ticked sessions.
    @Test
    func theSessionsMenuAppliesItsActionsAsTheTerminalDoes() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-sessions-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)

            // Save applies at once, as the channel's task.
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:save"))
            let save = try #require(channel.activeTurnTask)
            await save.value
            #expect(pair.texts.values == [TelegramChannel.noticeText(.nothingToSave)])
            // Without saved sessions, the lists say so.
            for action in ["load", "delete", "restore"] {
                _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:\(action)"))
            }
            #expect(pair.texts.values.dropFirst() == [
                TelegramChannel.noticeText(.noSavedSessions),
                TelegramChannel.noticeText(.noSavedSessions),
                TelegramChannel.noticeText(.noActiveSavedSession),
            ])
            #expect(pair.cards.values.isEmpty)

            try Self.saveSession(named: "first", in: pair.workspace, savedAt: 1_000)
            try Self.saveSession(named: "second", in: pair.workspace, savedAt: 2_000)
            let sessions = try controller.savedSessions()
            #expect(sessions.map(\.name) == ["second", "first"])

            // Load lists them, most recently saved first.
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:load"))
            #expect(Self.keyboard(of: try #require(pair.cards.values.last)).joined().map(\.text) == ["second", "first"])

            // Delete: nothing ticked, then the first entry ticked in place.
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:a:delete"))
            let deletion = Self.keyboard(of: try #require(pair.cards.values.last))
            #expect(deletion.joined().map(\.text) == ["☐ second", "☐ first", "Delete selected", "Cancel"])
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: deletion[2][0].callbackData))
            #expect(pair.texts.values.last == TelegramChannel.noSessionsSelectedText)
            #expect(channel.activeTurnTask == nil)
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: deletion[0][0].callbackData))
            let ticked = try #require(pair.edits.values.last?.markup.map { Self.keyboard(of: $0) })
            #expect(ticked.joined().map(\.text) == ["☑ second", "☐ first", "Delete selected", "Cancel"])
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: ticked[2][0].callbackData))
            let delete = try #require(channel.activeTurnTask)
            await delete.value
            #expect(pair.texts.values.last == TelegramChannel.noticeText(.sessionDeleted(name: "second")))
            #expect(try controller.savedSessions().map(\.name) == ["first"])
            // The list changed: the old deletion menu is out of date.
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: ticked[2][0].callbackData))
            #expect(pair.texts.values.last == TelegramChannel.selectionMenuOutOfDateText(command: "sessions"))
            // Cancel removes the keyboard and says nothing.
            let textCount = pair.texts.values.count
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: "zencode:sessions:dx"))
            #expect(pair.edits.values.last == KeyboardEdit(markup: nil, chatID: 42, messageID: Self.tappedMessageID))
            #expect(pair.texts.values.count == textCount)
            await pair.terminal.sessionHost.shutdown()
        }
    }

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
    /// workspace, with the hosted models Alpha and Beta (Beta current) and
    /// the default agent profiles, linked by hand to chat 42 on the route of
    /// `room`: no control service is started, and the system messages, the
    /// menu cards, and the keyboard edits are recorded through the seams.
    private static func linked(room: String) async throws -> Linked {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-menus-\(UUID().uuidString)", isDirectory: true
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

    /// Holds the channel: a task that never ends stands in for a task of the
    /// channel.
    private static func holdQueue(of channel: TelegramChannel) -> Task<Void, Never> {
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        channel.activeTurnTask = task
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

    /// Saves a session `name` of `workspace` to the store directly, as
    /// another process would.
    private static func saveSession(named name: String, in workspace: URL, savedAt: TimeInterval) throws {
        let date = Date(timeIntervalSince1970: savedAt)
        let history = [AgentRuntimeMessage(role: .user, content: "Prompt of \(name)")]
        _ = try TerminalSessionStore.save(TerminalSavedSession(
            name: name, sessionID: "saved-\(name)", cacheKey: nil,
            workingDirectoryPath: workspace.path, createdAt: date, savedAt: date,
            modelID: Fixtures.beta.id, agentID: nil, agentName: nil, selectedTools: [],
            selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "saved-\(name)")
        ))
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

    private var projectAgents: ChatTestCatalog {
        .hosted(agents: [Fixtures.developer, Fixtures.reviewer, Fixtures.reporter])
    }

    @Test
    func projectAgentsAnsweredByTheChannelApplyAsAConfirmedMenu() async throws {
        try await withChatHarness(catalog: projectAgents) { harness in
            let controller = harness.controller
            let hooks = RecordingChannelHooks(runtime: harness.runtime)
            controller.channelHooks = hooks
            try await harness.startSession(conversation: Fixtures.conversation)
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)

            // An unchanged association with the active agent kept names it.
            #expect(await controller.applyProjectAgentsSelection(associatedIDs: [developerID], activeID: nil)
                == ChatCommandOutcome(notices: [.selectedAgent(Fixtures.developer)]))
            #expect(hooks.steps.isEmpty)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace) == nil)

            // A changed association is saved, presented, and the prompt is
            // rebuilt in place; the channel's step follows.
            let changed = await controller.applyProjectAgentsSelection(
                associatedIDs: [developerID, reviewerID, "no-such-agent"], activeID: nil
            )
            #expect(changed == ChatCommandOutcome())
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace)
                == Set([Fixtures.developer, Fixtures.reviewer]
                    .map(ProjectAgentSelectionStore.selectionKey(for:))))
            #expect(await harness.presenter.notices == [
                .projectAgentsAssociated(
                    agents: [Fixtures.developer, Fixtures.reviewer],
                    projectName: harness.workspace.lastPathComponent
                ),
            ])
            #expect(await harness.callNames() == ["updateSessionOptions"])
            #expect(hooks.steps.count == 1)
            #expect(hooks.steps.first?.hasPrefix("selectionDidApply(") == true)
            #expect(hooks.steps.first?.contains(", agents) after ") == true)
            await harness.clearRecords()

            // Another active agent switches, keeping the saved association.
            #expect(await controller.applyProjectAgentsSelection(
                associatedIDs: [developerID, reviewerID], activeID: reviewerID
            ) == ChatCommandOutcome(notices: [.agentSwitched(Fixtures.reviewer)]))
            #expect(controller.selection.agent == Fixtures.reviewer)
            #expect(await harness.presenter.notices.isEmpty)

            // An unknown active agent is refused and changes nothing.
            #expect(await controller.applyProjectAgentsSelection(associatedIDs: [], activeID: "ghost")
                == ChatCommandOutcome(notices: [.operationFailed(description: "Unknown agent 'ghost'.")]))
            #expect(controller.selection.agent == Fixtures.reviewer)
        }
    }

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
