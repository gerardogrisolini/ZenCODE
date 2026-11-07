//
//  ACPToolCallTimer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/11/26.
//

import Foundation
import Synchronization

/// The elapsed time of one prompt's root tool calls, for the title of their
/// completion `tool_call_update` (``ZenCODEACPBridge/toolTitle(_:elapsed:)``).
///
/// One timer per ``ACPPromptPresenter``, hence per prompt: a call records its
/// start when its `tool_call` is presented and takes it back at completion.
/// A call without an id, or a completion without a recorded start (a call
/// cancelled before it was dispatched), has no time. The starts of calls that
/// never complete go away with the prompt's presenter.
final class ACPToolCallTimer: Sendable {
    private let now: @Sendable () -> ContinuousClock.Instant
    private let starts = Mutex<[String: ContinuousClock.Instant]>([:])

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Records that the call `id` started now; an empty id is ignored.
    func start(_ id: String) {
        guard !id.isEmpty else { return }
        let instant = now()
        starts.withLock { $0[id] = instant }
    }

    /// The time since the call `id` started, forgetting its start; `nil`
    /// when no start was recorded for it.
    func complete(_ id: String) -> Duration? {
        guard !id.isEmpty,
              let start = starts.withLock({ $0.removeValue(forKey: id) }) else { return nil }
        return start.duration(to: now())
    }
}
