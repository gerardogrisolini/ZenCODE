//
//  TelegramChannel+SelectionMenus.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

import Foundation
import ToolCore

/// One selection menu as the chat shows it: the text of its message and its
/// inline keyboard.
struct TelegramSelectionMenu: Sendable, Equatable {
    let text: String
    let keyboard: [[TerminalTelegramInlineKeyboardButton]]

    var replyMarkup: TerminalTelegramReplyMarkup {
        .inlineKeyboard(keyboard)
    }
}

/// What the tap of a selection menu applies to the session, as a task of
/// the channel (``TelegramChannel/startSelectionMenuApply(_:lease:)``).
enum TelegramSelectionMenuApply: Sendable, Equatable {
    /// `/models`: the model `id`, whose menu entry reads `title`.
    case model(id: String, title: String)
    /// `/think`: the level `id`, whose menu entry reads `title`.
    case thinking(id: String, title: String)
    /// `/agents`: the agent `id`, which becomes the active agent.
    case agent(id: String)
    /// `/sessions` Load: the saved session `name`.
    case loadSavedSession(name: String)
    /// `/sessions` Delete: the saved sessions `names`.
    case deleteSavedSessions(names: Set<String>)
    /// `/sessions` New, Save, Compact, Restore: the `/sessions` line the
    /// shared dispatcher runs.
    case sessionsCommand(String)
}

/// The `/models`, `/think` and `/agents` selection menus (the `/sessions`
/// menus are in `TelegramChannel+SessionsMenu.swift`).
///
/// The menus are stateless, like the `/chat` picker: the command sends a
/// keyboard built from the controller's menu, and a tap is a callback the
/// ingress hands to ``handleSelectionMenuCallback(_:chatID:messageID:lease:)``,
/// which rebuilds the menu from the controller and applies the choice through
/// the controller's APIs. The callback data, at most
/// ``selectionMenuCallbackDataLimit`` bytes, names an entry by its index and
/// carries the menu's token (``selectionMenuToken(itemIDs:context:)``), so a
/// tap on a menu whose entries changed since it was sent is refused with
/// ``selectionMenuOutOfDateText(command:)``. A multiple choice (the sessions
/// to delete) carries its ticks as a hex mask (``selectionMenuMask(_:)``): a
/// toggle carries the flipped mask and edits the keyboard of its own message
/// in place.
///
/// Nothing runs while the session generates: the ingress answers the commands
/// and the taps with ``busyMessageText``. A tap that applies a choice runs as
/// the channel's task, so it waits for nothing and is refused with the same
/// text while a task of the channel runs or a prompt waits in its queue.
extension TelegramChannel {
    // MARK: - Callback data

    /// The callback data prefix of a `/models` button.
    nonisolated static let modelsMenuCallbackPrefix = "zencode:models:"
    /// The callback data prefix of a `/think` button.
    nonisolated static let thinkMenuCallbackPrefix = "zencode:think:"
    /// The callback data prefix of an `/agents` button.
    nonisolated static let agentsMenuCallbackPrefix = "zencode:agents:"
    /// The callback data prefix of a `/sessions` button.
    nonisolated static let sessionsMenuCallbackPrefix = "zencode:sessions:"

    /// Telegram's limit on the callback data of a button, in UTF-8 bytes.
    nonisolated static let selectionMenuCallbackDataLimit = 64
    /// The most entry buttons a menu shows; a longer list shows a part of
    /// its entries and says so.
    nonisolated static let selectionMenuItemLimit = 90

    /// Whether `data` is the callback data of a selection menu.
    nonisolated static func isSelectionMenuCallback(_ data: String) -> Bool {
        [
            modelsMenuCallbackPrefix, thinkMenuCallbackPrefix,
            agentsMenuCallbackPrefix, sessionsMenuCallbackPrefix,
        ].contains { data.hasPrefix($0) }
    }

    /// The answer to the tap of a menu whose entries changed since it was
    /// sent, or whose data cannot be read.
    nonisolated static func selectionMenuOutOfDateText(command: String) -> String {
        "ZenCODE: this menu is out of date. Run /\(command) again."
    }

    /// The token of a menu: FNV-1a (32 bits) over `context`, when given, and
    /// the IDs of its entries, in order, joined by newlines, as eight
    /// lowercase hex digits. Deterministic across processes, unlike `Hasher`.
    nonisolated static func selectionMenuToken(itemIDs: [String], context: String? = nil) -> String {
        let source = (context.map { [$0] } ?? []) + itemIDs
        var hash: UInt32 = 2_166_136_261
        for byte in source.joined(separator: "\n").utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    /// The ticks of a multiple choice as a hex mask: entry `i` is bit
    /// `i % 4` of the hex digit `i / 4`, so `count` entries take
    /// `(count + 3) / 4` digits.
    nonisolated static func selectionMenuMask(_ ticks: [Bool]) -> String {
        stride(from: 0, to: ticks.count, by: 4).map { start in
            var nibble = 0
            for offset in 0..<4 where start + offset < ticks.count && ticks[start + offset] {
                nibble |= 1 << offset
            }
            return String(nibble, radix: 16)
        }.joined()
    }

    /// The ticks of `count` entries `mask` encodes
    /// (``selectionMenuMask(_:)``); `nil` for a mask of another length, a
    /// character that is not a lowercase hex digit, or a tick beyond `count`.
    nonisolated static func selectionMenuTicks(mask: String, count: Int) -> [Bool]? {
        let digits = Array(mask)
        guard count >= 0, digits.count == (count + 3) / 4 else { return nil }
        var ticks: [Bool] = []
        for digit in digits {
            guard digit.isASCII, digit.isHexDigit, !digit.isUppercase,
                  let nibble = Int(String(digit), radix: 16) else { return nil }
            for offset in 0..<4 {
                ticks.append(nibble & (1 << offset) != 0)
            }
        }
        guard !ticks[count...].contains(true) else { return nil }
        return Array(ticks[..<count])
    }

    /// The indices a menu of `count` entries shows: the first
    /// ``selectionMenuItemLimit``, or the last ones when `showsLast`.
    nonisolated static func selectionMenuVisibleIndices(count: Int, showsLast: Bool = false) -> Range<Int> {
        let shown = min(count, selectionMenuItemLimit)
        return showsLast ? (count - shown)..<count : 0..<shown
    }

    /// The fields after `prefix` in `data`, split on colons; `nil` when the
    /// data has another prefix.
    nonisolated static func selectionMenuFields(_ data: String, prefix: String) -> [String]? {
        guard data.hasPrefix(prefix) else { return nil }
        return data.dropFirst(prefix.count)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// The entry index `field` names among `count` entries.
    nonisolated static func selectionMenuIndex(_ field: String, count: Int) -> Int? {
        guard field.allSatisfy(\.isASCII), let index = Int(field),
              (0..<count).contains(index) else { return nil }
        return index
    }

    /// The message text of a menu: its title, the instruction, and how many
    /// of its entries it shows when it cannot show them all.
    nonisolated static func selectionMenuText(
        title: String, instruction: String, shown: Int, total: Int
    ) -> String {
        var lines = [title, instruction]
        if shown < total {
            lines.append("Showing \(shown) of \(total).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Single choice

    /// A single-choice menu of `choices`: one button per shown entry (see
    /// ``selectionMenuVisibleIndices(count:showsLast:)``), whose data is
    /// `callbackPrefix`, the menu's `token`, a colon, and the entry's index;
    /// the selected or current entry is marked with a leading check.
    nonisolated static func singleChoiceMenu(
        _ choices: ChatChoiceList,
        instruction: String,
        callbackPrefix: String,
        token: String,
        showsLast: Bool = false,
        buttonTitle: (ChatChoiceItem) -> String = \.title
    ) -> TelegramSelectionMenu {
        let indices = selectionMenuVisibleIndices(count: choices.items.count, showsLast: showsLast)
        let keyboard = indices.map { index in
            let item = choices.items[index]
            let isMarked = choices.selectedIDs.contains(item.id) || item.isCurrent
            return [TerminalTelegramInlineKeyboardButton(
                text: (isMarked ? "✓ " : "") + buttonTitle(item),
                callbackData: "\(callbackPrefix)\(token):\(index)"
            )]
        }
        return TelegramSelectionMenu(
            text: selectionMenuText(
                title: choices.title, instruction: instruction,
                shown: indices.count, total: choices.items.count
            ),
            keyboard: keyboard
        )
    }

    /// The entry of `choices` the fields `[token, index]` of a single-choice
    /// tap name, when `token` is still the menu's.
    nonisolated static func singleChoiceTapItem(
        _ fields: some Collection<String>,
        choices: ChatChoiceList,
        token: String
    ) -> ChatChoiceItem? {
        let fields = Array(fields)
        guard fields.count == 2, fields[0] == token,
              let index = selectionMenuIndex(fields[1], count: choices.items.count) else {
            return nil
        }
        return choices.items[index]
    }

    // MARK: - /models

    /// The `/models` menu of `choices` (``ChatSessionController/modelChoices()``):
    /// each model reads `<provider> · <title>`.
    nonisolated static func modelsMenu(_ choices: ChatChoiceList) -> TelegramSelectionMenu {
        singleChoiceMenu(
            choices,
            instruction: "Tap the model to use for this session.",
            callbackPrefix: modelsMenuCallbackPrefix,
            token: selectionMenuToken(itemIDs: choices.items.map(\.id)),
            buttonTitle: modelMenuButtonTitle
        )
    }

    /// The title of a model's button: its provider group, when it has one,
    /// then its title.
    nonisolated static func modelMenuButtonTitle(_ item: ChatChoiceItem) -> String {
        item.group.map { "\($0) · \(item.title)" } ?? item.title
    }

    /// The answer to `/models` without any configured model.
    nonisolated static var noConfiguredModelsText: String {
        noticeText(.operationFailed(description: TerminalChatError.noConfiguredModels.localizedDescription))
    }

    /// `/models`: sends the model menu, or says no model is configured.
    func handleModelsMenuRequest(lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        let choices = controller.modelChoices()
        guard !choices.items.isEmpty else {
            await sendSystemMessageIfLinked(Self.noConfiguredModelsText, lease: lease)
            return
        }
        await sendSelectionMenu(Self.modelsMenu(choices), lease: lease)
    }

    /// A `/models` tap (`<token>:<index>`): applies the model it names.
    private func handleModelsMenuCallback(_ fields: [String], lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        let choices = controller.modelChoices()
        let token = Self.selectionMenuToken(itemIDs: choices.items.map(\.id))
        guard let item = Self.singleChoiceTapItem(fields, choices: choices, token: token) else {
            await sendSelectionMenuOutOfDate(command: "models", lease: lease)
            return
        }
        await startSelectionMenuApply(.model(id: item.id, title: item.title), lease: lease)
    }

    // MARK: - /think

    /// The `/think` menu of `choices`, the levels of the model `modelID`.
    nonisolated static func thinkMenu(_ choices: ChatChoiceList, modelID: String) -> TelegramSelectionMenu {
        singleChoiceMenu(
            choices,
            instruction: "Tap the thinking level to use.",
            callbackPrefix: thinkMenuCallbackPrefix,
            token: selectionMenuToken(itemIDs: choices.items.map(\.id), context: modelID)
        )
    }

    /// The thinking menu of the current model with that model's ID; `nil`
    /// when there is none.
    private func currentThinkMenu(
        _ controller: ChatSessionController
    ) -> (choices: ChatChoiceList, modelID: String)? {
        guard case let .available(choices)? = try? controller.thinkingMenu(),
              let modelID = try? controller.thinkingMenuModelID() else {
            return nil
        }
        return (choices, modelID)
    }

    /// `/think`: sends the thinking menu of the current model, or the
    /// notice `/think` answers with when there is none.
    func handleThinkMenuRequest(lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        do {
            switch try controller.thinkingMenu() {
            case let .unavailable(notice):
                await sendSystemMessageIfLinked(Self.noticeText(notice), lease: lease)
            case let .available(choices):
                guard let modelID = try controller.thinkingMenuModelID() else { return }
                await sendSelectionMenu(Self.thinkMenu(choices, modelID: modelID), lease: lease)
            }
        } catch {
            await sendSystemMessageIfLinked(
                Self.noticeText(.operationFailed(description: error.localizedDescription)),
                lease: lease
            )
        }
    }

    /// A `/think` tap (`<token>:<index>`): applies the level it names.
    private func handleThinkMenuCallback(_ fields: [String], lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        guard let menu = currentThinkMenu(controller),
              let item = Self.singleChoiceTapItem(
                  fields,
                  choices: menu.choices,
                  token: Self.selectionMenuToken(
                      itemIDs: menu.choices.items.map(\.id), context: menu.modelID
                  )
              ) else {
            await sendSelectionMenuOutOfDate(command: "think", lease: lease)
            return
        }
        await startSelectionMenuApply(.thinking(id: item.id, title: item.title), lease: lease)
    }

    // MARK: - /agents

    /// The `/agents` menu of `choices` (``ChatSessionController/agentChoices()``):
    /// a single choice of the active agent among the available profiles. The
    /// profiles associated with the project are chosen in the terminal.
    nonisolated static func agentPickerMenu(_ choices: ChatChoiceList) -> TelegramSelectionMenu {
        singleChoiceMenu(
            choices,
            instruction: "Tap the agent to make active.",
            callbackPrefix: agentsMenuCallbackPrefix + "p:",
            token: selectionMenuToken(itemIDs: choices.items.map(\.id))
        )
    }

    /// `/agents`: sends the agent picker, or the agent list when there is no
    /// profile.
    func handleAgentsMenuRequest(lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        do {
            let choices = try controller.agentChoices()
            guard !choices.items.isEmpty else {
                await sendSystemMessageIfLinked(
                    Self.noticeText(.availableAgents(
                        agents: [],
                        selected: controller.selection.agent,
                        manifestPath: AgentProfileStore.agentsManifestURL().path
                    )),
                    lease: lease
                )
                return
            }
            await sendSelectionMenu(Self.agentPickerMenu(choices), lease: lease)
        } catch {
            await sendSystemMessageIfLinked(
                Self.noticeText(.operationFailed(description: error.localizedDescription)),
                lease: lease
            )
        }
    }

    /// An `/agents` tap (`p:<token>:<index>`): activates the agent it names.
    /// Any other data, the toggles of the former multiple-choice menu
    /// included, is out of date.
    private func handleAgentsMenuCallback(_ fields: [String], lease: TerminalTelegramRouteLease) async {
        guard let controller else { return }
        guard fields.first == "p",
              let choices = try? controller.agentChoices(),
              let item = Self.singleChoiceTapItem(
                  fields.dropFirst(), choices: choices,
                  token: Self.selectionMenuToken(itemIDs: choices.items.map(\.id))
              ) else {
            await sendSelectionMenuOutOfDate(command: "agents", lease: lease)
            return
        }
        await startSelectionMenuApply(.agent(id: item.id), lease: lease)
    }

    // MARK: - Taps

    /// Answers the tap of a selection menu button, whose data has one of
    /// the menus' prefixes (``isSelectionMenuCallback(_:)``), on the message
    /// `messageID` of the chat: the ingress calls it once the busy gate let
    /// the tap through. A tap from another chat than the route's, or on a
    /// route that is no longer valid, is dropped.
    func handleSelectionMenuCallback(
        _ data: String, chatID: Int64, messageID: Int, lease: TerminalTelegramRouteLease
    ) async {
        guard lease.key.chatID == chatID,
              (try? await router.validate(lease)) != nil else { return }
        if let fields = Self.selectionMenuFields(data, prefix: Self.modelsMenuCallbackPrefix) {
            await handleModelsMenuCallback(fields, lease: lease)
        } else if let fields = Self.selectionMenuFields(data, prefix: Self.thinkMenuCallbackPrefix) {
            await handleThinkMenuCallback(fields, lease: lease)
        } else if let fields = Self.selectionMenuFields(data, prefix: Self.agentsMenuCallbackPrefix) {
            await handleAgentsMenuCallback(fields, lease: lease)
        } else if let fields = Self.selectionMenuFields(data, prefix: Self.sessionsMenuCallbackPrefix) {
            await handleSessionsMenuCallback(fields, chatID: chatID, messageID: messageID, lease: lease)
        }
    }

    // MARK: - Applying

    /// Runs `apply` as the channel's task, as a prompt from the chat runs,
    /// so it waits for nothing and ``stopDriving(shuttingDown:)`` cancels
    /// it; while a task of the channel runs or a prompt waits in its queue,
    /// it is refused with ``busyMessageText``.
    func startSelectionMenuApply(
        _ apply: TelegramSelectionMenuApply,
        lease: TerminalTelegramRouteLease
    ) async {
        guard activeTurnTask == nil, promptQueue.isEmpty else {
            await sendBusyMessage(lease: lease)
            return
        }
        activeTurnTask = Task(name: "ZenCODE.Telegram.channel-menu-selection") { [weak self] in
            guard let self else { return }
            await self.synchronizeSharedChatConsumerBusyState()
            await self.performSelectionMenuApply(apply, lease: lease)
            await self.turnTaskDidEnd()
        }
    }

    /// Applies `apply` through the controller and sends, on `lease`, the
    /// notices it presented and its closing notices, as for a command run
    /// from the chat; when it would send nothing at all, a short
    /// confirmation (``selectionMenuConfirmation(for:agentName:)``).
    func performSelectionMenuApply(
        _ apply: TelegramSelectionMenuApply,
        lease: TerminalTelegramRouteLease
    ) async {
        guard await validateLease(lease), let controller else { return }
        presenter.beginNoticeCapture()
        let outcome: ChatCommandOutcome
        switch apply {
        case let .model(id, _):
            outcome = await controller.applyModelSelection(id: id)
        case let .thinking(id, _):
            outcome = await controller.applyThinkingSelection(id: id)
        case let .agent(id):
            outcome = await controller.applyAgentSelection(id: id)
        case let .loadSavedSession(name):
            outcome = await controller.loadSavedSessionSelection(named: name)
        case let .deleteSavedSessions(names):
            do {
                outcome = ChatCommandOutcome(
                    notices: try await controller.deleteSavedSessions(names: names).notices
                )
            } catch {
                outcome = ChatCommandOutcome(notices: [
                    .operationFailed(description: error.localizedDescription),
                ])
            }
        case let .sessionsCommand(line):
            outcome = await controller.handleCommandLine(line, context: commandContext())
        }
        let captured = presenter.endNoticeCapture()
        let texts = captured + outcome.notices.map { ChatSessionNoticeText.text(for: $0) }
        if texts.joined(separator: "\n").nilIfBlank == nil,
           let confirmation = Self.selectionMenuConfirmation(
               for: apply,
               agentName: (self.controller ?? controller).selection.agent?.displayName
           ) {
            await sendSystemMessageIfLinked(confirmation, lease: lease)
            return
        }
        await sendCommandNotices(of: outcome, captured: captured, lease: lease)
    }

    /// The confirmation of `apply` when it presented nothing: the model, the
    /// level, or the active agent (`agentName`) now in effect.
    nonisolated static func selectionMenuConfirmation(
        for apply: TelegramSelectionMenuApply,
        agentName: String?
    ) -> String? {
        switch apply {
        case let .model(_, title):
            "ZenCODE: model set to \(title)."
        case let .thinking(_, title):
            "ZenCODE: thinking set to \(title)."
        case .agent:
            agentName.map { "ZenCODE: agent \($0) selected." }
        case .loadSavedSession, .deleteSavedSessions, .sessionsCommand:
            nil
        }
    }

    // MARK: - Wire

    /// Sends `menu` to the chat on `lease`.
    func sendSelectionMenu(_ menu: TelegramSelectionMenu, lease: TerminalTelegramRouteLease) async {
        _ = await sendReplyMarkupMessage(
            menu.text, to: lease.key.chatID, replyMarkup: menu.replyMarkup, lease: lease
        )
    }

    /// Tells the chat on `lease` that the menu of `/command` is out of date.
    func sendSelectionMenuOutOfDate(command: String, lease: TerminalTelegramRouteLease) async {
        await sendSystemMessageIfLinked(Self.selectionMenuOutOfDateText(command: command), lease: lease)
    }

    /// Replaces the keyboard of the message `messageID` with `markup`, or
    /// removes it (`nil`), best effort: a failed edit (the message is gone,
    /// or unchanged) changes nothing else. The
    /// ``onTelegramReplyMarkupEditForTesting`` seam takes it over in tests.
    func editSelectionMenuKeyboard(
        _ markup: TerminalTelegramReplyMarkup?,
        chatID: Int64,
        messageID: Int,
        lease: TerminalTelegramRouteLease
    ) async {
        if let hook = onTelegramReplyMarkupEditForTesting {
            await hook(markup, chatID, messageID)
            return
        }
        guard let fence = wireFence(for: lease) else { return }
        try? await controlService.editMessageReplyMarkup(
            markup, chatID: chatID, messageID: messageID, fence: fence
        )
    }

    /// The text of `notice` as the chat shows it, without the trailing
    /// newline the terminal writes.
    nonisolated static func noticeText(_ notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
