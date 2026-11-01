//
//  ChatTurnOrigin.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

/// Where the prompt of a chat turn came from.
///
/// A plain value: it names the channel and nothing else. A channel that needs
/// more to answer the turn (the Telegram route of the chat that sent it) keeps
/// that itself. A turn carries its origin in ``ChatTurnRequest/origin``; a
/// ``ChatSessionStateReducer`` records it on the turn's
/// ``ChatTurnEntry/Kind/userPrompt(text:attachments:origin:)`` entry and falls
/// back to its ``ChatSessionStateReducer/defaultOrigin`` for a request that
/// names none.
public enum ChatTurnOrigin: Sendable, Equatable, Hashable {
    /// The terminal chat of the process.
    case local
    /// A host app that embeds `ZenCODECore`, such as the macOS app.
    case app
    /// An ACP client, such as an editor.
    case acp
    /// A headless run (`zen -p`, `--jsonl`).
    case headless
    /// A linked Telegram chat.
    case telegram
    /// The origin is not known: the turn was rebuilt from a saved transcript,
    /// which does not record it.
    case unknown
}
