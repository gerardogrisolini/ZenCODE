//
//  MemoryGraphStore+Registry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

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

    private var stores: [URL: Task<MemoryGraphStore, Error>] = [:]

    func store(
        graphURL: URL
    ) async throws -> MemoryGraphStore {
        if let pending = stores[graphURL] {
            return try await pending.value
        }

        let task = Task(executorPreference: MemoryLegacyBridge.taskExecutor) {
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

    /// Flushes every open store, attempting all before throwing the first error,
    /// so one unwritable graph never hides the flush of the others. A durability
    /// barrier for automatic-recall maintenance, which deliberately stays in
    /// memory below its checkpoint threshold; idempotent, and it ignores unrelated
    /// dirty state such as deferred inserts.
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
