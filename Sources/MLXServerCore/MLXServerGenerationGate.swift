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
                let lease = try await gates[modelID]!.acquire()
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
