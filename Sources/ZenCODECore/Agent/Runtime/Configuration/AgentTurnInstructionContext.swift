//
//  AgentTurnInstructionContext.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 24/10/26.
//
//  Per-turn instruction propagated to the outgoing provider request.
//

import Foundation

/// Dynamic turn context carrying an optional instruction for the model while a
/// runtime backend executes one prompt.
///
/// The caller that starts the turn decides whether an instruction applies (for
/// example, a front end asking for short answers). The runtime stays generic:
/// it only transports the text and never interprets it.
///
/// This mirrors ``MemoryTurnContext`` deliberately, and for the same reasons: a
/// task-local is the only channel that can deliver *per-turn* content to
/// request assembly without changing session identity.
///
/// - `AgentCoreSessionConfiguration.systemPrompt` participates in the session
///   cache key and in `matchesSessionIdentity`, so putting a per-turn text
///   there would rotate the prompt-cache key whenever the instruction appears
///   or disappears.
/// - `AgentCoreSessionConfiguration.dynamicContext` is compared by
///   `matchesSessionIdentityIgnoringThinking`, so changing it per turn forces a
///   `createSession` and discards the whole conversation.
///
/// The instruction therefore travels out-of-band. It is bound by
/// `AgentCoreSessionRunner.sendPrompt` around the single `backend.sendPrompt`
/// call and is merged into the *outgoing copy* of the last user message by
/// `RemoteGenerationClient.applyingCurrentTurnMemory(to:block:instruction:)`,
/// after the recalled memory block. `session.messages` is never mutated, so the
/// instruction never enters conversation history, saved session snapshots, or
/// the session cache key.
///
/// A `Task {}` inherits task-locals, so work that is not the main turn — a
/// delegated sub-agent turn, the isolated memory proposal — binds `nil`
/// explicitly and does not receive the instruction.
///
/// `nil` (or a blank string) always means "send the request exactly as it would
/// have been sent without an instruction".
public enum AgentTurnInstructionContext {
    @TaskLocal public static var currentTurnInstruction: String? = nil
}
