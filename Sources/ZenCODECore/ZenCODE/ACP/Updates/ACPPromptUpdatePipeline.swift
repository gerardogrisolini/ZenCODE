//
//  ACPPromptUpdatePipeline.swift
//  ZenCODE
//
//  Serializes app-mode and ChatGPT thinking prompt-update units leaving the ACP
//  prompt path for one writer. Callbacks reaching `onEvent` are `@Sendable` and can overlap
//  arbitrarily: without this choke point, two concurrent units could interleave
//  their "drain buffer" and "write wire" steps, and a notification emitted by a
//  later callback could reach the host ahead of buffered content an earlier
//  callback had already claimed.
//
//  The chain is a `Mutex<Task>` tail: acquiring the lock fixes the unit's
//  position in the chain, so the wire order equals the enqueue order regardless
//  of how the cooperative pool schedules the tasks. No public wire format or
//  API changes: the bridge routes the same `consume`/`flush` calls through this
//  single serialized point.
//

import Foundation
import Synchronization
import ToolCore

final class ACPPromptUpdatePipeline: Sendable {
    /// One serialized unit of work that ends in zero or more writer calls.
    struct Unit: Sendable {
        enum Kind: Sendable {
            /// Consume one update, optionally format reasoning and buffer it.
            case consume(JSONValue)
            /// Flush the buffer, then write what it emits.
            case flush
            /// End a model reasoning segment without flushing unrelated content.
            case finishThought
            /// Flush the buffer, then write one custom notification after it.
            case flushThenNotify(method: String, params: JSONValue)
            /// A no-op unit used to establish a chain barrier for `drain()`.
            case barrier
        }

        let kind: Kind
    }

    private let state = Mutex<State>(State())

    private struct State {
        var tail: Task<Void, Never>?
        var nextOrdinal = 1
    }

    let buffer: ACPPromptUpdateBuffer
    private let writer: ACPWriter
    private let sessionID: String
    private let buffersUpdates: Bool
    private let thoughtNormalizer: Mutex<ACPChatGPTThoughtNormalizer?>
    /// Test seam invoked by every raw task before it awaits its predecessor.
    /// It proves that all task bodies may be scheduled in any order while the
    /// writer-facing unit execution remains ordered by the predecessor chain.
    private let onTaskStart: (@Sendable (Int) async -> Void)?
    /// Test seam invoked after the predecessor completed, before writer calls.
    private let onUnitStart: (@Sendable (Int) async -> Void)?
    /// Test seam invoked after a unit has finished its writer work.
    private let onUnitFinish: (@Sendable (Int) async -> Void)?

    init(
        sessionID: String,
        writer: ACPWriter,
        buffer: ACPPromptUpdateBuffer,
        buffersUpdates: Bool = true,
        normalizesChatGPTThoughts: Bool = false,
        onTaskStart: (@Sendable (Int) async -> Void)? = nil,
        onUnitStart: (@Sendable (Int) async -> Void)? = nil,
        onUnitFinish: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.writer = writer
        self.buffer = buffer
        self.buffersUpdates = buffersUpdates
        self.thoughtNormalizer = Mutex(normalizesChatGPTThoughts ? ACPChatGPTThoughtNormalizer() : nil)
        self.onTaskStart = onTaskStart
        self.onUnitStart = onUnitStart
        self.onUnitFinish = onUnitFinish
    }

    /// Enqueues one unit and returns the task that runs it. Awaiting the
    /// returned task waits for this unit specifically, so a final result can
    /// never overtake updates enqueued before it.
    @discardableResult
    func enqueue(_ unit: Unit) -> Task<Void, Never> {
        state.withLock { state -> Task<Void, Never> in
            let predecessor = state.tail
            let ordinal = state.nextOrdinal
            state.nextOrdinal += 1
            let task = Task(name: "ZenCODEACP.prompt-update-pipeline") {
                if let onTaskStart {
                    await onTaskStart(ordinal)
                }
                if let predecessor {
                    await predecessor.value
                }
                await self.run(unit, ordinal: ordinal)
            }
            state.tail = task
            return task
        }
    }

    /// Appends and waits for an explicit chain barrier. This fixes the drain's
    /// position atomically under the same mutex as updates, so the final result
    /// cannot overtake work enqueued before the drain call.
    func drain() async {
        await enqueue(.init(kind: .barrier)).value
    }

    private func writeUpdate(_ update: JSONValue) async {
        let updates = buffersUpdates ? buffer.consume(update) : [update]
        for update in updates {
            await writer.sendSessionUpdate(sessionID: sessionID, update: update)
        }
    }

    private func finishThought() async {
        let suffix = thoughtNormalizer.withLock { $0?.finish() ?? "" }
        guard !suffix.isEmpty else { return }
        await writeUpdate(ZenCODEACPBridge.textChunkJSONUpdate(
            kind: "agent_thought_chunk", text: suffix
        ))
    }

    private func run(_ unit: Unit, ordinal: Int) async {
        if let onUnitStart {
            await onUnitStart(ordinal)
        }
        switch unit.kind {
        case let .consume(update):
            let kind = update.objectValue?["sessionUpdate"]?.acpStringValue
            if kind == "agent_message_chunk" || kind == "tool_call" {
                await finishThought()
            }
            if kind == "agent_thought_chunk",
               let text = update.objectValue?["content"]?.objectValue?["text"]?.acpStringValue {
                let normalized = thoughtNormalizer.withLock { $0?.consume(text) }
                if let normalized {
                    if !normalized.isEmpty {
                        await writeUpdate(ZenCODEACPBridge.textChunkJSONUpdate(
                            kind: "agent_thought_chunk", text: normalized
                        ))
                    }
                } else {
                    await writeUpdate(update)
                }
            } else {
                await writeUpdate(update)
            }
        case .finishThought:
            await finishThought()
        case .flush:
            await finishThought()
            for bufferedUpdate in buffer.flushAll() {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: bufferedUpdate
                )
            }
        case let .flushThenNotify(method, params):
            for bufferedUpdate in buffer.flushAll() {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: bufferedUpdate
                )
            }
            await writer.sendCustomNotification(method: method, params: params)
        case .barrier:
            break
        }
        if let onUnitFinish {
            await onUnitFinish(ordinal)
        }
    }
}
