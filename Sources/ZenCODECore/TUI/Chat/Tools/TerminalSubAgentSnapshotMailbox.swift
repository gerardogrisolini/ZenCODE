//
//  TerminalSubAgentSnapshotMailbox.swift
//  ZenCODE
//
//  The mailbox that hands the newest sub-agent snapshots from the task that
//  iterates their stream to the `/subagent` detail controller.
//

import Synchronization

// MARK: - Mailbox

/// The newest snapshots of one stream, handed from the child task that
/// iterates the stream (``pump(_:)``) to the following loop of a
/// ``TerminalSubAgentDetailController`` that applies them (``next()``).
///
/// It keeps only the newest value, and tells whether a value changes the
/// agent's lifecycle from the last value taken (at first, from the lifecycle
/// it was made with); a change seen in a value that a newer one replaced still
/// counts. ``waitForLifecycleChange()`` lets the controller's throttle end as
/// soon as such a value arrives. Every wait ends when its task is cancelled,
/// and nothing polls.
final class TerminalSubAgentSnapshotMailbox: Sendable {
    /// A value taken from the mailbox.
    struct Delivery: Sendable {
        let snapshots: [DirectSubAgentRuntime.AgentSnapshot]
        /// The value, or one it replaced, changes the agent's lifecycle.
        let changesLifecycle: Bool
    }

    private enum Waiter {
        case value
        case lifecycleChange
    }

    private struct State {
        var latest: [DirectSubAgentRuntime.AgentSnapshot]?
        /// The lifecycle of the agent in ``latest``; `nil` without the agent.
        var latestLifecycle: TerminalSubAgentLifecycle?
        /// The lifecycle of the agent in the last value taken that had it.
        var lifecycle: TerminalSubAgentLifecycle?
        /// A value put since the last take changes the lifecycle.
        var changesLifecycle = false
        var isFinished = false
        var valueWaiter: CheckedContinuation<Void, Never>?
        var lifecycleWaiter: CheckedContinuation<Void, Never>?

        func isReady(for waiter: Waiter) -> Bool {
            switch waiter {
            case .value:
                latest != nil || isFinished
            case .lifecycleChange:
                changesLifecycle
            }
        }

        mutating func set(_ continuation: CheckedContinuation<Void, Never>?, for waiter: Waiter) {
            switch waiter {
            case .value:
                valueWaiter = continuation
            case .lifecycleChange:
                lifecycleWaiter = continuation
            }
        }

        mutating func take(_ waiter: Waiter) -> CheckedContinuation<Void, Never>? {
            switch waiter {
            case .value:
                defer { valueWaiter = nil }
                return valueWaiter
            case .lifecycleChange:
                defer { lifecycleWaiter = nil }
                return lifecycleWaiter
            }
        }
    }

    private let agentID: String
    private let state: Mutex<State>

    /// - Parameters:
    ///   - agentID: The agent whose lifecycle the mailbox watches.
    ///   - lifecycle: The lifecycle of the last snapshot the controller
    ///     applied.
    init(agentID: String, lifecycle: TerminalSubAgentLifecycle?) {
        self.agentID = agentID
        state = Mutex(State(lifecycle: lifecycle))
    }

    /// Iterates `stream` until it finishes or the task is cancelled, keeping
    /// its newest value, then finishes the mailbox.
    func pump(_ stream: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>) async {
        for await snapshots in stream {
            put(snapshots)
        }
        finish()
    }

    /// Replaces the value not taken yet with `snapshots`, and wakes the waits
    /// it satisfies.
    func put(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        let lifecycle = snapshots.first { $0.id == agentID }.map(TerminalSubAgentLifecycle.init)
        let waiters = state.withLock { state in
            state.latest = snapshots
            state.latestLifecycle = lifecycle
            if let lifecycle, lifecycle != state.lifecycle {
                state.changesLifecycle = true
            }
            let lifecycleWaiter = state.changesLifecycle ? state.take(.lifecycleChange) : nil
            return (state.take(.value), lifecycleWaiter)
        }
        waiters.0?.resume()
        waiters.1?.resume()
    }

    /// No value comes any more: ``next()`` answers the one not taken yet,
    /// then `nil`.
    func finish() {
        let waiter = state.withLock { state in
            state.isFinished = true
            return state.take(.value)
        }
        waiter?.resume()
    }

    /// The newest value not taken yet, waiting for one; `nil` once the
    /// mailbox finished with nothing left, or when the task is cancelled.
    func next() async -> Delivery? {
        while !Task.isCancelled {
            let delivery = state.withLock { state -> Delivery?? in
                if let latest = state.latest {
                    let delivery = Delivery(snapshots: latest, changesLifecycle: state.changesLifecycle)
                    if let latestLifecycle = state.latestLifecycle {
                        state.lifecycle = latestLifecycle
                    }
                    state.latest = nil
                    state.latestLifecycle = nil
                    state.changesLifecycle = false
                    return .some(delivery)
                }
                return state.isFinished ? .some(nil) : nil
            }
            if let delivery {
                return delivery
            }
            await wait(for: .value)
        }
        return nil
    }

    /// Returns once a value that changes the agent's lifecycle waits to be
    /// taken, or when the task is cancelled.
    func waitForLifecycleChange() async {
        await wait(for: .lifecycleChange)
    }

    private func wait(for waiter: Waiter) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Under the lock, so a cancellation either finds the stored
                // continuation or is seen here.
                let resumesNow = state.withLock { state -> Bool in
                    if state.isReady(for: waiter) || Task.isCancelled {
                        return true
                    }
                    state.set(continuation, for: waiter)
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.take(waiter) }?.resume()
        }
    }
}
