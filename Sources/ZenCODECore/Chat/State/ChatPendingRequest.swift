//
//  ChatPendingRequest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// An operator interaction the session waits for, published in
/// ``ChatSessionSnapshot/pendingRequests`` by a ``ChatPendingRequestHost``
/// until the client answers it with
/// ``ChatPendingRequestHost/resolve(_:answer:)``.
///
/// Each kind is one ``ChatInteractionHost`` request, with its arguments.
public struct ChatPendingRequest: Sendable, Equatable, Identifiable {
    /// The interaction, one per ``ChatInteractionHost`` request.
    public enum Kind: Sendable, Equatable {
        /// ``ChatInteractionHost/requestToolConsent(_:)``; answered with
        /// ``Answer/consent(_:)``.
        case toolConsent(AgentToolAuthorizationRequest)
        /// ``ChatInteractionHost/chooseOne(title:items:selectedID:)``;
        /// answered with ``Answer/choice(_:)``.
        case chooseOne(title: String, items: [ChatChoiceItem], selectedID: String?)
        /// ``ChatInteractionHost/chooseMany(title:items:selectedIDs:)``;
        /// answered with ``Answer/choices(_:)``.
        case chooseMany(title: String, items: [ChatChoiceItem], selectedIDs: Set<String>)
        /// ``ChatInteractionHost/chooseManyWithFocus(title:items:selectedIDs:focusedID:toggleLabel:confirmLabel:)``;
        /// answered with ``Answer/focusedChoice(_:)``.
        case chooseManyWithFocus(
            title: String,
            items: [ChatChoiceItem],
            selectedIDs: Set<String>,
            focusedID: String?,
            toggleLabel: String,
            confirmLabel: String
        )
        /// ``ChatInteractionHost/readLine(prompt:)``; answered with
        /// ``Answer/text(_:)``.
        case readLine(prompt: String)
        /// ``ChatInteractionHost/requestWorkspaceAccess(_:)``; answered with
        /// ``Answer/workspaceAccess(granted:)``.
        case workspaceAccess(ChatWorkspaceAccessRequest)
        /// ``ChatInteractionHost/pickAttachment(startingAt:)``; answered with
        /// ``Answer/attachment(_:)``.
        case pickAttachment(startingAt: URL)
    }

    /// The operator's answer to a request. Each case answers the kind its
    /// documentation names; a `nil` answer is a refusal of any kind.
    public enum Answer: Sendable, Equatable {
        case consent(ChatConsentDecision)
        case choice(String)
        case choices(Set<String>)
        case focusedChoice(ChatFocusedChoice)
        case text(String)
        case workspaceAccess(granted: Bool)
        case attachment(URL)
    }

    /// Identifies the request until it is resolved or cancelled.
    public let id: UUID
    public let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

extension ChatPendingRequest.Kind {
    /// `true` when `answer` is the kind of answer this request takes.
    func accepts(_ answer: ChatPendingRequest.Answer) -> Bool {
        switch (self, answer) {
        case (.toolConsent, .consent),
             (.chooseOne, .choice),
             (.chooseMany, .choices),
             (.chooseManyWithFocus, .focusedChoice),
             (.readLine, .text),
             (.workspaceAccess, .workspaceAccess),
             (.pickAttachment, .attachment):
            true
        default:
            false
        }
    }
}
