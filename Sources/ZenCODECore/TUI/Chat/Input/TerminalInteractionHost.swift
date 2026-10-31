//
//  TerminalInteractionHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Operator interactions of the terminal chat.
///
/// Consent goes through the terminal consent card of the permission
/// authorizer, which reads keys through the chat's shared interactive reader;
/// menus and line input run off the actor like every other blocking read.
/// Menus and line input need an interactive terminal: without one the host
/// does not offer them, so the selection commands print their
/// non-interactive output instead.
@TerminalChatActor
final class TerminalInteractionHost: ChatInteractionHost {
    weak var chat: TerminalChat?
    /// Whether stdin is an interactive terminal.
    nonisolated let stdinIsTerminal: Bool
    /// Whether the process runs inside a host app rather than a terminal.
    nonisolated let appMode: Bool

    init(stdinIsTerminal: Bool, appMode: Bool) {
        self.stdinIsTerminal = stdinIsTerminal
        self.appMode = appMode
    }

    nonisolated var capabilities: ChatChannelCapabilities {
        var capabilities: ChatChannelCapabilities = [
            .toolConsent,
            .serialConsentDialogs,
            .liveFileArtifacts,
        ]
        if stdinIsTerminal {
            capabilities.formUnion([
                .singleChoice,
                .multipleChoice,
                .focusedMultipleChoice,
                .textInput,
            ])
        }
        return capabilities
    }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        guard let chat else { return nil }
        return await chat.permissionAuthorizer.terminalHost.requestToolConsent(request)
    }

    func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        guard let chat else { return nil }
        return await TerminalCheckboxMenu.selectOneOffActor(
            title: title,
            items: Self.menuItems(items),
            selected: selectedID,
            reservedBottomRows: await chat.statusBar.reservedRowsForOverlay()
        )
    }

    func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        guard let chat else { return nil }
        return await TerminalCheckboxMenu.selectOffActor(
            title: title,
            items: Self.menuItems(items),
            selected: selectedIDs,
            reservedBottomRows: await chat.statusBar.reservedRowsForOverlay()
        )
    }

    func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice? {
        guard let chat else { return nil }
        guard let choice = await TerminalCheckboxMenu.selectWithFocusOffActor(
            title: title,
            items: Self.menuItems(items),
            selected: selectedIDs,
            focused: focusedID,
            helpLines: Self.focusedMenuHelpLines(
                toggleLabel: toggleLabel,
                confirmLabel: confirmLabel
            ),
            reservedBottomRows: await chat.statusBar.reservedRowsForOverlay()
        ) else {
            return nil
        }
        return ChatFocusedChoice(selectedIDs: choice.selected, focusedID: choice.focused)
    }

    func readLine(prompt: String) async -> String? {
        guard let chat else { return nil }
        return await TerminalChat.readLineOffActor(
            reader: chat.interactiveReader,
            prompt: prompt
        )
    }

    /// Without a terminal or inside a host app access is granted; on macOS
    /// the terminal asks for the folder; elsewhere access is granted.
    func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        guard stdinIsTerminal, !appMode else {
            return true
        }
        #if os(macOS)
        return await TerminalWorkspaceToolAccessStore.shared.ensureAccess(
            for: request.workspaceURL
        )
        #else
        return true
        #endif
    }

    /// The key-help line of a focused multiple-choice menu.
    nonisolated static func focusedMenuHelpLines(
        toggleLabel: String,
        confirmLabel: String
    ) -> [String] {
        [
            "↑/↓ move · Space/X toggle \(toggleLabel) · A all · N none · Enter \(confirmLabel) · Esc/Q cancel"
        ]
    }

    /// Menu rows of `items`: the current item flagged with ` *`, the group
    /// as the row's heading.
    nonisolated static func menuItems(
        _ items: [ChatChoiceItem]
    ) -> [TerminalCheckboxMenuItem<String>] {
        items.map { item in
            TerminalCheckboxMenuItem(
                value: item.id,
                title: item.title + (item.isCurrent ? " *" : ""),
                detail: item.detail,
                groupTitle: item.group
            )
        }
    }
}
