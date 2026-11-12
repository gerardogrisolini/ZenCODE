//
//  MemoryTurnContext.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Per-turn memory context propagated to the outgoing provider request.
//

import Foundation

/// Dynamic turn context carrying the automatically recalled memory block while
/// a runtime backend executes one prompt.
///
/// This mirrors ``AgentToolAuthorizationContext`` deliberately: a task-local is
/// the only channel that can deliver *per-turn* content to request assembly
/// without changing session identity. The two alternatives both fail:
///
/// - `AgentCoreSessionConfiguration.systemPrompt` participates in the session
///   cache key and in `matchesSessionIdentity`, so putting per-turn text there
///   would rotate the prompt-cache key on every turn.
/// - `AgentCoreSessionConfiguration.dynamicContext` is compared by
///   `matchesSessionIdentityIgnoringThinking`, so changing it per turn forces a
///   `createSession` and discards the whole conversation.
///
/// The block therefore travels out-of-band. The `sendPrompt` of a generation
/// client records it on the prompt it appends to the session, under a private
/// key (`RemoteGenerationClient.turnAdditionKey`), and request assembly merges
/// it into the *outgoing copy* of that prompt, on this turn and on every later
/// one, so the prompt is always sent again exactly as it was first sent and
/// the request prefix a provider caches stays valid across turns. The content
/// of a session message is never mutated, and history and snapshots are
/// derived from the known fields of a message only, so the block never enters
/// conversation history, saved session snapshots, or the session cache key.
/// Because the value is read deep inside the concrete generation clients —
/// across at least one actor hop from the runner — it relies on the same
/// task-local inheritance that already carries
/// `AgentToolAuthorizationContext.turnID` from
/// `AgentCoreSessionRunner.sendPrompt` into tool executors.
///
/// `nil` (or a blank string) always means "send the request exactly as it would
/// have been sent without memory". Every failure path in the recall pipeline
/// resolves to `nil`, so a broken, slow, or empty memory graph degrades to a
/// byte-identical request instead of failing the turn.
public enum MemoryTurnContext {
    @TaskLocal public static var currentTurnMemoryBlock: String? = nil
}
