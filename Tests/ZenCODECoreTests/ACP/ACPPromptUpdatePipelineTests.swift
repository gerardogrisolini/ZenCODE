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

    func unitFinished(_ ordinal: Int) {
        events.append("finish-\(ordinal)")
    }

    func record(_ event: String) {
        events.append(event)
    }

    func recordedStarts() -> [Int] { starts }
    func recordedEvents() -> [String] { events }
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

    /// `drain()` appends a real third barrier unit. Its completion must follow
    /// the tail's finish, and the caller returns only after the barrier finishes.
    @Test
    func drainAppendsBarrierAfterTailBeforeReturning() async {
        let rawGate = RawTaskGate()
        let trace = PipelineTrace()
        let sink = RecordingSink()
        let writer = ACPWriter(sink: sink.sink)
        let pipeline = ACPPromptUpdatePipeline(
            sessionID: "pipeline-drain",
            writer: writer,
            buffer: ACPPromptUpdateBuffer(),
            onTaskStart: { ordinal in await rawGate.park(ordinal) },
            onUnitStart: { ordinal in await trace.unitStarted(ordinal) },
            onUnitFinish: { ordinal in await trace.unitFinished(ordinal) }
        )

        let first = pipeline.enqueue(.init(kind: .consume(Self.chunk("gated"))))
        let tail = pipeline.enqueue(.init(kind: .flush))
        let drainTask = Task {
            await pipeline.drain()
            await trace.record("drain-return")
        }

        await rawGate.waitUntilArrivals(3)
        await rawGate.release(3)
        await rawGate.release(2)
        await rawGate.release(1)
        await first.value
        await tail.value
        await drainTask.value

        #expect(await trace.recordedStarts() == [1, 2, 3])
        #expect(await trace.recordedEvents() == [
            "start-1", "finish-1",
            "start-2", "finish-2",
            "start-3", "finish-3",
            "drain-return"
        ])
        #expect(sink.deliveredMessages().count == 1)
    }
}
