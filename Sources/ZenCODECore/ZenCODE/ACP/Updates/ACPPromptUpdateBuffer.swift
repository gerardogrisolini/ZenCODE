//
//  ACPPromptUpdateBuffer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

public final class ACPPromptUpdateBuffer: Sendable {
    private struct State {
        var pendingContent = ""
        var latestUsageUpdate: JSONValue?
        var lastContentFlushAt = Date()
        var lastMetadataFlushAt = Date()
    }

    private let state = Mutex(State())

    public func consume(_ update: JSONValue) -> [JSONValue] {
        state.withLock { state in
            guard let object = update.objectValue else {
                return Self.flushAll(state: &state) + [update]
            }
            switch object["sessionUpdate"]?.acpStringValue {
            case "agent_message_chunk":
                guard let content = object["content"]?.objectValue,
                      let text = content["text"]?.acpStringValue,
                      !text.isEmpty else {
                    return []
                }
                state.pendingContent += text
                return Self.flushContentIfNeeded(force: false, state: &state)

            case "usage_update":
                state.latestUsageUpdate = update
                return Self.flushMetadataIfNeeded(force: false, state: &state)

            default:
                return Self.flushAll(state: &state) + [update]
            }
        }
    }

    public func flushAll() -> [JSONValue] {
        state.withLock { state in
            Self.flushAll(state: &state)
        }
    }

    private static func flushAll(state: inout State) -> [JSONValue] {
        flushContentIfNeeded(force: true, state: &state)
            + flushMetadataIfNeeded(force: true, state: &state)
    }

    private static func flushContentIfNeeded(force: Bool, state: inout State) -> [JSONValue] {
        guard !state.pendingContent.isEmpty else {
            return []
        }

        let now = Date()
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

    private static func flushMetadataIfNeeded(force: Bool, state: inout State) -> [JSONValue] {
        guard state.latestUsageUpdate != nil else {
            return []
        }

        let now = Date()
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
