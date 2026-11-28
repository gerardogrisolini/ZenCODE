//
//  ACPPromptUpdatePipelineTests.swift
//  ZenCODE
//
//  The prompt-update pipeline serializes writer-facing work even when its raw
//  task bodies start in an adversarial scheduler order.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Parks raw task bodies before they await a predecessor. Tests release task
/// ordinals in reverse order, proving ordering comes from the chain itself.
private actor RawTaskGate {
    private var arrived: Set<Int> = []
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func park(_ ordinal: Int) async {
        arrived.insert(ordinal)
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            parked[ordinal] = continuation
        }
    }

    func waitUntilArrivals(_ expected: Int) async {
        while arrived.count < expected {
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }
    }

    func release(_ ordinal: Int) {
        precondition(arrived.contains(ordinal))
        guard let continuation = parked.removeValue(forKey: ordinal) else {
            preconditionFailure("raw task \(ordinal) was not parked")
        }
        continuation.resume()
    }
}

private actor PipelineTrace {
    private var starts: [Int] = []
    private var events: [String] = []

    func unitStarted(_ ordinal: Int) {
        starts.append(ordinal)
        events.append("start-\(ordinal)")
    }

    func record(_ event: String) {
        events.append(event)
    }

    func recordedStarts() -> [Int] { starts }
}

/// Recording sink: captures every wire message in delivery order.
private final class RecordingSink: Sendable {
    private let storage = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            storage.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
        }
    }

    func deliveredMessages() -> [String] {
        storage.withLock { $0 }
    }
}

@Suite
struct ACPPromptUpdatePipelineTests {
    private static func chunk(_ text: String) -> JSONValue {
        .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    }

    /// All three raw tasks are parked before predecessor awaits, then released
    /// in reverse ordinal order. If the predecessor wait were absent or moved
    /// after `onUnitStart`, the observed unit starts would become [3, 2, 1].
    @Test
    func concurrentRawTasksStillStartUnitsInOrdinalOrder() async throws {
        let rawGate = RawTaskGate()
        let trace = PipelineTrace()
        let sink = RecordingSink()
        let writer = ACPWriter(sink: sink.sink)
        let pipeline = ACPPromptUpdatePipeline(
            sessionID: "pipeline-order",
            writer: writer,
            buffer: ACPPromptUpdateBuffer(now: { Date(timeIntervalSince1970: 0) }),
            onTaskStart: { ordinal in await rawGate.park(ordinal) },
            onUnitStart: { ordinal in await trace.unitStarted(ordinal) }
        )

        let first = pipeline.enqueue(.init(kind: .consume(Self.chunk("first unit"))))
        let second = pipeline.enqueue(.init(kind: .consume(Self.chunk("second"))))
        let third = pipeline.enqueue(
            .init(
                kind: .flushThenNotify(
                    method: "_zencode/usage/subscription",
                    params: .object(["sessionId": .string("pipeline-order")])
                )
            )
        )

        await rawGate.waitUntilArrivals(3)
        await rawGate.release(3)
        await rawGate.release(2)
        await rawGate.release(1)
        await first.value
        await second.value
        await third.value

        #expect(await trace.recordedStarts() == [1, 2, 3])
        let delivered = sink.deliveredMessages()
        #expect(delivered.count == 2)
        let contentMessage = try #require(delivered.first)
        #expect(contentMessage.contains("first unit"))
        #expect(contentMessage.contains("second"))
        let notificationMessage = try #require(delivered.last)
        #expect(notificationMessage.replacingOccurrences(of: "\\/", with: "/")
            .contains("_zencode/usage/subscription"))
    }

    // MARK: - Message ids

    /// One streamed message as it reached the client: the update kind, the
    /// `messageId`, and the text.
    private struct Delivered: Equatable {
        let kind: String
        let messageID: String?
        let text: String?

        init(_ kind: String, _ messageID: String? = nil, _ text: String? = nil) {
            self.kind = kind
            self.messageID = messageID
            self.text = text
        }
    }

    /// Deterministic ids for the messages the pipeline opens: `m1`, `m2`, …
    private final class MessageIDs: Sendable {
        private let counter = Mutex(0)

        func next() -> String {
            counter.withLock { value in
                value += 1
                return "m\(value)"
            }
        }
    }

    private static func update(_ kind: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object = fields
        object["sessionUpdate"] = .string(kind)
        return .object(object)
    }

    private static func thought(_ text: String) -> JSONValue {
        ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_thought_chunk", text: text)
    }

    /// Runs `units` through a pipeline and returns what reached the client,
    /// with the adjacent chunks of one message (same kind and id) joined: how
    /// the buffer splits or merges the text is not what is under test.
    private static func delivered(
        buffering: Bool,
        _ units: [ACPPromptUpdatePipeline.Unit.Kind]
    ) async throws -> [Delivered] {
        let sink = RecordingSink()
        let ids = MessageIDs()
        let pipeline = ACPPromptUpdatePipeline(
            sessionID: "pipeline-ids",
            writer: ACPWriter(sink: sink.sink),
            buffer: ACPPromptUpdateBuffer(now: { Date(timeIntervalSince1970: 0) }),
            buffersUpdates: buffering,
            makeMessageID: { ids.next() }
        )
        for kind in units {
            await pipeline.enqueue(.init(kind: kind)).value
        }
        await pipeline.enqueue(.init(kind: .flush)).value
        var result: [Delivered] = []
        for message in sink.deliveredMessages() {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(message.utf8))
            guard let update = value.objectValue?["params"]?.objectValue?["update"]?.objectValue,
                  let kind = update["sessionUpdate"]?.acpStringValue else { continue }
            let entry = Delivered(
                kind,
                update["messageId"]?.acpStringValue,
                update["content"]?.objectValue?["text"]?.acpStringValue
            )
            if kind == "agent_message_chunk", let last = result.last,
               last.kind == kind, last.messageID == entry.messageID {
                result[result.count - 1] = Delivered(kind, entry.messageID, (last.text ?? "") + (entry.text ?? ""))
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// The text that resumes after a tool call is a new message; the chunks
    /// before it, however the buffer splits them, are one.
    @Test(arguments: [false, true])
    func textAfterAToolCallIsANewMessage(buffering: Bool) async throws {
        let result = try await Self.delivered(buffering: buffering, [
            .consume(Self.chunk("Let me look. ")),
            .consume(Self.chunk("Reading the file.")),
            .consume(Self.update("tool_call", ["toolCallId": .string("call-1")])),
            .consume(Self.update("tool_call_update", ["toolCallId": .string("call-1")])),
            .consume(Self.chunk("Found it.")),
        ])
        #expect(result == [
            Delivered("agent_message_chunk", "m1", "Let me look. Reading the file."),
            Delivered("tool_call"),
            Delivered("tool_call_update"),
            Delivered("agent_message_chunk", "m2", "Found it."),
        ])
    }

    /// A thought, a plan, and a boundary of the model's round each end the
    /// text message; a block of thought is one message, ended by the text.
    @Test(arguments: [false, true])
    func thoughtsPlansAndRoundsSplitTheMessages(buffering: Bool) async throws {
        let result = try await Self.delivered(buffering: buffering, [
            .consume(Self.thought("Think ")),
            .consume(Self.thought("more")),
            .consume(Self.chunk("First answer. ")),
            .consume(Self.thought("Again")),
            .consume(Self.chunk("Second answer.")),
            .consume(Self.update("plan", ["entries": .array([])])),
            .consume(Self.chunk("After the plan.")),
            .finishThought,
            .consume(Self.chunk("Next round.")),
        ])
        #expect(result == [
            Delivered("agent_thought_chunk", "m1", "Think "),
            Delivered("agent_thought_chunk", "m1", "more"),
            Delivered("agent_message_chunk", "m2", "First answer. "),
            Delivered("agent_thought_chunk", "m3", "Again"),
            Delivered("agent_message_chunk", "m4", "Second answer."),
            Delivered("plan"),
            Delivered("agent_message_chunk", "m5", "After the plan."),
            Delivered("agent_message_chunk", "m6", "Next round."),
        ])
    }

    /// Metadata the client does not show in the conversation does not end the
    /// message the text is part of.
    @Test(arguments: [false, true])
    func usageUpdatesDoNotSplitAMessage(buffering: Bool) async throws {
        let result = try await Self.delivered(buffering: buffering, [
            .consume(Self.chunk("Part one, ")),
            .consume(Self.update("usage_update", ["used": .number(1), "size": .number(10)])),
            .consume(Self.chunk("part two.")),
        ])
        let ids = Set(result.filter { $0.kind == "agent_message_chunk" }.map(\.messageID))
        #expect(ids == ["m1"])
        #expect(result.filter { $0.kind == "agent_message_chunk" }.compactMap(\.text).joined() == "Part one, part two.")
    }

    /// A message that arrives with its own id (the configuration summary, the
    /// Summary of the changed files) keeps it and is never joined with the
    /// model's text, which opens a message of its own before and after it.
    @Test(arguments: [false, true])
    func aMessageWithItsOwnIDIsNeverJoinedWithTheModelText(buffering: Bool) async throws {
        let result = try await Self.delivered(buffering: buffering, [
            .consume(ZenCODEACPBridge.textChunkJSONUpdate(
                kind: "agent_message_chunk", text: "Agent: Developer\n\n", messageID: "summary"
            )),
            .consume(Self.chunk("The answer.")),
            .consume(ZenCODEACPBridge.textChunkJSONUpdate(
                kind: "agent_message_chunk", text: "\n\n\n**Summary**\n", messageID: "files"
            )),
            .consume(Self.chunk("A late word.")),
        ])
        #expect(result == [
            Delivered("agent_message_chunk", "summary", "Agent: Developer\n\n"),
            Delivered("agent_message_chunk", "m1", "The answer."),
            Delivered("agent_message_chunk", "files", "\n\n\n**Summary**\n"),
            Delivered("agent_message_chunk", "m2", "A late word."),
        ])
    }

    /// A flush is a boundary too: the delegated tool calls written beside the
    /// pipeline follow it, and the text that comes next is another message.
    @Test(arguments: [false, true])
    func textAfterAFlushIsANewMessage(buffering: Bool) async throws {
        let result = try await Self.delivered(buffering: buffering, [
            .consume(Self.chunk("Before.")),
            .flush,
            .consume(Self.chunk("After.")),
        ])
        #expect(result == [
            Delivered("agent_message_chunk", "m1", "Before."),
            Delivered("agent_message_chunk", "m2", "After."),
        ])
    }
}
