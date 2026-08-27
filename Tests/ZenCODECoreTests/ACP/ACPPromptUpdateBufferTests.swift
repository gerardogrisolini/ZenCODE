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

    /// Metadata must never overtake content produced before it. When a usage
    /// update is emitted, the pending text is flushed ahead of it.
    @Test
    func usageUpdateNeverOvertakesPendingContent() throws {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("first half ")).isEmpty)
        // The metadata window has not elapsed yet, so nothing is emitted and the
        // text stays pending rather than being passed on the wire.
        #expect(buffer.consume(Self.usageUpdate(used: 10)).isEmpty)

        let flushed = buffer.flushAll()
        #expect(flushed.count == 2)
        let flushedContent = try #require(flushed.first)
        let flushedMetadata = try #require(flushed.last)
        #expect(Self.kind(of: flushedContent) == "agent_message_chunk")
        #expect(Self.text(of: flushedContent) == "first half ")
        #expect(Self.kind(of: flushedMetadata) == "usage_update")
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

    /// A blank or malformed chunk carries no reply text, so it must not create an
    /// empty message on the wire.
    @Test
    func emptyContentChunksAreIgnored() {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("")).isEmpty)
        #expect(buffer.flushAll().isEmpty)
    }

    /// A non-object update cannot be classified, so it is forwarded verbatim
    /// after the buffered content instead of being swallowed.
    @Test
    func nonObjectUpdateIsForwardedAfterBufferedContent() throws {
        let clock = ManualClock()
        let buffer = ACPPromptUpdateBuffer(now: clock.clock)

        #expect(buffer.consume(Self.chunk("reply")).isEmpty)
        let emitted = buffer.consume(.string("opaque"))

        #expect(emitted.count == 2)
        let forwardedContent = try #require(emitted.first)
        let forwardedUpdate = try #require(emitted.last)
        #expect(Self.text(of: forwardedContent) == "reply")
        #expect(forwardedUpdate.acpStringValue == "opaque")
    }
}
