//
//  TerminalTelegramSharedChatReplyTarget.swift
//  ZenCODE
//
//  The resolved destination of a Telegram reply to a forwarded shared-chat
//  card.
//

import Foundation
import ToolCore

/// Resolved destination of a Telegram reply to a forwarded shared-chat card.
///
/// Routing is derived exclusively from this locally recorded target, never from
/// the quoted text Telegram echoes back in `reply_to_message`: that payload is
/// user-controlled and could otherwise be used to address an arbitrary
/// participant.
public struct TerminalTelegramSharedChatReplyTarget: Sendable, Equatable {
    /// Room the card was forwarded from. Always the observation's room
    /// identifier, so it can be handed back to the runner as `rootSessionID`
    /// without depending on how the bus normalises room ids.
    public let roomID: String
    public let chatID: Int64
    public let sharedChatMessageID: UUID
    public let senderID: String
    public let senderKind: AgentSharedChat.ParticipantKind
    public let senderName: String

    /// Live destination that answers the original sender.
    ///
    /// `.operator` senders never produce a target (the operator is the human
    /// reading Telegram), so the fallback is deliberately absent rather than
    /// silently broadcasting.
    public var replyDestination: AgentSharedChat.Destination? {
        switch senderKind {
        case .agent:
            return .direct([senderID])
        case .coordinator:
            return .coordinator
        case .operator:
            return nil
        }
    }
}
