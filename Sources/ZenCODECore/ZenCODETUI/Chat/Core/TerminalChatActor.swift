//
//  TerminalChatActor.swift
//  ZenCODE
//

/// Global actor that owns the terminal chat isolation domain.
///
/// All mutable state of `TerminalChat` is isolated here, which replaces the
/// previous `@unchecked Sendable` contract with compiler-checked isolation:
/// the periodic sub-agent overview refresh task, the generation callbacks, the
/// task-graph observer, and the Telegram bridge all reach instance state
/// through this actor, so their accesses are serialized by construction.
///
/// Contract: blocking POSIX reads must never run on this actor. Terminal input
/// (`readLine`, `drainBufferedLines`, raw-key consent reads) blocks the calling
/// thread, so it is dispatched off-actor through `withCheckedContinuation` on a
/// global dispatch queue. Running such a read on `TerminalChatActor` would
/// freeze rendering, the status bar, and every background refresh task.
///
/// Pure helpers that derive presentation strings from their arguments are
/// marked `nonisolated` so they remain callable synchronously from any context,
/// including tests.
@globalActor
public actor TerminalChatActor {
    public static let shared = TerminalChatActor()

    private init() {}
}
