//
//  ChatPromptQueue.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Finite FIFO for prompts accepted while the session is already busy.
///
/// A prompt has no durable second copy once it has left the channel that
/// received it (for the terminal, the local input panel or the Telegram update
/// stream). Callers must therefore handle a rejected insertion and report it to
/// the sender through that sender's own channel: the terminal answers local
/// input with a TUI error and remote input with a Telegram error. Keeping that
/// decision at the boundary makes overload explicit rather than silently
/// retaining an unbounded array of prompt text and attachments.
///
/// The queue only orders and bounds prompts: it never reorders, drops or
/// replaces one, and a rejected prompt leaves the queue untouched. When to
/// start the next prompt belongs to the session loop that owns the queue.
struct ChatPromptQueue<Origin: Sendable>: Sendable {
    /// A generous interactive backlog that still puts a firm upper bound on
    /// retained prompt text. The panel shows the current count to the operator.
    static var defaultCapacity: Int { 32 }

    private var storage: [ChatQueuedPrompt<Origin>]
    let capacity: Int

    init(capacity: Int = ChatPromptQueue.defaultCapacity) {
        self.capacity = max(1, capacity)
        storage = []
        storage.reserveCapacity(min(max(1, capacity), ChatPromptQueue.defaultCapacity))
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Returns `false` without mutating when the prompt backlog is full.
    @discardableResult
    mutating func enqueue(_ prompt: ChatQueuedPrompt<Origin>) -> Bool {
        guard storage.count < capacity else {
            return false
        }
        storage.append(prompt)
        return true
    }

    /// Removes and returns the oldest prompt, or `nil` when the queue is empty.
    mutating func dequeue() -> ChatQueuedPrompt<Origin>? {
        guard !storage.isEmpty else {
            return nil
        }
        return storage.removeFirst()
    }
}
