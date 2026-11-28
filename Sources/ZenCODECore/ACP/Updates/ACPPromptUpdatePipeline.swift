//
//  ACPPromptUpdatePipeline.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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
//  The pipeline also owns the `messageId` of what streams through it. A text
//  chunk of the model (or a thought) is written by the presenter without one;
//  the pipeline, which sees every update of the turn in wire order, gives it
//  the id of the message it belongs to, and that message is one continuous
//  stretch of the same stream: the text of the model, or a block of thought.
//  It ends, and the next chunk opens a message with a new id, when anything
//  else visible comes between (a thought, a tool call, a plan, a boundary of a
//  model round or of the turn). A chunk that already carries an id is a message
//  of its own and keeps it.
//

import Foundation
import Synchronization
import ToolCore
import ZenCODERuntime

final class ACPPromptUpdatePipeline: Sendable {
    /// One serialized unit of work that ends in zero or more writer calls.
    struct Unit: Sendable {
        enum Kind: Sendable {
            /// Consume one update, optionally format reasoning and buffer it.
            case consume(JSONValue)
            /// Flush the buffer, then write what it emits. What is written next
            /// is another message.
            case flush
            /// End a model reasoning segment without flushing unrelated content.
            /// A model round or the turn ended: the open streamed messages end
            /// too, so the text that follows is a new message.
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

    /// The streamed messages the turn has open: the ids the next chunk of
    /// that stream still belongs to. Only the unit that is running touches
    /// them (units run one at a time, in order).
    private struct OpenMessages {
        var text: String?
        var thought: String?
    }

    private enum ChunkStream {
        case text
        case thought
    }

    private let openMessages = Mutex<OpenMessages>(OpenMessages())
    private let makeMessageID: @Sendable () -> String
    let buffer: ACPPromptUpdateBuffer
    private let writer: ACPWriter
    private let sessionID: String
    private let buffersUpdates: Bool
    private let isValid: @Sendable () async -> Bool
    private let canDeliver: @Sendable () async -> Bool
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
        isValid: @escaping @Sendable () async -> Bool = { true },
        canDeliver: @escaping @Sendable () async -> Bool = { true },
        makeMessageID: @escaping @Sendable () -> String = { ZenCODEACPBridge.newMessageID() },
        onTaskStart: (@Sendable (Int) async -> Void)? = nil,
        onUnitStart: (@Sendable (Int) async -> Void)? = nil,
        onUnitFinish: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.writer = writer
        self.buffer = buffer
        self.buffersUpdates = buffersUpdates
        self.isValid = isValid
        self.canDeliver = canDeliver
        self.makeMessageID = makeMessageID
        self.thoughtNormalizer = Mutex(normalizesChatGPTThoughts ? ACPChatGPTThoughtNormalizer() : nil)
        self.onTaskStart = onTaskStart
        self.onUnitStart = onUnitStart
        self.onUnitFinish = onUnitFinish
    }

    /// Enqueues one unit and returns the task that runs it. Awaiting the
    /// returned task waits for this unit specifically, so a final result can
    /// never overtake updates enqueued before it.
    @discardableResult
    /// `onAccepted` acknowledges consume units only after admission and buffer/
    /// writer processing. Rejection by the prompt fence never acknowledges.
    /// Accepted buffered content remains owned by this pipeline's close flush;
    /// delivery still uses the separate incarnation fence.
    func enqueue(_ unit: Unit, onAccepted: (@Sendable () async -> Void)? = nil) -> Task<Void, Never> {
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
                await self.run(unit, ordinal: ordinal, onAccepted: onAccepted)
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

    @discardableResult
    private func writeUpdate(_ update: JSONValue) async -> Bool {
        let updates = buffersUpdates ? buffer.consume(update) : [update]
        for update in updates {
            guard await canDeliver() else { return false }
            await writer.sendSessionUpdate(sessionID: sessionID, update: update)
        }
        return true
    }

    /// The text chunk `update` with the `messageId` of the message it belongs
    /// to. A chunk that has one already is a message of its own: it keeps its
    /// id and ends the streamed messages. Otherwise it continues the open
    /// message of its stream, or opens one with a new id, and ends the open
    /// message of the other stream.
    private func taggingMessageID(_ update: JSONValue, as stream: ChunkStream) -> JSONValue {
        guard case var .object(fields) = update else { return update }
        let messageID: String = openMessages.withLock { open in
            if let explicit = fields["messageId"]?.acpStringValue {
                open = OpenMessages()
                return explicit
            }
            switch stream {
            case .text:
                open.thought = nil
                if let id = open.text { return id }
                let id = makeMessageID()
                open.text = id
                return id
            case .thought:
                open.text = nil
                if let id = open.thought { return id }
                let id = makeMessageID()
                open.thought = id
                return id
            }
        }
        fields["messageId"] = .string(messageID)
        return .object(fields)
    }

    /// Ends the open streamed messages: what streams next opens a new one.
    private func closeStreamedMessages() {
        openMessages.withLock { $0 = OpenMessages() }
    }

    /// Whether an update of this kind, written between two text chunks, ends
    /// the message they would share: anything the client shows as something
    /// else. Metadata the client does not show in the conversation does not.
    private static func interruptsStreamedMessages(_ kind: String?) -> Bool {
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk",
             "usage_update", "available_commands_update", "config_option_update", "session_info_update":
            return false
        default:
            return true
        }
    }

    private func finishThought() async {
        let suffix = thoughtNormalizer.withLock { $0?.finish() ?? "" }
        if !suffix.isEmpty {
            await writeUpdate(taggingMessageID(
                ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_thought_chunk", text: suffix),
                as: .thought
            ))
        }
        // The block of thought ends: the next one is another message.
        openMessages.withLock { $0.thought = nil }
    }

    private func run(_ unit: Unit, ordinal: Int, onAccepted: (@Sendable () async -> Void)?) async {
        if let onUnitStart {
            await onUnitStart(ordinal)
        }
        switch unit.kind {
        case let .consume(update):
            // Fence admission, not delivery: close must flush accepted content.
            guard await isValid() else { return }
            let kind = update.objectValue?["sessionUpdate"]?.acpStringValue
            if kind == "agent_message_chunk" || kind == "tool_call" {
                await finishThought()
            }
            var accepted = true
            if kind == "agent_thought_chunk" {
                let text = update.objectValue?["content"]?.objectValue?["text"]?.acpStringValue
                if let text, let normalized = thoughtNormalizer.withLock({ $0?.consume(text) }) {
                    if !normalized.isEmpty {
                        accepted = await writeUpdate(taggingMessageID(
                            ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_thought_chunk", text: normalized),
                            as: .thought
                        ))
                    }
                } else {
                    accepted = await writeUpdate(taggingMessageID(update, as: .thought))
                }
            } else if kind == "agent_message_chunk" {
                accepted = await writeUpdate(taggingMessageID(update, as: .text))
            } else {
                if Self.interruptsStreamedMessages(kind) {
                    closeStreamedMessages()
                }
                accepted = await writeUpdate(update)
            }
            if accepted, let onAccepted { await onAccepted() }
        case .finishThought:
            // The end of a model round or of the turn: what streams next is
            // another message.
            await finishThought()
            closeStreamedMessages()
        case .flush:
            await finishThought()
            // Something is about to be written outside the stream, or the turn
            // ends: the text that follows is another message.
            closeStreamedMessages()
            for bufferedUpdate in buffer.flushAll() {
                guard await canDeliver() else { return }
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: bufferedUpdate
                )
            }
        case let .flushThenNotify(method, params):
            for bufferedUpdate in buffer.flushAll() {
                guard await canDeliver() else { return }
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: bufferedUpdate
                )
            }
            guard await isValid() else { return }
            await writer.sendCustomNotification(method: method, params: params)
        case .barrier:
            break
        }
        if let onUnitFinish {
            await onUnitFinish(ordinal)
        }
    }
}
