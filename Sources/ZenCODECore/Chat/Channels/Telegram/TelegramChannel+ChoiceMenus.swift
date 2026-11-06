//
//  TelegramChannel+ChoiceMenus.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation
import ToolCore

/// What a tap on a controller menu does (``TelegramChannel/choiceMenuTap(_:items:isMultipleChoice:selectedIDs:token:)``).
enum TelegramChoiceMenuTap: Sendable, Equatable {
    /// The request is answered with these item IDs: the chosen one, or the
    /// ticked ones in item order.
    case choose([String])
    /// The keyboard of the menu's message is ticked again with these ticks,
    /// one per shown item; the request keeps waiting.
    case retick([Bool])
    /// The request is cancelled (`nil`).
    case cancel
}

/// The generic menus of the channel: the controller's
/// ``ChatInteractionHost/chooseOne(title:items:selectedID:)`` and
/// ``ChatInteractionHost/chooseMany(title:items:selectedIDs:)`` asked in the
/// linked chat as an inline menu, such as the startup offer of the task graphs
/// earlier sessions left incomplete, and every other menu the controller asks
/// while the channel drives the slot. The focused multiple choice is not
/// offered.
///
/// One menu at a time, like a line of text: the request waits for a tap as
/// the channel's ``pendingChoiceReader``, and a request that arrives while
/// another waits, or without a valid route to the linked chat, is refused at
/// once (`nil`). The message lists the title, the items under their group
/// headings as `title — detail`, and the instruction; the keyboard shows at
/// most ``selectionMenuItemLimit`` items. The callback data, at most
/// ``selectionMenuCallbackDataLimit`` bytes after the prefix
/// ``choiceMenuCallbackPrefix``, carries the request's token
/// (``selectionMenuToken(itemIDs:context:)`` over the items and the request's
/// UUID), so a tap on the menu of an earlier request is refused with
/// ``choiceMenuOutOfDateText``:
///
/// - `s:<token>:<index>`: choose the item (single choice).
/// - `t:<token>:<mask>`: tick the items again, the keyboard of the same
///   message edited in place (multiple choice; a toggle carries the flipped
///   mask, ``selectionMenuMask(_:)``).
/// - `c:<token>:<mask>`: confirm the ticked items (multiple choice).
/// - `x:<token>`: cancel.
///
/// An answer resolves the request and then removes the keyboard of its
/// message, best effort. The ingress hands the taps here before its busy
/// gate, since a menu may wait while a turn runs, and answers any other
/// message with ``choicePendingText`` while a menu waits, a permission reply
/// excepted. Cancelling the request's task, and ``stopDriving(shuttingDown:)``
/// (``cancelPendingReaders()``), resolve it with `nil`.
extension TelegramChannel {
    /// A controller menu waiting for a tap of the chat.
    struct PendingChoiceReader {
        let id: UUID
        let lease: TerminalTelegramRouteLease
        let title: String
        let items: [ChatChoiceItem]
        let isMultipleChoice: Bool
        /// The IDs selected when the menu was sent: the ticked items of a
        /// multiple choice, the marked item of a single choice.
        let selectedIDs: Set<String>
        /// The menu's token; a tap must carry it.
        let token: String
        /// Resumed with the chosen item IDs, or `nil` when cancelled.
        let continuation: CheckedContinuation<[String]?, Never>
    }

    // MARK: - Texts

    /// The callback data prefix of a controller menu's button.
    nonisolated static let choiceMenuCallbackPrefix = "zencode:choice:"
    /// The answer to a tap on a controller menu that no longer waits, or
    /// whose data cannot be read.
    nonisolated static let choiceMenuOutOfDateText = "ZenCODE: this menu is out of date."
    /// The answer to any other message while a controller menu waits.
    nonisolated static let choicePendingText = "Choose an option from the menu above."
    /// The instruction of a single choice.
    nonisolated static let singleChoiceMenuInstruction = "Tap an option."
    /// The instruction of a multiple choice.
    nonisolated static let multipleChoiceMenuInstruction = "Tap the entries to select, then Done."

    // MARK: - Menus

    /// The message text of a controller menu: `title`, the shown `items`
    /// (``selectionMenuVisibleIndices(count:showsLast:)``) under their group
    /// headings, one `title — detail` line each, then `instruction` and how
    /// many items it shows when it cannot show them all; the sections are
    /// separated by blank lines.
    nonisolated static func choiceMenuText(
        title: String,
        items: [ChatChoiceItem],
        instruction: String
    ) -> String {
        let shown = selectionMenuVisibleIndices(count: items.count)
        var blocks: [[String]] = []
        var blockGroup: String?
        for index in shown {
            let item = items[index]
            if blocks.isEmpty || item.group != blockGroup {
                blocks.append(item.group.map { [$0] } ?? [])
                blockGroup = item.group
            }
            let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            blocks[blocks.count - 1].append(detail.isEmpty ? item.title : "\(item.title) — \(detail)")
        }
        var closing = [instruction]
        if shown.count < items.count {
            closing.append("Showing \(shown.count) of \(items.count).")
        }
        return ([title] + blocks.map { $0.joined(separator: "\n") } + [closing.joined(separator: "\n")])
            .joined(separator: "\n\n")
    }

    /// The single-choice menu of `items`: one button per shown item, the
    /// item's title, with a leading check when it is in `selectedIDs` or
    /// current, whose data is `s:<token>:<index>`, then `Cancel`.
    nonisolated static func chooseOneMenu(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        token: String
    ) -> TelegramSelectionMenu {
        let prefix = choiceMenuCallbackPrefix
        var keyboard = selectionMenuVisibleIndices(count: items.count).map { index in
            let item = items[index]
            let isMarked = selectedIDs.contains(item.id) || item.isCurrent
            return [TerminalTelegramInlineKeyboardButton(
                text: (isMarked ? "✓ " : "") + item.title,
                callbackData: "\(prefix)s:\(token):\(index)"
            )]
        }
        keyboard.append([
            TerminalTelegramInlineKeyboardButton(text: "Cancel", callbackData: "\(prefix)x:\(token)"),
        ])
        return TelegramSelectionMenu(
            text: choiceMenuText(title: title, items: items, instruction: singleChoiceMenuInstruction),
            keyboard: keyboard
        )
    }

    /// The multiple-choice menu of `items` with `ticks`, one per shown item:
    /// one toggle per shown item (`☑`/`☐` and its title, carrying the flipped
    /// mask, `t:<token>:<mask>`), then `Done` (`c:<token>:<mask>`) and
    /// `Cancel`.
    nonisolated static func chooseManyMenu(
        title: String,
        items: [ChatChoiceItem],
        ticks: [Bool],
        token: String
    ) -> TelegramSelectionMenu {
        let prefix = choiceMenuCallbackPrefix
        var keyboard = selectionMenuVisibleIndices(count: items.count).map { index in
            var flipped = ticks
            flipped[index].toggle()
            return [TerminalTelegramInlineKeyboardButton(
                text: (ticks[index] ? "☑ " : "☐ ") + items[index].title,
                callbackData: "\(prefix)t:\(token):\(selectionMenuMask(flipped))"
            )]
        }
        keyboard.append([
            TerminalTelegramInlineKeyboardButton(
                text: "Done", callbackData: "\(prefix)c:\(token):\(selectionMenuMask(ticks))"
            ),
            TerminalTelegramInlineKeyboardButton(text: "Cancel", callbackData: "\(prefix)x:\(token)"),
        ])
        return TelegramSelectionMenu(
            text: choiceMenuText(title: title, items: items, instruction: multipleChoiceMenuInstruction),
            keyboard: keyboard
        )
    }

    /// What the fields of a tap (the callback data after
    /// ``choiceMenuCallbackPrefix``, split on colons) do to the menu of
    /// `items` whose token is `token`; `nil` when they do not belong to it
    /// (another token, an action of the other kind of menu, an index or a
    /// mask out of range). Done answers the ticked items in item order, then
    /// the items of `selectedIDs` the menu could not show, which the operator
    /// had no way to untick.
    nonisolated static func choiceMenuTap(
        _ fields: [String],
        items: [ChatChoiceItem],
        isMultipleChoice: Bool,
        selectedIDs: Set<String>,
        token: String
    ) -> TelegramChoiceMenuTap? {
        guard fields.count >= 2, fields[1] == token else { return nil }
        let shown = selectionMenuVisibleIndices(count: items.count)
        switch (fields[0], fields.count, isMultipleChoice) {
        case ("s", 3, false):
            guard let index = selectionMenuIndex(fields[2], count: shown.count) else { return nil }
            return .choose([items[index].id])
        case ("t", 3, true):
            guard let ticks = selectionMenuTicks(mask: fields[2], count: shown.count) else { return nil }
            return .retick(ticks)
        case ("c", 3, true):
            guard let ticks = selectionMenuTicks(mask: fields[2], count: shown.count) else { return nil }
            let ticked = shown.filter { ticks[$0] }.map { items[$0].id }
            let unshown = items[shown.upperBound...].map(\.id).filter { selectedIDs.contains($0) }
            return .choose(ticked + unshown)
        case ("x", 2, _):
            return .cancel
        default:
            return nil
        }
    }

    // MARK: - ChatInteractionHost

    public func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        await waitForChoice(
            title: title,
            items: items,
            selectedIDs: selectedID.map { [$0] } ?? [],
            isMultipleChoice: false
        )?.first
    }

    public func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        await waitForChoice(
            title: title,
            items: items,
            selectedIDs: selectedIDs,
            isMultipleChoice: true
        ).map { Set($0) }
    }

    // MARK: - Waiting

    /// Sends the menu of `items` to the linked chat and waits for its answer
    /// (``handleChoiceMenuCallback(_:chatID:messageID:lease:)``): the chosen
    /// item IDs, or `nil` when it is cancelled, cannot be sent, or another
    /// menu waits. The request waits before the menu is sent, so the menu's
    /// first tap finds it.
    private func waitForChoice(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        isMultipleChoice: Bool
    ) async -> [String]? {
        guard !items.isEmpty, pendingChoiceReader == nil,
              let lease = activeRouteLease,
              outgoingChatID(for: lease) != nil,
              await validateLease(lease) else {
            return nil
        }
        let id = UUID()
        let token = Self.selectionMenuToken(itemIDs: items.map(\.id), context: id.uuidString)
        let menu = isMultipleChoice
            ? Self.chooseManyMenu(
                title: title,
                items: items,
                ticks: Self.selectionMenuVisibleIndices(count: items.count).map {
                    selectedIDs.contains(items[$0].id)
                },
                token: token
            )
            : Self.chooseOneMenu(title: title, items: items, selectedIDs: selectedIDs, token: token)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pendingChoiceReader == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingChoiceReader = PendingChoiceReader(
                    id: id,
                    lease: lease,
                    title: title,
                    items: items,
                    isMultipleChoice: isMultipleChoice,
                    selectedIDs: selectedIDs,
                    token: token,
                    continuation: continuation
                )
                Task(name: "ZenCODE.Telegram.channel-choice-menu") { @ChatSessionActor [weak self] in
                    await self?.sendChoiceMenu(menu, readerID: id, lease: lease)
                }
            }
        } onCancel: {
            Task { @ChatSessionActor in
                self.resolvePendingChoice(id: id, with: nil)
            }
        }
    }

    /// Sends `menu` for the request `readerID` while it still waits; a menu
    /// the chat did not receive cannot be answered, so its request is
    /// refused.
    private func sendChoiceMenu(
        _ menu: TelegramSelectionMenu,
        readerID: UUID,
        lease: TerminalTelegramRouteLease
    ) async {
        guard pendingChoiceReader?.id == readerID else { return }
        let receipt = await sendReplyMarkupMessage(
            menu.text, to: lease.key.chatID, replyMarkup: menu.replyMarkup, lease: lease
        )
        if receipt == nil {
            resolvePendingChoice(id: readerID, with: nil)
        }
    }

    /// Answers the request `id` with `answer`, when it still waits.
    private func resolvePendingChoice(id: UUID, with answer: [String]?) {
        guard let reader = pendingChoiceReader, reader.id == id else { return }
        pendingChoiceReader = nil
        reader.continuation.resume(returning: answer)
    }

    // MARK: - Taps

    /// Answers the tap of a controller menu's button, whose data has the
    /// prefix ``choiceMenuCallbackPrefix``, on the message `messageID` of the
    /// chat: a toggle ticks the keyboard of that message again, a choice,
    /// Done, or Cancel answers the waiting request and removes the keyboard.
    /// A tap that does not belong to the waiting menu, or that arrives when
    /// none waits, is told the menu is out of date. A tap from another chat
    /// than the route's, or on a route that is no longer valid, is dropped.
    func handleChoiceMenuCallback(
        _ data: String, chatID: Int64, messageID: Int, lease: TerminalTelegramRouteLease
    ) async {
        guard lease.key.chatID == chatID,
              (try? await router.validate(lease)) != nil else { return }
        guard let reader = pendingChoiceReader, reader.lease.key.chatID == chatID,
              let fields = Self.selectionMenuFields(data, prefix: Self.choiceMenuCallbackPrefix),
              let tap = Self.choiceMenuTap(
                  fields,
                  items: reader.items,
                  isMultipleChoice: reader.isMultipleChoice,
                  selectedIDs: reader.selectedIDs,
                  token: reader.token
              ) else {
            await sendSystemMessageIfLinked(Self.choiceMenuOutOfDateText, lease: lease)
            return
        }
        switch tap {
        case let .retick(ticks):
            await editSelectionMenuKeyboard(
                Self.chooseManyMenu(
                    title: reader.title, items: reader.items, ticks: ticks, token: reader.token
                ).replyMarkup,
                chatID: chatID, messageID: messageID, lease: lease
            )
        case let .choose(ids):
            resolvePendingChoice(id: reader.id, with: ids)
            await editSelectionMenuKeyboard(nil, chatID: chatID, messageID: messageID, lease: lease)
        case .cancel:
            resolvePendingChoice(id: reader.id, with: nil)
            await editSelectionMenuKeyboard(nil, chatID: chatID, messageID: messageID, lease: lease)
        }
    }
}
