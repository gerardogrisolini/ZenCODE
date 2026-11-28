//
//  ACPPromptUpdateBuffer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore
import ZenCODERuntime

/// Coalesces the text chunks of a prompt turn so the wire carries fewer, larger
/// `agent_message_chunk` updates, without ever changing what a client sees as a
/// message: only chunks of one message (the same `messageId`, or both without
/// one) are merged, and the merged chunk keeps that id. A chunk of another
/// message first writes the text still pending for the previous one.
public final class ACPPromptUpdateBuffer: Sendable {
    /// Minimal deterministic time seam. Production keeps wall-clock `Date()`;
    /// tests inject a controllable clock so window-based flush decisions can
    /// be exercised without real sleeps.
    typealias Clock = @Sendable () -> Date

    private struct State {
        var pendingContent = ""
        /// The message the pending text belongs to.
        var pendingMessageID: String?
        var latestUsageUpdate: JSONValue?
        var lastContentFlushAt: Date
        var lastMetadataFlushAt: Date

        init(now: Date) {
            lastContentFlushAt = now
            lastMetadataFlushAt = now
        }
    }

    private let state: Mutex<State>
    private let now: Clock

    init(now: @escaping Clock = { Date() }) {
        self.now = now
        state = Mutex(State(now: now()))
    }

    public func consume(_ update: JSONValue) -> [JSONValue] {
        state.withLock { state in
            let instant = now()
            guard let object = update.objectValue else {
                return Self.flushAll(now: instant, state: &state) + [update]
            }
            switch object["sessionUpdate"]?.acpStringValue {
            case "agent_message_chunk":
                guard let content = object["content"]?.objectValue,
                      let text = content["text"]?.acpStringValue,
                      !text.isEmpty else {
                    return []
                }
                let messageID = object["messageId"]?.acpStringValue
                // Never merge two messages: the text pending for another one
                // is written first, under its own id.
                var updates: [JSONValue] = []
                if !state.pendingContent.isEmpty, state.pendingMessageID != messageID {
                    updates = Self.flushContentIfNeeded(force: true, now: instant, state: &state)
                }
                state.pendingMessageID = messageID
                state.pendingContent += text
                return updates + Self.flushContentIfNeeded(force: false, now: instant, state: &state)

            case "usage_update":
                state.latestUsageUpdate = update
                // Metadata must never overtake content that was produced before
                // it. When this usage update is actually emitted, any text still
                // pending is flushed first so the wire order keeps matching the
                // order the turn produced.
                let metadata = Self.flushMetadataIfNeeded(force: false, now: instant, state: &state)
                guard !metadata.isEmpty else {
                    return []
                }
                return Self.flushContentIfNeeded(force: true, now: instant, state: &state) + metadata

            default:
                return Self.flushAll(now: instant, state: &state) + [update]
            }
        }
    }

    public func flushAll() -> [JSONValue] {
        state.withLock { state in
            Self.flushAll(now: now(), state: &state)
        }
    }

    private static func flushAll(now: Date, state: inout State) -> [JSONValue] {
        flushContentIfNeeded(force: true, now: now, state: &state)
            + flushMetadataIfNeeded(force: true, now: now, state: &state)
    }

    private static func flushContentIfNeeded(force: Bool, now: Date, state: inout State) -> [JSONValue] {
        guard !state.pendingContent.isEmpty else {
            return []
        }

        let shouldFlush =
            force
            || state.pendingContent.count >= 1536
            || now.timeIntervalSince(state.lastContentFlushAt) >= 0.45
        guard shouldFlush else {
            return []
        }

        let content = state.pendingContent
        let messageID = state.pendingMessageID
        state.pendingContent.removeAll(keepingCapacity: true)
        state.pendingMessageID = nil
        state.lastContentFlushAt = now
        return [
            ZenCODEACPBridge.textChunkJSONUpdate(
                kind: "agent_message_chunk",
                text: content,
                messageID: messageID
            )
        ]
    }

    private static func flushMetadataIfNeeded(force: Bool, now: Date, state: inout State) -> [JSONValue] {
        guard state.latestUsageUpdate != nil else {
            return []
        }

        let shouldFlush =
            force
            || now.timeIntervalSince(state.lastMetadataFlushAt) >= 2.0
        guard shouldFlush else {
            return []
        }

        let usageUpdate = state.latestUsageUpdate
        state.latestUsageUpdate = nil
        state.lastMetadataFlushAt = now

        var updates: [JSONValue] = []
        if let usageUpdate {
            updates.append(usageUpdate)
        }
        return updates
    }
}
