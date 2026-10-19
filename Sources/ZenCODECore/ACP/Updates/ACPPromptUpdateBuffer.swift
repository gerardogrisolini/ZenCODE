//
//  ACPPromptUpdateBuffer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore

public final class ACPPromptUpdateBuffer: Sendable {
    /// Minimal deterministic time seam. Production keeps wall-clock `Date()`;
    /// tests inject a controllable clock so window-based flush decisions can
    /// be exercised without real sleeps.
    typealias Clock = @Sendable () -> Date

    private struct State {
        var pendingContent = ""
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
                state.pendingContent += text
                return Self.flushContentIfNeeded(force: false, now: instant, state: &state)

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
        state.pendingContent.removeAll(keepingCapacity: true)
        state.lastContentFlushAt = now
        return [
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(content)
                ])
            ])
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
