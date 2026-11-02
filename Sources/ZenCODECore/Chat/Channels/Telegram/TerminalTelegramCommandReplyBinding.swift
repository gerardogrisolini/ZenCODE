//
//  TerminalTelegramCommandReplyBinding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

struct TerminalTelegramCommandReplyKey: Hashable, Sendable {
    let chatID: Int64
    let receiptMessageID: Int
}

struct TerminalTelegramCommandReplyBinding: Sendable {
    let command: String
    let chatID: Int64
    let lease: TerminalTelegramRouteLease
}
