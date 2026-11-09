//
//  ZenTurnOutcome.swift
//  ZenApp
//
//  How a turn step of a window ended.
//

import ZenCODECore

/// How a turn step ended.
enum ZenTurnOutcome: Sendable {
    /// The turn ran to its end.
    case finished
    /// The prompt could not be reserved.
    case refused(ChatSessionHostError)
    /// The reservation was dropped (a stop, a close), the line was stopped,
    /// or the line was cancelled before the turn started: it did not start.
    case cancelledBeforeStart
    /// The turn failed or was cancelled while it ran.
    case failed(any Error)
}
