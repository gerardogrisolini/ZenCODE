//
//  ZenTerminationGate.swift
//  ZenApp
//
//  Answers a quit request the app delegate deferred, exactly once: when the
//  shutdown ends or when the timeout passes, whichever comes first.
//

import Foundation

/// The one answer to a deferred quit request
/// (`NSApplication.TerminateReply.terminateLater`).
///
/// ``start(timeout:shutdown:)`` runs the shutdown and a timer side by side;
/// the first to end settles the gate, which calls the reply once. The other
/// one settles nothing: a timer that fires after the shutdown, or a shutdown
/// that ends after the timeout, does not reply again.
@MainActor
final class ZenTerminationGate {
    /// What settled the gate.
    enum Outcome: Equatable, Sendable {
        /// The shutdown ended in time.
        case shutDown
        /// The timeout passed first.
        case timedOut
    }

    /// The outcome, once the gate settled.
    private(set) var outcome: Outcome?

    private let reply: @MainActor (Outcome) -> Void
    private var shutdownTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    /// - Parameter reply: Called once, with what settled the gate.
    init(reply: @escaping @MainActor (Outcome) -> Void) {
        self.reply = reply
    }

    /// Runs `shutdown` and a timer of `timeout`; the first to end settles
    /// the gate. Later calls do nothing.
    func start(timeout: Duration, shutdown: @escaping @MainActor () async -> Void) {
        guard shutdownTask == nil else { return }
        shutdownTask = Task { @MainActor in
            await shutdown()
            self.settle(.shutDown)
        }
        timerTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.settle(.timedOut)
        }
    }

    /// Settles the gate with `outcome` unless it already settled; `true`
    /// when this call settled it (and replied).
    @discardableResult
    func settle(_ outcome: Outcome) -> Bool {
        guard self.outcome == nil else { return false }
        self.outcome = outcome
        timerTask?.cancel()
        reply(outcome)
        return true
    }
}
