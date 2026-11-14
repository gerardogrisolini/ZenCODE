//
//  MemoryGraphStore+Registry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Dispatch
import Foundation

// MARK: - Identifiers

enum MemoryIdentifier {
    static func makeNew() -> String {
        UUID().uuidString
    }

    static func validated(_ rawIdentifier: String) throws -> String {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }
        return uuid.uuidString
    }
}

enum MemorySource {
    static let tool = "memory.write"
    /// Fallback attribution for injected learn drafts without a source.
    static let learn = "memory.learn"
}

// MARK: - Store registry

/// Process-wide cache of open graph stores, keyed by resolved graph URL. A fresh
/// `MemoryService` per tool execution would otherwise open independent engines
/// over one file and lose each other's updates.
actor MemoryGraphStoreRegistry {
    static let shared = MemoryGraphStoreRegistry()

    /// Executor of the cold-open task (see `MemoryGraphStoreOpenTaskExecutor`).
    private static let openTaskExecutor: any TaskExecutor = MemoryGraphStoreOpenTaskExecutor()

    private var stores: [URL: Task<MemoryGraphStore, Error>] = [:]

    func store(
        graphURL: URL
    ) async throws -> MemoryGraphStore {
        if let pending = stores[graphURL] {
            return try await pending.value
        }

        let task = Task(executorPreference: Self.openTaskExecutor) {
            try await MemoryGraphStore.open(
                graphURL: graphURL
            )
        }
        stores[graphURL] = task
        do {
            return try await task.value
        } catch {
            // A failed open must not be cached, otherwise the workspace stays
            // permanently broken for the lifetime of the process.
            stores[graphURL] = nil
            throw error
        }
    }

    /// Drops cached stores. Used when the support directory is re-pointed.
    func reset() {
        stores.removeAll()
    }

    /// Forgets the cached store for one graph, so the next `store(graphURL:)`
    /// reopens it from disk. Used when the graph's directory is deleted, so a
    /// stale engine can never write the removed graph back. Other graphs stay
    /// cached.
    func remove(graphURL: URL) {
        stores[graphURL] = nil
    }

    /// Flushes every open store, attempting all before throwing the first error,
    /// so one unwritable graph never hides the flush of the others. A durability
    /// barrier for automatic-recall maintenance, which deliberately stays in
    /// memory below its checkpoint threshold; idempotent.
    func flushAll() async throws {
        // Snapshot first: awaiting a store inside the loop would re-enter this
        // actor and could observe a dictionary mutated by `store(graphURL:)`.
        let pendingTasks = Array(stores.values)
        var firstError: (any Error)?
        for task in pendingTasks {
            do {
                try await task.value.flushRecallMaintenance()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

/// Executor of the registry's cold-open task.
///
/// Opening a store does synchronous file-system work on the opening task: the
/// graph file's existence check and the settings read that selects the
/// embedding provider. The task therefore runs on a dedicated dispatch queue,
/// not on Swift's cooperative pool. It is a `Task` rather than
/// `Task.detached`, so it still inherits the caller's task-local
/// support-directory and embedding overrides.
private final class MemoryGraphStoreOpenTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(
        label: "zencode.memory.store-open",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { [self] in
            unownedJob.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
