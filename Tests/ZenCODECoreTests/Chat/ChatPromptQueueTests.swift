//
//  ChatPromptQueueTests.swift
//  ZenCODE
//
//  The prompt queue of the Chat layer: the bounded FIFO the terminal kept before
//  it moved, generic over the origin of a prompt.
//

import Testing
@testable import ZenCODECore

/// The expectations are literal copies of what the terminal prompt buffer did
/// before it moved (capacity 32, a full queue refuses and keeps its content,
/// first in first out), not calls to the code that now produces it.
///
/// `#expect` cannot call a mutating member directly, so the outcome of every
/// `enqueue` is bound to a constant first.
@Suite("Chat prompt queue")
struct ChatPromptQueueTests {
    // MARK: - Fixtures

    /// An origin that is not a terminal type: the queue must work for any
    /// channel, and the Chat layer must not name one.
    private enum TestOrigin: Sendable, Equatable {
        case editor
        case remote(chat: Int)
    }

    private static func prompt(
        _ text: String,
        origin: TestOrigin = .editor,
        mode: ChatQueuedPromptMode = .submittedLine
    ) -> ChatQueuedPrompt<TestOrigin> {
        ChatQueuedPrompt(text: text, origin: origin, mode: mode)
    }

    /// Empties a queue, oldest prompt first.
    private static func drain(_ queue: inout ChatPromptQueue<TestOrigin>) -> [String] {
        var texts: [String] = []
        while let next = queue.dequeue() {
            texts.append(next.text)
        }
        return texts
    }

    // MARK: - Order

    @Test("Prompts leave in the order they entered")
    func promptsLeaveInArrivalOrder() {
        var queue = ChatPromptQueue<TestOrigin>()
        let texts = (1...10).map { "prompt \($0)" }

        for (index, text) in texts.enumerated() {
            let accepted = queue.enqueue(Self.prompt(text))
            #expect(accepted)
            #expect(queue.count == index + 1)
        }
        #expect(!queue.isEmpty)

        let dequeued = Self.drain(&queue)

        #expect(dequeued == texts)
        #expect(queue.isEmpty)
        #expect(queue.count == 0)
    }

    // MARK: - Overflow

    @Test("The 33rd prompt is refused and the 32 before it are untouched")
    func thirtyThirdPromptIsRefused() {
        var queue = ChatPromptQueue<TestOrigin>()

        var accepted: [Bool] = []
        for index in 1...32 {
            accepted.append(queue.enqueue(Self.prompt("prompt \(index)")))
        }
        let acceptedOverflow = queue.enqueue(Self.prompt("prompt 33"))
        let acceptedAgain = queue.enqueue(Self.prompt("prompt 34"))

        #expect(accepted == Array(repeating: true, count: 32))
        #expect(!acceptedOverflow)
        #expect(!acceptedAgain)
        #expect(queue.count == 32)
        #expect(!queue.isEmpty)
        #expect(Self.drain(&queue) == (1...32).map { "prompt \($0)" })
        #expect(queue.isEmpty)
    }

    @Test("A slot freed by a removal accepts a prompt at the tail")
    func freedSlotAcceptsAPromptAtTheTail() {
        var queue = ChatPromptQueue<TestOrigin>(capacity: 2)

        let acceptedFirst = queue.enqueue(Self.prompt("first"))
        let acceptedSecond = queue.enqueue(Self.prompt("second"))
        let refused = queue.enqueue(Self.prompt("refused"))
        let removed = queue.dequeue()
        let acceptedThird = queue.enqueue(Self.prompt("third"))
        let refusedAgain = queue.enqueue(Self.prompt("refused again"))

        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(!refused)
        #expect(removed?.text == "first")
        #expect(acceptedThird)
        #expect(!refusedAgain)
        #expect(queue.count == 2)
        #expect(Self.drain(&queue) == ["second", "third"])
    }
}
