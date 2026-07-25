//
//  MCPSingleFlight.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Coalesces concurrent callers onto a single in-flight operation while keeping
/// every caller cancellable and fencing results that arrive too late.
///
/// The previous ad-hoc pattern (`if let task { try await task.value }`) had two
/// concrete defects:
///
/// * `Task.value` is not cancellation-aware. A cancelled caller stayed suspended
///   for the full duration of the shared work, so cancelling an MCP connect or
///   an interactive browser sign-in did not return until the network/user
///   finished.
/// * The completion path mutated shared state unconditionally. If the client was
///   torn down (or a newer flight started) while the old one was still running,
///   the late completion clobbered the newer state.
///
/// This type fixes both: each caller holds a ticket that is resumed with
/// `CancellationError` on cancellation, the shared work is cancelled once its
/// last caller withdraws, and a completion is applied only when its generation
/// is still the current one.
public final class MCPSingleFlight<Value: Sendable>: Sendable {
    private struct Waiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Value, Error>
    }

    private struct State {
        var generation: UInt64 = 0
        /// Non-nil while a shared operation is current. Cleared on completion,
        /// invalidation, or withdrawal of the last waiter, which is exactly what
        /// fences a late completion.
        var runningGeneration: UInt64?
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter] = [:]
        /// Tickets cancelled before their continuation was registered.
        var withdrawnTickets: Set<UUID> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// True while a shared operation is in flight.
    public var isRunning: Bool {
        state.withLock { $0.runningGeneration != nil }
    }

    /// Number of callers currently attached to the active flight.
    ///
    /// Internal test visibility lets concurrency tests synchronize on actual
    /// registration rather than assuming a task has run after an arbitrary
    /// delay. It is not part of the public transport API.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Joins the in-flight operation, or starts `operation` when none is running.
    public func run(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let ticket = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(ticket: ticket, continuation: continuation, operation: operation)
            }
        } onCancel: {
            withdraw(ticket: ticket)
        }
    }

    /// Invalidates the current flight: waiters fail with `CancellationError`, the
    /// shared task is cancelled, and its eventual completion is fenced out.
    public func cancel() {
        let (continuations, task) = state.withLock { state -> ([CheckedContinuation<Value, Error>], Task<Void, Never>?) in
            let pending = Array(state.waiters.values.map(\.continuation))
            state.waiters.removeAll()
            state.runningGeneration = nil
            let task = state.task
            state.task = nil
            return (pending, task)
        }
        task?.cancel()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private enum JoinAction {
        case alreadyWithdrawn
        case joined
        case start(UInt64)
    }

    private func join(
        ticket: UUID,
        continuation: CheckedContinuation<Value, Error>,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        let action = state.withLock { state -> JoinAction in
            // Cancellation can fire before the continuation exists; the recorded
            // ticket makes this late registration fail immediately instead of
            // leaking a suspended caller.
            if state.withdrawnTickets.remove(ticket) != nil {
                return .alreadyWithdrawn
            }

            if let runningGeneration = state.runningGeneration {
                state.waiters[ticket] = Waiter(
                    generation: runningGeneration,
                    continuation: continuation
                )
                return .joined
            }

            state.generation &+= 1
            let generation = state.generation
            state.runningGeneration = generation
            state.waiters[ticket] = Waiter(generation: generation, continuation: continuation)
            return .start(generation)
        }

        switch action {
        case .alreadyWithdrawn:
            continuation.resume(throwing: CancellationError())
        case .joined:
            break
        case .start(let generation):
            startTask(generation: generation, operation: operation)
        }
    }

    private func startTask(
        generation: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        state.withLock { state in
            // `join` elected this generation before calling us, but cancellation
            // or invalidation may have won in the meantime. Do not start stale
            // work in that case. Creating and publishing the task under this
            // lock also means cancellation can always find and cancel the task
            // for a current generation.
            guard state.runningGeneration == generation else { return }

            state.task = Task<Void, Never> { [self] in
                let result: Result<Value, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                finish(generation: generation, result: result)
            }
        }
    }

    private func finish(generation: UInt64, result: Result<Value, Error>) {
        let continuations = state.withLock { state -> [CheckedContinuation<Value, Error>] in
            // Fence: a completion from an invalidated or superseded generation
            // must not publish its result or disturb the current flight.
            guard state.runningGeneration == generation else {
                return []
            }
            state.runningGeneration = nil
            state.task = nil
            let matching = state.waiters.filter { $0.value.generation == generation }
            for key in matching.keys {
                state.waiters.removeValue(forKey: key)
            }
            return matching.values.map(\.continuation)
        }

        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func withdraw(ticket: UUID) {
        let (continuation, task) = state.withLock { state -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?) in
            guard let waiter = state.waiters.removeValue(forKey: ticket) else {
                state.withdrawnTickets.insert(ticket)
                return (nil, nil)
            }

            // The shared work exists only to serve its callers: cancel it once
            // the last one withdraws, and invalidate the generation so a result
            // still in flight cannot be published afterwards.
            let hasRemainingWaiters = state.waiters.values.contains {
                $0.generation == waiter.generation
            }
            guard !hasRemainingWaiters,
                  state.runningGeneration == waiter.generation else {
                return (waiter.continuation, nil)
            }

            state.runningGeneration = nil
            let task = state.task
            state.task = nil
            return (waiter.continuation, task)
        }

        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
