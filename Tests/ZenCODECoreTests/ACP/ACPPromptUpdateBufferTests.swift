//
//  ACPPromptUpdateBufferTests.swift
//  ZenCODE
//
//  Covers the app-mode prompt update buffer: an ACP client only sees the reply
//  the buffer decides to emit, and only in the order it emits it.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// Deterministic manual clock: window-based flush decisions advance only when
/// the test moves time forward, so no test needs a real sleep.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(startingAt date: Date = Date(timeIntervalSince1970: 0)) {
        current = date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var clock: ACPPromptUpdateBuffer.Clock { { self.now } }
}

@Suite
struct ACPPromptUpdateBufferTests {
    private static func chunk(_ text: String) -> JSONValue {
        .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    }

    private static func usageUpdate(used: Int) -> JSONValue {
        .object([
            "sessionUpdate": .string("usage_update"),
            "used": .number(Double(used)),
            "size": .number(1_000)
        ])
    }

    private static func text(of update: JSONValue) -> String? {
        update.objectValue?["content"]?.objectValue?["text"]?.acpStringValue
    }

    private static func messageID(of update: JSONValue) -> String? {
        update.objectValue?["messageId"]?.acpStringValue
    }

    private static func chunk(_ text: String, messageID: String) -> JSONValue {
        ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_message_chunk", text: text, messageID: messageID)
    }

    private static func kind(of update: JSONValue) -> String? {
        update.objectValue?["sessionUpdate"]?.acpStringValue
    }

    /// The reply must reach the client: aggregated deltas are never dropped, and
    /// the final flush emits them as one `agent_message_chunk`.
    @Test
    func aggregatedContentIsDeliveredOnFlush() throws {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("Hello, ")).isEmpty)
        #expect(buffer.consume(Self.chunk("world")).isEmpty)

        let flushed = buffer.flushAll()
        #expect(flushed.count == 1)
        let flushedChunk = try #require(flushed.first)
        #expect(Self.kind(of: flushedChunk) == "agent_message_chunk")
        #expect(Self.text(of: flushedChunk) == "Hello, world")
        // Nothing is retained after a flush, so the reply is delivered once.
        #expect(buffer.flushAll().isEmpty)
    }

    /// Same guarantee once the metadata window has actually elapsed: this is the
    /// only path where a `usage_update` is emitted from `consume`, so it is the
    /// path where metadata could really overtake pending text on the wire.
    ///
    /// Time is advanced through the injected clock instead of sleeping, so the
    /// window boundary is reached deterministically.
    @Test
    func usageUpdateEmittedAfterItsWindowStillFlushesContentFirst() {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("produced before the metadata")).isEmpty)
        clock.advance(by: 2.1)

        let emitted = buffer.consume(Self.usageUpdate(used: 30))
        #expect(emitted.map(Self.kind(of:)) == ["agent_message_chunk", "usage_update"])
        #expect(emitted.first.flatMap(Self.text(of:)) == "produced before the metadata")
        // Both were emitted, so nothing is left behind for the final flush.
        #expect(buffer.flushAll().isEmpty)
    }

    /// An unrelated update (tool call, plan, stop reason) is a hard ordering
    /// boundary: everything buffered before it is emitted first, in order.
    @Test
    func unbufferedUpdateFlushesEverythingBeforeItself() throws {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("answer")).isEmpty)
        _ = buffer.consume(Self.usageUpdate(used: 20))

        let toolCall = JSONValue.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("call-1")
        ])
        let emitted = buffer.consume(toolCall)

        #expect(emitted.count == 3)
        let emittedContent = try #require(emitted.first)
        let emittedMetadata = try #require(emitted.dropFirst().first)
        let emittedBoundary = try #require(emitted.last)
        #expect(Self.kind(of: emittedContent) == "agent_message_chunk")
        #expect(Self.text(of: emittedContent) == "answer")
        #expect(Self.kind(of: emittedMetadata) == "usage_update")
        // The boundary update itself is always the last one emitted.
        #expect(Self.kind(of: emittedBoundary) == "tool_call")
    }

    /// Chunks of one message are coalesced into one, which keeps the id of the
    /// message.
    @Test
    func chunksOfOneMessageAreMergedUnderItsID() throws {
        let buffer = ACPPromptUpdateBuffer(now: ManualClock().clock)

        #expect(buffer.consume(Self.chunk("Hello, ", messageID: "m-1")).isEmpty)
        #expect(buffer.consume(Self.chunk("world", messageID: "m-1")).isEmpty)

        let flushed = buffer.flushAll()
        #expect(flushed.count == 1)
        let merged = try #require(flushed.first)
        #expect(Self.text(of: merged) == "Hello, world")
        #expect(Self.messageID(of: merged) == "m-1")
    }

    /// Two messages are never merged, whatever the window or the size: the
    /// text pending for the first one is emitted, under its own id, before the
    /// second one starts to accumulate.
    @Test
    func chunksOfDifferentMessagesAreNeverMerged() throws {
        let buffer = ACPPromptUpdateBuffer(now: ManualClock().clock)

        #expect(buffer.consume(Self.chunk("Agent: Developer · Model: m\n\n", messageID: "summary")).isEmpty)
        let emitted = buffer.consume(Self.chunk("The answer", messageID: "answer"))
        #expect(emitted.count == 1)
        let summary = try #require(emitted.first)
        #expect(Self.text(of: summary) == "Agent: Developer · Model: m\n\n")
        #expect(Self.messageID(of: summary) == "summary")

        // The second message is the one pending now, and keeps accumulating.
        #expect(buffer.consume(Self.chunk(" continues", messageID: "answer")).isEmpty)
        let rest = buffer.flushAll()
        #expect(rest.count == 1)
        #expect(Self.text(of: try #require(rest.first)) == "The answer continues")
        #expect(Self.messageID(of: try #require(rest.first)) == "answer")

        // A message with an id is not merged with one without it either.
        #expect(buffer.consume(Self.chunk("without id")).isEmpty)
        let switched = buffer.consume(Self.chunk("with id", messageID: "m-2"))
        #expect(switched.count == 1)
        #expect(Self.messageID(of: try #require(switched.first)) == nil)
        #expect(Self.text(of: try #require(switched.first)) == "without id")
        #expect(Self.messageID(of: try #require(buffer.flushAll().first)) == "m-2")
    }

    /// A message that grows past the size threshold is emitted in several
    /// chunks, each with the id of the message, and the next message starts a
    /// new one.
    @Test
    func aLongMessageKeepsItsIDInEveryChunkItIsSplitInto() throws {
        let buffer = ACPPromptUpdateBuffer(now: ManualClock().clock)
        let emitted = buffer.consume(Self.chunk(String(repeating: "a", count: 1_600), messageID: "long"))
            + buffer.consume(Self.chunk(String(repeating: "b", count: 1_600), messageID: "long"))
            + buffer.flushAll()
        #expect(emitted.count == 2)
        #expect(emitted.allSatisfy { Self.messageID(of: $0) == "long" })
        #expect(emitted.compactMap(Self.text(of:)).joined().count == 3_200)
    }
}
