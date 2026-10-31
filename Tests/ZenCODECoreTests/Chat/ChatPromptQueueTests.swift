//
//  ChatPromptQueueTests.swift
//  ZenCODE
//
//  The prompt queue of the Chat layer: the bounded FIFO the terminal kept before
//  it moved, generic over the origin of a prompt.
//

import Testing
@testable import ZenCODECore

/// The expectations are literal copies of what `TerminalQueuedPromptBuffer`
/// did before it moved (capacity 32, a full queue refuses and keeps its
/// content, first in first out), not calls to the code that now produces it.
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

    /// An origin without `Equatable`: only the queue's own conformances apply.
    private struct OpaqueOrigin: Sendable {
        let id: Int
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

    // MARK: - Empty queue

    @Test("A new queue is empty and holds 32 prompts")
    func newQueueIsEmptyWithDefaultCapacity() {
        var queue = ChatPromptQueue<TestOrigin>()

        #expect(queue.capacity == 32)
        #expect(ChatPromptQueue<TestOrigin>.defaultCapacity == 32)
        #expect(queue.count == 0)
        #expect(queue.isEmpty)
        #expect(queue.dequeue() == nil)
        #expect(queue.count == 0)
        #expect(queue.isEmpty)
    }

    @Test("The capacity is at least one")
    func capacityIsAtLeastOne() {
        for requested in [1, 0, -5] {
            var queue = ChatPromptQueue<TestOrigin>(capacity: requested)
            let first = Self.prompt("first")

            let acceptedFirst = queue.enqueue(first)
            let acceptedSecond = queue.enqueue(Self.prompt("second"))

            #expect(queue.capacity == 1)
            #expect(acceptedFirst)
            #expect(!acceptedSecond)
            #expect(queue.count == 1)
            #expect(queue.dequeue() == first)
            #expect(queue.dequeue() == nil)
        }
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

    @Test("Interleaved insertions and removals keep the order")
    func interleavedInsertionsKeepTheOrder() {
        var queue = ChatPromptQueue<TestOrigin>()

        let acceptedA = queue.enqueue(Self.prompt("a"))
        let acceptedB = queue.enqueue(Self.prompt("b"))
        let firstOut = queue.dequeue()
        let acceptedC = queue.enqueue(Self.prompt("c"))
        let secondOut = queue.dequeue()
        let acceptedD = queue.enqueue(Self.prompt("d"))

        #expect([acceptedA, acceptedB, acceptedC, acceptedD] == [true, true, true, true])
        #expect(firstOut?.text == "a")
        #expect(secondOut?.text == "b")
        #expect(queue.count == 2)
        #expect(Self.drain(&queue) == ["c", "d"])
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

    @Test("A refused prompt leaves a small queue as it was")
    func refusedPromptLeavesTheQueueUnchanged() {
        var queue = ChatPromptQueue<TestOrigin>(capacity: 2)
        let first = Self.prompt("first")
        let second = Self.prompt("second")
        let overflow = Self.prompt("overflow")

        let acceptedFirst = queue.enqueue(first)
        let acceptedSecond = queue.enqueue(second)
        let acceptedOverflow = queue.enqueue(overflow)
        let countAtCapacity = queue.count
        let dequeuedFirst = queue.dequeue()
        let dequeuedSecond = queue.dequeue()
        let dequeuedEmpty = queue.dequeue()

        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(!acceptedOverflow)
        #expect(countAtCapacity == 2)
        #expect(queue.count == 0)
        #expect(dequeuedFirst == first)
        #expect(dequeuedSecond == second)
        #expect(dequeuedEmpty == nil)
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

    @Test("A copy of a queue does not share its content")
    func copiesDoNotShareContent() {
        var queue = ChatPromptQueue<TestOrigin>(capacity: 2)
        let acceptedShared = queue.enqueue(Self.prompt("shared"))

        var copy = queue
        let removedFromCopy = copy.dequeue()
        let acceptedInCopy = copy.enqueue(Self.prompt("only in the copy"))

        #expect(acceptedShared)
        #expect(removedFromCopy?.text == "shared")
        #expect(acceptedInCopy)
        #expect(queue.count == 1)
        #expect(Self.drain(&queue) == ["shared"])
        #expect(Self.drain(&copy) == ["only in the copy"])
    }

    // MARK: - Prompts

    @Test("A prompt keeps its text, origin and mode")
    func promptKeepsItsFields() {
        var queue = ChatPromptQueue<TestOrigin>()
        let line = Self.prompt("/help", origin: .editor)
        let voice = Self.prompt("what changed?", origin: .remote(chat: 42), mode: .directPrompt)

        let acceptedLine = queue.enqueue(line)
        let acceptedVoice = queue.enqueue(voice)
        let first = queue.dequeue()
        let second = queue.dequeue()

        #expect(acceptedLine)
        #expect(acceptedVoice)
        #expect(first?.text == "/help")
        #expect(first?.origin == .editor)
        #expect(first?.mode == .submittedLine)
        #expect(second?.text == "what changed?")
        #expect(second?.origin == .remote(chat: 42))
        #expect(second?.mode == .directPrompt)
    }

    @Test("A prompt is a submitted line unless it says otherwise")
    func promptDefaultsToASubmittedLine() {
        let plain = ChatQueuedPrompt(text: "hello", origin: TestOrigin.editor)

        #expect(plain.mode == .submittedLine)
        #expect(plain == Self.prompt("hello"))
        #expect(plain != Self.prompt("hello", mode: .directPrompt))
        #expect(plain != Self.prompt("hello", origin: .remote(chat: 1)))
        #expect(plain != Self.prompt("goodbye"))
    }

    @Test("The queue accepts an origin that is not Equatable")
    func queueAcceptsAnOpaqueOrigin() {
        var queue = ChatPromptQueue<OpaqueOrigin>(capacity: 2)

        let acceptedOne = queue.enqueue(ChatQueuedPrompt(text: "one", origin: OpaqueOrigin(id: 1)))
        let acceptedTwo = queue.enqueue(ChatQueuedPrompt(text: "two", origin: OpaqueOrigin(id: 2)))
        let acceptedThree = queue.enqueue(ChatQueuedPrompt(text: "three", origin: OpaqueOrigin(id: 3)))
        let first = queue.dequeue()
        let second = queue.dequeue()

        #expect(acceptedOne)
        #expect(acceptedTwo)
        #expect(!acceptedThree)
        #expect(first?.origin.id == 1)
        #expect(second?.origin.id == 2)
        #expect(queue.isEmpty)
    }

    // MARK: - Terminal names

    @Test("The terminal names are the Chat types with the terminal origin")
    func terminalNamesAreTheChatTypes() {
        #expect(TerminalQueuedPromptBuffer.self == ChatPromptQueue<TerminalPromptOrigin>.self)
        #expect(TerminalQueuedPrompt.self == ChatQueuedPrompt<TerminalPromptOrigin>.self)
        #expect(TerminalQueuedPromptMode.self == ChatQueuedPromptMode.self)
    }

    @Test("The terminal queue keeps the terminal origins and its capacity of 32")
    func terminalQueueKeepsTerminalOrigins() {
        var queue = TerminalQueuedPromptBuffer()
        let local = TerminalQueuedPrompt(text: "from the panel", origin: .local)
        let remote = TerminalQueuedPrompt(
            text: "from telegram",
            origin: .telegram(chatID: 7),
            mode: .directPrompt
        )

        var accepted = [queue.enqueue(local), queue.enqueue(remote)]
        for index in 3...32 {
            accepted.append(queue.enqueue(TerminalQueuedPrompt(text: "prompt \(index)", origin: .local)))
        }
        let refused = queue.enqueue(
            TerminalQueuedPrompt(text: "refused", origin: .telegram(chatID: 7))
        )
        let countAtCapacity = queue.count
        let first = queue.dequeue()
        let second = queue.dequeue()

        #expect(queue.capacity == 32)
        #expect(accepted == Array(repeating: true, count: 32))
        #expect(!refused)
        #expect(countAtCapacity == 32)
        #expect(first == local)
        #expect(second == remote)
        #expect(second?.origin.telegramChatID == 7)
        #expect(second?.mode == .directPrompt)
        #expect(queue.count == 30)
    }
}
