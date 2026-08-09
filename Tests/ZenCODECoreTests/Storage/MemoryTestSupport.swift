//
//  MemoryTestSupport.swift
//  ZenCODECoreTests
//
//  Shared fixtures for the graph-backed memory suites. Every test points the
//  per-workspace graph at a throwaway support directory through the task-local
//  `AppStorageDirectory` override, so the developer's real `~/.zencode` is
//  never read or written.
//

import Foundation
@testable import ZenCODECore

/// An isolated support directory + workspace pair for one memory graph test.
struct MemoryTestWorkspace {
    let rootURL: URL
    let supportDirectoryURL: URL
    let workspaceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-graph-tests-\(UUID().uuidString)", isDirectory: true)
        supportDirectoryURL = rootURL.appendingPathComponent("support", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: supportDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Removes the throwaway tree. Safe to call from `defer`.
    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Runs `operation` with the support directory scoped to this workspace.
    ///
    /// The override is a task-local, so it is inherited by the unstructured
    /// `Task` that `MemoryGraphStoreRegistry` uses to open the engine, and it
    /// never leaks into concurrently running tests.
    func withIsolatedSupport<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await AppStorageDirectory.withSupportDirectoryURL(supportDirectoryURL) {
            try await operation()
        }
    }

    /// Seeds the workspace with a legacy `MEMORY.md` journal for migration tests.
    func writeLegacyJournal(_ content: String) throws {
        try content.write(
            to: workspaceURL.appendingPathComponent(MemoryService.filename),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Resolves the graph URL for this workspace under the scoped support dir.
    /// Must be called inside `withIsolatedSupport` so the override is honoured.
    func graphURL() -> URL {
        MemoryService().graphURL(workspaceRootURL: workspaceURL)
    }
}
