//
//  TerminalQueuedPromptBuffer.swift
//  ZenCODE
//

/// Finite FIFO for prompts accepted while the terminal is already busy.
///
/// A prompt has no durable second copy once it has left the local panel or the
/// Telegram update stream. Callers must therefore handle a rejected insertion:
/// local input receives a TUI error and remote input receives a Telegram error.
/// Keeping that decision at the boundary makes overload explicit rather than
/// silently retaining an unbounded array of prompt text and attachments.
struct TerminalQueuedPromptBuffer: Sendable {
    /// A generous interactive backlog that still puts a firm upper bound on
    /// retained prompt text. The panel shows the current count to the operator.
    static let defaultCapacity = 32

    private var storage: [TerminalQueuedPrompt]
    let capacity: Int

    init(capacity: Int = TerminalQueuedPromptBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
        storage = []
        storage.reserveCapacity(min(max(1, capacity), TerminalQueuedPromptBuffer.defaultCapacity))
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Returns `false` without mutating when the prompt backlog is full.
    @discardableResult
    mutating func enqueue(_ prompt: TerminalQueuedPrompt) -> Bool {
        guard storage.count < capacity else {
            return false
        }
        storage.append(prompt)
        return true
    }

    mutating func dequeue() -> TerminalQueuedPrompt? {
        guard !storage.isEmpty else {
            return nil
        }
        return storage.removeFirst()
    }
}
