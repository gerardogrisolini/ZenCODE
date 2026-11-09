//
//  ZenLineStop.swift
//  ZenApp
//
//  The stop of one exclusive line of a window.
//

import Synchronization

/// The stop of one exclusive line, shared by ``ZenWindowSession/stop()``
/// (main actor) and the turn step (chat actor). The stop sets it before it
/// suspends and the step reads it in the same check as the reservation, so
/// a stop that lands before the prompt is even reserved still keeps the
/// line's turn from starting.
final class ZenLineStop: Sendable {
    private let requested = Mutex(false)

    /// The operator stopped the line.
    var isRequested: Bool {
        requested.withLock { $0 }
    }

    func request() {
        requested.withLock { $0 = true }
    }
}
