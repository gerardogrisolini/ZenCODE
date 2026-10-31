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
@TerminalChatActor
final class TerminalInteractionHost: ChatInteractionHost {
    weak var chat: TerminalChat?

    init() {}

    nonisolated var capabilities: ChatChannelCapabilities {
        [.toolConsent, .serialConsentDialogs, .singleChoice, .multipleChoice, .textInput, .liveFileArtifacts]
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

    func readLine(prompt: String) async -> String? {
        guard let chat else { return nil }
        return await TerminalChat.readLineOffActor(
            reader: chat.interactiveReader,
            prompt: prompt
        )
    }

    private nonisolated static func menuItems(
        _ items: [ChatChoiceItem]
    ) -> [TerminalCheckboxMenuItem<String>] {
        items.map { item in
            TerminalCheckboxMenuItem(value: item.id, title: item.title, detail: item.detail)
        }
    }
}
