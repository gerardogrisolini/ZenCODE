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
//  and the system messages, menu cards and keyboard edits are recorded
//  through the seams.
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

    /// `/agents` is a single choice of the active agent, whatever the number
    /// of profiles: the callback data stays `zencode:agents:p:<token>:<index>`.
    @Test
    func theAgentsMenuIsASingleChoiceOfTheActiveAgent() {
        let three = Self.agentChoices(count: 3, idSuffix: "p")
        let token = TelegramChannel.selectionMenuToken(itemIDs: three.items.map(\.id))
        #expect(TelegramChannel.agentPickerMenu(three) == TelegramSelectionMenu(
            text: "Agents\nTap the agent to make active.",
            keyboard: [
                [Button(text: "✓ Agent 0", callbackData: "zencode:agents:p:\(token):0")],
                [Button(text: "Agent 1", callbackData: "zencode:agents:p:\(token):1")],
                [Button(text: "Agent 2", callbackData: "zencode:agents:p:\(token):2")],
            ]
        ))

        // A crowd of profiles shows the first 90 and says so.
        let crowd = Self.agentChoices(count: 120, idSuffix: String(repeating: "x", count: 120))
        let picker = TelegramChannel.agentPickerMenu(crowd)
        #expect(picker.keyboard.count == 90)
        #expect(picker.text == "Agents\nTap the agent to make active.\nShowing 90 of 120.")
        #expect(picker.keyboard.allSatisfy {
            $0.count == 1 && $0[0].callbackData.hasPrefix("zencode:agents:p:")
                && $0[0].callbackData.utf8.count <= 64
        })
        #expect(picker.keyboard[0][0].text == "✓ Agent 0")
        #expect(picker.keyboard[89][0].callbackData.hasSuffix(":89"))
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
                itemIDs: try controller.agentChoices().items.map(\.id)
            )
            let modelsToken = TelegramChannel.selectionMenuToken(
                itemIDs: controller.modelChoices().items.map(\.id)
            )
            let taps: [(data: String, command: String)] = [
                ("zencode:models:00000000:0", "models"),
                ("zencode:models:\(modelsToken):99", "models"),
                ("zencode:think:00000000:0", "think"),
                // The data of the former multiple-choice menu, whose token is
                // the current one, is out of date too.
                ("zencode:agents:t:\(agentsToken):0", "agents"),
                ("zencode:agents:u:\(agentsToken):1:0", "agents"),
                ("zencode:agents:s:\(agentsToken):1", "agents"),
                ("zencode:agents:x", "agents"),
                ("zencode:agents:p:00000000:0", "agents"),
                ("zencode:agents:p:\(agentsToken):99", "agents"),
                ("zencode:agents:p:\(agentsToken)", "agents"),
                ("zencode:agents:q", "agents"),
                ("zencode:agents:", "agents"),
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

    /// A tap on the `/agents` picker makes the agent it names the active one,
    /// as the channel's task: the keyboard is left alone, the association of
    /// the profiles with the project is not written, and the chat gets the
    /// switch notice, as for `/agents <name>`.
    @Test
    func anAgentsTapActivatesTheAgentAsTheChannelsTask() async throws {
        try await Support.withSupport {
            let runner = AgentCoreSessionRunner(
                backendFactory: { _, _ in MenuAgentStubBackend() },
                taskGraphStore: nil
            )
            let pair = try await Self.linked(
                room: "menus-agents-\(UUID().uuidString)", sessionRunner: runner, stdinIsTerminal: false
            )
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            try await pair.terminal.createCurrentSession(discoverExternalTools: false)
            _ = await channel.lineAction(for: "/agents", lease: pair.lease)
            let rows = Self.keyboard(of: try #require(pair.cards.values.first))
            let activeName = try #require(controller.selection.agent?.displayName)
            let other = try #require(rows.joined().first { !$0.text.hasPrefix("✓ ") })
            #expect(other.text != activeName)

            #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: other.callbackData))))
            let task = try #require(channel.activeTurnTask)
            await task.value
            let switched = try #require(controller.selection.agent)
            #expect(switched.displayName == other.text)
            #expect(pair.texts.values == [TelegramChannel.noticeText(.agentSwitched(switched))])
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: pair.workspace) == nil)
            #expect(pair.edits.values.isEmpty)
            #expect(channel.activeTurnTask == nil)
            await pair.terminal.sessionHost.shutdown()
        }
    }

    /// A tap that applies a choice is refused with the busy text while a
    /// task of the channel runs or a prompt waits in its queue; a toggle of
    /// the `/sessions` deletion list and a tap that opens a list are not.
    @Test
    func anApplyingTapIsRefusedWhileTheChannelIsBusy() async throws {
        try await Support.withSupport {
            let pair = try await Self.linked(room: "menus-busy-\(UUID().uuidString)")
            defer { pair.remove() }
            let channel = pair.channel
            let controller = try #require(channel.controller)
            let agentData = TelegramChannel.agentPickerMenu(try controller.agentChoices())
                .keyboard[0][0].callbackData
            let modelData = TelegramChannel.modelsMenu(controller.modelChoices()).keyboard[0][0].callbackData
            try Self.saveSession(named: "first", in: pair.workspace, savedAt: 1_000)
            let deletion = TelegramChannel.savedSessionChoices(
                try controller.savedSessions(), title: "Delete saved sessions", activeName: nil
            )
            let toggle = TelegramChannel.savedSessionsDeleteMenu(deletion, ticks: [false])
            let deleteTicked = TelegramChannel.savedSessionsDeleteMenu(deletion, ticks: [true])

            // A task of the channel runs.
            let hold = Self.holdQueue(of: channel)
            for data in [
                agentData,
                try #require(deleteTicked.keyboard.last?.first?.callbackData),
                modelData,
                "zencode:sessions:a:new",
            ] {
                #expect(!(await channel.handleIncomingMessage(Self.ownerMessage(callbackData: data))))
            }
            #expect(pair.texts.values == Array(repeating: TelegramChannel.busyMessageText, count: 4))
            #expect(channel.activeTurnTask == hold)
            _ = await channel.handleIncomingMessage(Self.ownerMessage(callbackData: toggle.keyboard[0][0].callbackData))
            #expect(pair.edits.values == [
                KeyboardEdit(markup: deleteTicked.replyMarkup, chatID: 42, messageID: Self.tappedMessageID),
            ])
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
            #expect(pair.texts.values.count == 5)
            #expect(Self.keyboard(of: try #require(pair.cards.values.last)).joined().map(\.text) == ["first"])
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
                    "zencode:agents:p:00000000:0", "zencode:sessions:dt:00000000:0",
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

/// A backend that accepts every session: an agent switch recreates the session
/// without a model.
private actor MenuAgentStubBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }
}
