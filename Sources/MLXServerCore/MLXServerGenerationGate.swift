//
//  MLXServerGenerationGate.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation

actor MLXServerGenerationGate {
    private var activeLeaseID: UUID?
    private var waiters: [Waiter] = []

        /// True when no generation holds the gate and none is queued.
    var isIdle: Bool {
        activeLeaseID == nil && waiters.isEmpty
    }

    func acquire() async throws -> MLXServerGenerationLease {
        let leaseID = UUID()
        if activeLeaseID == nil {
            activeLeaseID = leaseID
            return MLXServerGenerationLease(id: leaseID, gate: self)
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: leaseID, continuation: continuation))
            }
        }, onCancel: {
            Task {
                await self.cancelWaiter(id: leaseID)
            }
        })
    }


    fileprivate func release(id: UUID) {
        guard activeLeaseID == id else {
            return
        }
        guard !waiters.isEmpty else {
            activeLeaseID = nil
            return
        }

        let next = waiters.removeFirst()
        activeLeaseID = next.id
        next.continuation.resume(returning: MLXServerGenerationLease(id: next.id, gate: self))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<MLXServerGenerationLease, any Error>
    }
}

struct MLXServerGenerationLease: Sendable {
    fileprivate let id: UUID
    fileprivate let gate: MLXServerGenerationGate

    func release() async {
        await gate.release(id: id)
    }
}
// MARK: - Per-model generation gate

/// An actor that maintains one `MLXServerGenerationGate` per model,
/// allowing concurrent generation for different models while preserving
/// serialization within the same model.
actor MLXServerPerModelGenerationGate {
    private var gates: [String: MLXServerGenerationGate] = [:]

    func acquire(modelID: String) async throws -> MLXServerGenerationLease {
        let gate = gates[modelID] ?? {
            let g = MLXServerGenerationGate()
            gates[modelID] = g
            return g
        }()
        return try await gate.acquire()
    }

            /// True when no generation is active or queued for the model.
    func isIdle(modelID: String) async -> Bool {
        guard let gate = gates[modelID] else {
            return true
        }
        return await gate.isIdle
    }


    /// Acquires every per-model gate that exists at the time of the call.
    /// Uses a snapshot to avoid deadlocks between concurrent `acquireAll()` calls.
    func acquireAll() async throws -> MLXServerGenerationLeaseSet {
        let snapshotIDs = Array(gates.keys).sorted()
        var leases: [MLXServerGenerationLease] = []
        do {
            for modelID in snapshotIDs {
                // Re-read the gate after each suspension: actor state may have
                // changed while awaiting, so never force unwrap here.
                guard let gate = gates[modelID] else {
                    continue
                }
                let lease = try await gate.acquire()
                leases.append(lease)
            }
            return MLXServerGenerationLeaseSet(leases: leases)
        } catch {
            for lease in leases {
                await lease.release()
            }
            throw error
        }
    }
}

/// A collection of leases that is released atomically (one by one).
struct MLXServerGenerationLeaseSet: Sendable {
    fileprivate let leases: [MLXServerGenerationLease]

    func releaseAll() async {
        for lease in leases {
            await lease.release()
        }
    }
}

// MARK: - Keyed generation gate

/// Serializes work independently for each key while removing idle key state,
/// avoiding one retained actor per session identifier.
package actor MLXServerKeyedGenerationGate<Key: Hashable & Sendable> {
    private var activeLeaseIDs: [Key: UUID] = [:]
    private var waiters: [Key: [Waiter]] = [:]

    package init() {}

    package func acquire(
        key: Key
    ) async throws -> MLXServerKeyedGenerationLease<Key> {
        let leaseID = UUID()
        if activeLeaseIDs[key] == nil {
            activeLeaseIDs[key] = leaseID
            return MLXServerKeyedGenerationLease(
                id: leaseID,
                key: key,
                gate: self
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append(
                    Waiter(id: leaseID, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: leaseID, key: key)
            }
        }
    }

    fileprivate func release(id: UUID, key: Key) {
        guard activeLeaseIDs[key] == id else {
            return
        }
        guard var queued = waiters[key], !queued.isEmpty else {
            activeLeaseIDs[key] = nil
            waiters[key] = nil
            return
        }

        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        activeLeaseIDs[key] = next.id
        next.continuation.resume(
            returning: MLXServerKeyedGenerationLease(
                id: next.id,
                key: key,
                gate: self
            )
        )
    }

    private func cancelWaiter(id: UUID, key: Key) {
        guard var queued = waiters[key],
              let index = queued.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<
            MLXServerKeyedGenerationLease<Key>,
            any Error
        >
    }
}

package struct MLXServerKeyedGenerationLease<
    Key: Hashable & Sendable
>: Sendable {
    fileprivate let id: UUID
    fileprivate let key: Key
    fileprivate let gate: MLXServerKeyedGenerationGate<Key>

    package func release() async {
        await gate.release(id: id, key: key)
    }
}
