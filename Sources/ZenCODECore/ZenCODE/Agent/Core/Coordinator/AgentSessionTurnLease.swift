//
//  AgentSessionTurnLease.swift
//  ZenCODE
//

import Foundation

/// Serializes prompt turns for each session while allowing independent sessions
/// to proceed concurrently.
///
/// A cancelled waiter is removed from its session queue immediately. The lease
/// is released on every exit from `withLease`, including errors and
/// cancellation observed after acquisition.
actor AgentSessionTurnLease {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var heldSessionIDs: Set<String> = []
    private var waitersBySessionID: [String: [Waiter]] = [:]
    /// Test-only observation seam. It is synchronous so it fires at the exact
    /// point a continuation enters the FIFO queue, rather than eventually from
    /// a task scheduled by the observer.
    private let onWaiterEnqueued: (@Sendable (String) -> Void)?

    init(onWaiterEnqueued: (@Sendable (String) -> Void)? = nil) {
        self.onWaiterEnqueued = onWaiterEnqueued
    }

    func withLease<Result: Sendable>(
        sessionID: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler(
            operation: {
                guard !Task.isCancelled else {
                    return false
                }
                return await self.waitForLease(sessionID: sessionID, waiterID: waiterID)
            },
            onCancel: {
                Task {
                    await self.cancelWaiter(sessionID: sessionID, waiterID: waiterID)
                }
            }
        )
        guard acquired else {
            throw CancellationError()
        }
        defer {
            releaseLease(sessionID: sessionID)
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func waitForLease(sessionID: String, waiterID: UUID) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard heldSessionIDs.contains(sessionID) else {
            heldSessionIDs.insert(sessionID)
            return true
        }
        return await withCheckedContinuation { continuation in
            // Cancellation can race with installation of its handler. Checking
            // again prevents a cancelled task from remaining queued forever.
            guard !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            waitersBySessionID[sessionID, default: []].append(
                Waiter(id: waiterID, continuation: continuation)
            )
            onWaiterEnqueued?(sessionID)
        }
    }

    private func cancelWaiter(sessionID: String, waiterID: UUID) {
        guard var waiters = waitersBySessionID[sessionID],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            waitersBySessionID.removeValue(forKey: sessionID)
        } else {
            waitersBySessionID[sessionID] = waiters
        }
        waiter.continuation.resume(returning: false)
    }

    private func releaseLease(sessionID: String) {
        guard var waiters = waitersBySessionID[sessionID], !waiters.isEmpty else {
            waitersBySessionID.removeValue(forKey: sessionID)
            heldSessionIDs.remove(sessionID)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            waitersBySessionID.removeValue(forKey: sessionID)
        } else {
            waitersBySessionID[sessionID] = waiters
        }
        // Keep the session held while ownership is handed directly to its next
        // waiter; this avoids a gap in which a later turn can overtake it.
        next.continuation.resume(returning: true)
    }
}
