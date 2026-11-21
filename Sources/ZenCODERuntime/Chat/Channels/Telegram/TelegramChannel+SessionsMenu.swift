//
//  TelegramChannel+SessionsMenu.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

import Foundation
import ToolCore

/// The `/sessions` menus: a first menu of actions, then the saved sessions
/// to load, the saved sessions to delete (a multiple choice whose ticks are
/// edited in place), and the checkpoint entries of the active saved session
/// to restore from. They are stateless like the other selection menus
/// (`TelegramChannel+SelectionMenus.swift`), with the callback data prefix
/// ``sessionsMenuCallbackPrefix``:
///
/// - `a:<action>`: an action of the first menu (``SessionsMenuAction``);
///   New, Save and Compact apply at once, the others send their list.
/// - `l:<token>:<index>`: load the saved session.
/// - `dt:<token>:<mask>`: re-tick the deletion list in place.
/// - `dc:<token>:<mask>`: delete the ticked sessions; `dx` cancels.
/// - `r:<token>:<index>`: restore from the checkpoint entry.
extension TelegramChannel {
    /// An action of the first `/sessions` menu, in menu order; its raw value
    /// is the one its callback data carries.
    enum SessionsMenuAction: String, CaseIterable, Sendable {
        case load
        case new
        case save
        case compact
        case delete
        case restore

        /// The title of its button.
        var title: String {
            switch self {
            case .load: "Load"
            case .new: "New"
            case .save: "Save"
            case .compact: "Compact"
            case .delete: "Delete"
            case .restore: "Restore checkpoint"
            }
        }

        /// The `/sessions` line an action that applies at once runs; `nil`
        /// for an action that sends a list.
        var commandLine: String? {
            switch self {
            case .new: "/sessions new"
            case .save: "/sessions save"
            case .compact: "/sessions compact"
            case .load, .delete, .restore: nil
            }
        }
    }

    // MARK: - Menus

    /// The first `/sessions` menu: one button per action.
    nonisolated static func sessionsActionMenu() -> TelegramSelectionMenu {
        TelegramSelectionMenu(
            text: "Sessions\nChoose an action.",
            keyboard: SessionsMenuAction.allCases.map { action in
                [TerminalTelegramInlineKeyboardButton(
                    text: action.title,
                    callbackData: "\(sessionsMenuCallbackPrefix)a:\(action.rawValue)"
                )]
            }
        )
    }

    /// The saved sessions `sessions` (most recently saved first) as a menu,
    /// the active one (`activeName`) selected.
    nonisolated static func savedSessionChoices(
        _ sessions: [TerminalSavedSession],
        title: String,
        activeName: String?
    ) -> ChatChoiceList {
        ChatChoiceList(
            title: title,
            items: ChatSessionController.savedSessionChoiceItems(sessions),
            selectedIDs: activeName.map { [$0] } ?? []
        )
    }

    /// The token of a saved-session menu of `choices`.
    nonisolated static func savedSessionsMenuToken(_ choices: ChatChoiceList) -> String {
        selectionMenuToken(itemIDs: choices.items.map(\.id))
    }

    /// The Load list: a single choice of the saved sessions `choices`.
    nonisolated static func savedSessionsLoadMenu(_ choices: ChatChoiceList) -> TelegramSelectionMenu {
        singleChoiceMenu(
            choices,
            instruction: "Tap the session to load.",
            callbackPrefix: sessionsMenuCallbackPrefix + "l:",
            token: savedSessionsMenuToken(choices)
        )
    }

    /// The Delete list of the saved sessions `choices` with `ticks`, one per
    /// shown session (the first ``selectionMenuItemLimit``): one toggle per
    /// session (`☑`/`☐` and its name, carrying the flipped mask), then
    /// `Delete selected` (the mask) and `Cancel`.
    nonisolated static func savedSessionsDeleteMenu(
        _ choices: ChatChoiceList,
        ticks: [Bool]
    ) -> TelegramSelectionMenu {
        let indices = selectionMenuVisibleIndices(count: choices.items.count)
        let token = savedSessionsMenuToken(choices)
        let prefix = sessionsMenuCallbackPrefix
        var keyboard: [[TerminalTelegramInlineKeyboardButton]] = indices.map { index in
            var flipped = ticks
            flipped[index].toggle()
            return [TerminalTelegramInlineKeyboardButton(
                text: (ticks[index] ? "☑ " : "☐ ") + choices.items[index].title,
                callbackData: "\(prefix)dt:\(token):\(selectionMenuMask(flipped))"
            )]
        }
        keyboard.append([
            TerminalTelegramInlineKeyboardButton(
                text: "Delete selected",
                callbackData: "\(prefix)dc:\(token):\(selectionMenuMask(ticks))"
            ),
            TerminalTelegramInlineKeyboardButton(text: "Cancel", callbackData: "\(prefix)dx"),
        ])
        return TelegramSelectionMenu(
            text: selectionMenuText(
                title: choices.title,
                instruction: "Tap the sessions to delete, then Delete selected.",
                shown: indices.count, total: choices.items.count
            ),
            keyboard: keyboard
        )
    }

    /// The Restore list: a single choice of the checkpoint entries `choices`
    /// of the saved session `sessionName`, the last ones when they are too
    /// many, the active leaf marked.
    nonisolated static func checkpointRestoreMenu(
        _ choices: ChatChoiceList,
        sessionName: String
    ) -> TelegramSelectionMenu {
        singleChoiceMenu(
            choices,
            instruction: "Tap the entry to restore the session from.",
            callbackPrefix: sessionsMenuCallbackPrefix + "r:",
            token: checkpointRestoreMenuToken(choices, sessionName: sessionName),
            showsLast: true
        )
    }

    /// The token of a Restore list of `choices` for `sessionName`.
    nonisolated static func checkpointRestoreMenuToken(
        _ choices: ChatChoiceList,
        sessionName: String
    ) -> String {
        selectionMenuToken(itemIDs: choices.items.map(\.id), context: sessionName)
    }

    // MARK: - Requests

    /// `/sessions`: sends the first menu.
    func handleSessionsMenuRequest(lease: TerminalTelegramRouteLease) async {
        guard controller != nil else { return }
        await sendSelectionMenu(Self.sessionsActionMenu(), lease: lease)
    }

    /// The saved sessions of the project, or `nil` once the chat was told
    /// they cannot be read.
    private func savedSessionsForMenu(
        _ controller: ChatSessionController,
        lease: TerminalTelegramRouteLease
    ) async -> [TerminalSavedSession]? {
        do {
            return try controller.savedSessions()
        } catch {
            await sendSystemMessageIfLinked(
                Self.noticeText(.operationFailed(description: error.localizedDescription)),
                lease: lease
            )
            return nil
        }
    }

    // MARK: - Taps

    /// A `/sessions` tap (see the extension's list of callback data).
    func handleSessionsMenuCallback(
        _ fields: [String], chatID: Int64, messageID: Int, lease: TerminalTelegramRouteLease
    ) async {
        guard let controller, let action = fields.first else { return }
        switch (action, fields.count) {
        case ("a", 2):
            guard let menuAction = SessionsMenuAction(rawValue: fields[1]) else {
                await sendSelectionMenuOutOfDate(command: "sessions", lease: lease)
                return
            }
            await handleSessionsMenuAction(menuAction, controller: controller, lease: lease)
        case ("l", 3):
            guard let sessions = await savedSessionsForMenu(controller, lease: lease) else { return }
            let choices = Self.savedSessionChoices(
                sessions, title: "Saved sessions",
                activeName: controller.savedSessionState.savedSessionName
            )
            guard let item = Self.singleChoiceTapItem(
                fields.dropFirst(), choices: choices, token: Self.savedSessionsMenuToken(choices)
            ) else {
                await sendSelectionMenuOutOfDate(command: "sessions", lease: lease)
                return
            }
            await startSelectionMenuApply(.loadSavedSession(name: item.id), lease: lease)
        case ("dt", 3), ("dc", 3):
            await handleSavedSessionsDeleteTap(
                fields, controller: controller, chatID: chatID, messageID: messageID, lease: lease
            )
        case ("dx", 1):
            // As the terminal's cancelled menu, nothing is said.
            await editSelectionMenuKeyboard(nil, chatID: chatID, messageID: messageID, lease: lease)
        case ("r", 3):
            guard case let .available(choices)? = try? controller.checkpointEntryMenu(),
                  let sessionName = controller.savedSessionState.savedSessionName,
                  let item = Self.singleChoiceTapItem(
                      fields.dropFirst(), choices: choices,
                      token: Self.checkpointRestoreMenuToken(choices, sessionName: sessionName)
                  ) else {
                await sendSelectionMenuOutOfDate(command: "sessions", lease: lease)
                return
            }
            await startSelectionMenuApply(.sessionsCommand("/sessions restore \(item.id)"), lease: lease)
        default:
            await sendSelectionMenuOutOfDate(command: "sessions", lease: lease)
        }
    }

    /// An action of the first menu: New, Save and Compact apply at once;
    /// Load, Delete and Restore send their list, or the notice that says
    /// there is nothing to list.
    private func handleSessionsMenuAction(
        _ action: SessionsMenuAction,
        controller: ChatSessionController,
        lease: TerminalTelegramRouteLease
    ) async {
        if let commandLine = action.commandLine {
            await startSelectionMenuApply(.sessionsCommand(commandLine), lease: lease)
            return
        }
        switch action {
        case .load, .delete:
            guard let sessions = await savedSessionsForMenu(controller, lease: lease) else { return }
            guard !sessions.isEmpty else {
                await sendSystemMessageIfLinked(Self.noticeText(.noSavedSessions), lease: lease)
                return
            }
            if action == .load {
                await sendSelectionMenu(
                    Self.savedSessionsLoadMenu(Self.savedSessionChoices(
                        sessions, title: "Saved sessions",
                        activeName: controller.savedSessionState.savedSessionName
                    )),
                    lease: lease
                )
            } else {
                let choices = Self.savedSessionChoices(
                    sessions, title: "Delete saved sessions", activeName: nil
                )
                let shown = Self.selectionMenuVisibleIndices(count: choices.items.count).count
                await sendSelectionMenu(
                    Self.savedSessionsDeleteMenu(choices, ticks: Array(repeating: false, count: shown)),
                    lease: lease
                )
            }
        case .restore:
            do {
                switch try controller.checkpointEntryMenu() {
                case let .unavailable(notice):
                    await sendSystemMessageIfLinked(Self.noticeText(notice), lease: lease)
                case let .available(choices):
                    guard let sessionName = controller.savedSessionState.savedSessionName else { return }
                    await sendSelectionMenu(
                        Self.checkpointRestoreMenu(choices, sessionName: sessionName), lease: lease
                    )
                }
            } catch {
                await sendSystemMessageIfLinked(
                    Self.noticeText(.operationFailed(description: error.localizedDescription)),
                    lease: lease
                )
            }
        case .new, .save, .compact:
            break
        }
    }

    /// A tap of the Delete list: `dt` re-ticks the keyboard of its message
    /// in place, `dc` deletes the ticked sessions, or says none is ticked.
    private func handleSavedSessionsDeleteTap(
        _ fields: [String],
        controller: ChatSessionController,
        chatID: Int64,
        messageID: Int,
        lease: TerminalTelegramRouteLease
    ) async {
        guard let sessions = await savedSessionsForMenu(controller, lease: lease) else { return }
        let choices = Self.savedSessionChoices(sessions, title: "Delete saved sessions", activeName: nil)
        let shown = Self.selectionMenuVisibleIndices(count: choices.items.count).count
        guard shown > 0, fields[1] == Self.savedSessionsMenuToken(choices),
              let ticks = Self.selectionMenuTicks(mask: fields[2], count: shown) else {
            await sendSelectionMenuOutOfDate(command: "sessions", lease: lease)
            return
        }
        if fields[0] == "dt" {
            await editSelectionMenuKeyboard(
                Self.savedSessionsDeleteMenu(choices, ticks: ticks).replyMarkup,
                chatID: chatID, messageID: messageID, lease: lease
            )
            return
        }
        let names = Set((0..<shown).filter { ticks[$0] }.map { choices.items[$0].id })
        guard !names.isEmpty else {
            await sendSystemMessageIfLinked(Self.noSessionsSelectedText, lease: lease)
            return
        }
        await startSelectionMenuApply(.deleteSavedSessions(names: names), lease: lease)
    }

    /// The answer to `Delete selected` with nothing ticked.
    nonisolated static let noSessionsSelectedText = "ZenCODE: no sessions selected."
}
