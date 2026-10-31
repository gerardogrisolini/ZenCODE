//
//  ChatSessionActor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Global actor that owns the chat-session isolation domain.
///
/// Every ``ChatSessionController`` and every channel that drives one (the
/// terminal chat, the ACP bridge sessions, the headless runner) reaches the
/// controller state through this actor, so turn bookkeeping, transcripts,
/// command state, and file-change artifacts are serialized by construction.
///
/// The terminal chat keeps its historical name through the
/// ``TerminalChatActor`` alias: all of `TerminalChat` is isolated here, which
/// replaces the previous `@unchecked Sendable` contract with compiler-checked
/// isolation. The periodic sub-agent overview refresh task, the generation
/// callbacks, the task-graph observer, and the Telegram bridge all reach
/// instance state through this actor.
///
/// Contract: blocking POSIX reads must never run on this actor. Terminal input
/// (`readLine`, `drainBufferedLines`, raw-key consent reads) blocks the calling
/// thread, so it is dispatched off-actor through `withCheckedContinuation` on a
/// global dispatch queue. Running such a read on this actor would freeze
/// rendering, the status bar, and every background refresh task.
///
/// Pure helpers that derive presentation strings from their arguments are
/// marked `nonisolated` so they remain callable synchronously from any context,
/// including tests.
@globalActor
public actor ChatSessionActor {
    public static let shared = ChatSessionActor()

    private init() {}
}

/// Compatibility name of ``ChatSessionActor`` used by the terminal chat.
public typealias TerminalChatActor = ChatSessionActor
