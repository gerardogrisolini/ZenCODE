//
//  TerminalQueuedPromptBuffer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Finite FIFO for prompts accepted while the terminal is already busy.
///
/// The queue itself lives in the Chat layer (``ChatPromptQueue``); the terminal
/// supplies its own origin type. A prompt has no durable second copy once it has
/// left the local panel or the Telegram update stream, so callers must handle a
/// rejected insertion: local input receives a TUI error and remote input
/// receives a Telegram error.
typealias TerminalQueuedPromptBuffer = ChatPromptQueue<TerminalPromptOrigin>
