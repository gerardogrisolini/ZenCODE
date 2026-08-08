//
//  MemoryLegacyCompatibility.swift
//  ZenCODE
//
//  Source compatibility layer for the pre-graph (1.1.4 / 3003ddc) memory API.
//
//  Before the graph migration `MemoryService` read and wrote `MEMORY.md`
//  synchronously, so every public entry point was a *synchronous* function
//  taking a `scope:` argument. The graph store is actor-backed, so the primary
//  API is now async and drops `scope:` (only `.project` is backed by a
//  per-workspace graph).
//
//  The modern tool entry point is `MemoryTool.executeAsync`.  It was renamed
//  from `execute` so that the legacy synchronous `execute` — the exact 1.1.x
//  spelling — is the *only* `execute` overload.  This means `try
//  MemoryTool.execute(…)` compiles unchanged everywhere, including inside an
//  async function where a same-named async/sync pair would have forced `await`.
//
//  **Timeout semantics.**  Reads use a bounded wait and may be abandoned (a
//  late read result is harmless).  Mutations go through a commit-gate
//  (`MemoryLegacyBridge.runBlockingMutation`) that never abandons while the
//  work may still commit — it waits for the definitive outcome instead.
//
//  Every legacy spelling below is the exact signature that existed at 3003ddc,
//  including its effects (`throws` vs non-throwing) and its return type, so
//  pre-existing call sites compile unchanged and only emit a deprecation
//  warning.
//
//  None of this exposes ZenMemory: the wrappers speak only in ZenCODECore DTOs.
//

import Foundation
import Synchronization
import ToolCore

// MARK: - Bounded blocking bridge

/// Failure raised when a deprecated synchronous wrapper cannot finish within
/// its bounded budget.
public enum MemoryLegacyBridgeError: LocalizedError {
    /// A **read** exceeded its bounded budget and was abandoned.
    ///
    /// This is safe for reads: a late result is harmless because reads have no
    /// durable side-effect.  It must never be used for mutations.
    case timedOut(operation: String, seconds: TimeInterval)

    /// A **mutation** could not produce a definitive outcome even after the
    /// extended wait.  This should be unreachable in practice (actor operations
    /// are finite) but is declared so every code path returns an honest error.
    case outcomeUndetermined(operation: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(operation, seconds):
            return """
            The deprecated synchronous memory API '\(operation)' did not complete within \(Int(seconds))s \
            and was abandoned. Call the async memory API instead.
            """
        case let .outcomeUndetermined(operation, seconds):
            return """
            The deprecated synchronous memory API '\(operation)' did not produce a definitive outcome \
            within \(Int(seconds))s. The mutation may or may not have committed; call the async memory \
            API and verify state before retrying.
            """
        }
    }
}

/// Runs async work from a synchronous caller with a bounded wait.
///
/// Deadlock safety, and its limits, precisely:
///
/// * The work runs on the concurrency pool; the caller's thread is the only one
///   that blocks. Nothing in the memory path is `@MainActor`, and the graph is
///   reached through plain `actor`s, so blocking the main thread here cannot
///   deadlock against the work itself.
/// * The wait is **bounded**. If the budget expires the pending task is
///   cancelled and a diagnosable error is thrown, so a pathological case
///   degrades into a visible failure instead of an unbounded hang.
/// * The task is unstructured but **not detached**, so when a legacy sync call
///   is made from inside an async context it still inherits the caller's
///   task-locals (this is what keeps the `AppStorageDirectory` scoping used by
///   tests and embedders intact).
///
/// Residual risk: calling this from an async context parks one cooperative
/// thread for the duration. That is why every wrapper using it is deprecated —
/// async callers should call the async API directly.
enum MemoryLegacyBridge {
    /// Generous enough for a cold graph open plus an embedding pass, small
    /// enough that a stuck call surfaces instead of hanging a session.
    static let defaultTimeout: TimeInterval = 60

    private final class ResultBox<Value: Sendable>: Sendable {
        private let storage = Mutex<Result<Value, any Error>?>(nil)

        func set(_ result: Result<Value, any Error>) {
            storage.withLock { $0 = result }
        }

        func take() -> Result<Value, any Error>? {
            storage.withLock { $0 }
        }
    }

    static func runBlocking<Value: Sendable>(
        _ operation: String,
        timeout: TimeInterval = defaultTimeout,
        work: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success,
              let result = box.take() else {
            task.cancel()
            throw MemoryLegacyBridgeError.timedOut(operation: operation, seconds: timeout)
        }
        return try result.get()
    }

    /// Read-shaped variant: the 1.1.x read API was non-throwing and answered
    /// with `[]` for anything it could not produce, so failures are absorbed.
    static func runBlockingRead<Value: Sendable>(
        _ operation: String,
        fallback: Value,
        timeout: TimeInterval = defaultTimeout,
        work: @escaping @Sendable () async throws -> Value
    ) -> Value {
        (try? runBlocking(operation, timeout: timeout, work: work)) ?? fallback
    }

    /// Mutation-safe variant: **never abandons while the work may still
    /// commit**.
    ///
    /// Reads can safely absorb a timeout because a late result is harmless.
    /// Mutations cannot: a write that commits *after* the caller has already
    /// received an "abandoned" error is a silent, durable side-effect the
    /// caller cannot reconcile.  This method therefore splits the wait in two
    /// phases:
    ///
    /// 1. **Bounded wait** — same budget as ``runBlocking``.  Most operations
    ///    finish here and the result is returned immediately.
    /// 2. **Definitive-outcome wait** — if the budget expires the bridge keeps
    ///    waiting for the task's actual result **without cancelling it**.
    ///    Cancelling would interrupt the in-flight operation and prevent the
    ///    commit, which defeats the purpose.  The caller never sees
    ///    "abandoned"; only the true success or the true failure of the
    ///    operation.
    ///
    /// Contract: **a mutation timeout never produces a durable side-effect
    /// reported as abandoned**.  Either the mutation commits and the caller
    /// sees the commit, or the mutation fails and the caller sees the failure.
    ///
    /// - Note: Phase 2 is an unbounded wait.  Actor operations are finite, so
    ///   in practice the task always finishes.  If the underlying store hung,
    ///   the bridge would block — but that is a store bug, and a silent late
    ///   commit would be strictly worse.
    static func runBlockingMutation<Value: Sendable>(
        _ operation: String,
        timeout: TimeInterval = defaultTimeout,
        work: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        _ = Task {
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        // Phase 1 — bounded wait for a fast completion.
        if semaphore.wait(timeout: .now() + timeout) == .success,
           let result = box.take() {
            return try result.get()
        }

        // Phase 2 — the budget expired but the mutation may still commit.
        // Do NOT cancel: cancelling would interrupt the operation and
        // suppress the very commit we need to observe.  Wait for the
        // definitive outcome instead.
        semaphore.wait()

        guard let result = box.take() else {
            // Unreachable: the task always sets the box before signalling.
            throw MemoryLegacyBridgeError.outcomeUndetermined(
                operation: operation, seconds: timeout
            )
        }
        return try result.get()
    }
}

// MARK: - MemoryEntry.normalizedContent

extension MemoryEntry {
    /// Normalization helper that existed on `MemoryEntry` before it moved to
    /// the shared `MemoryContent` namespace. Behaviourally identical.
    @available(
        *,
        deprecated,
        renamed: "MemoryContent.normalized(_:)",
        message: "Use MemoryContent.normalized(_:); this shim is kept for 1.1.x source compatibility."
    )
    public static func normalizedContent(_ content: String) -> String {
        MemoryContent.normalized(content)
    }
}

// MARK: - MemoryService: legacy synchronous surface

extension MemoryService {

    // MARK: Reads
    //
    // 1.1.x reads were non-throwing. A nil directory produced no memory
    // document at all, and `memoryDocuments` returned `[]`, so a nil directory
    // read as "no entries" rather than as an error. That contract is preserved
    // here verbatim; only the *mutating* legacy API reported
    // `scopeUnavailable`. The modern async `readEntries(workspaceRootURL:…)`
    // deliberately keeps throwing, which is what the tool layer relies on.

    @available(
        *,
        deprecated,
        message: "Use the async readEntries(workspaceRootURL:includeArchived:limit:)."
    )
    public func readEntries(
        scope: MemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        legacyReadEntries(
            scope: scope,
            workspaceRootURL: workingDirectory,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    @available(
        *,
        deprecated,
        message: "Use the async readEntries(workspaceRootURL:includeArchived:limit:)."
    )
    public func readEntries(
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        legacyReadEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    @available(
        *,
        deprecated,
        message: "Use the async searchEntries(query:workspaceRootURL:includeArchived:limit:)."
    )
    public func searchEntries(
        query: String,
        scope: MemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        legacySearchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workingDirectory,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    @available(
        *,
        deprecated,
        message: "Use the async searchEntries(query:workspaceRootURL:includeArchived:limit:)."
    )
    public func searchEntries(
        query: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        legacySearchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    private func legacyReadEntries(
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool,
        limit: Int
    ) -> [MemoryEntry] {
        // No document for this scope/root pair => legacy answered `[]`.
        guard Self.legacyScopeMatchesProject(scope),
              let root = workspaceRootURL?.standardizedFileURL else {
            return []
        }
        return MemoryLegacyBridge.runBlockingRead(
            "MemoryService.readEntries(scope:…)",
            fallback: []
        ) { [self] in
            try await readEntries(
                workspaceRootURL: root,
                includeArchived: includeArchived,
                limit: limit
            )
        }
    }

    private func legacySearchEntries(
        query: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool,
        limit: Int
    ) -> [MemoryEntry] {
        guard Self.legacyScopeMatchesProject(scope),
              let root = workspaceRootURL?.standardizedFileURL else {
            return []
        }
        // 1.1.x ranking extracted no terms from a blank query and fell through
        // to "first `limit` entries" instead of failing. The async API rejects
        // a blank query, so the legacy path is routed around it.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return legacyReadEntries(
                scope: scope,
                workspaceRootURL: root,
                includeArchived: includeArchived,
                limit: limit
            )
        }
        return MemoryLegacyBridge.runBlockingRead(
            "MemoryService.searchEntries(query:scope:…)",
            fallback: []
        ) { [self] in
            try await searchEntries(
                query: query,
                workspaceRootURL: root,
                includeArchived: includeArchived,
                limit: limit
            )
        }
    }

    /// `.project` is the only scope ZenCODECore ever exposed, and `nil` meant
    /// "any scope" for the 1.1.x read/archive entry points.
    private static func legacyScopeMatchesProject(_ scope: MemoryScope?) -> Bool {
        scope == nil || scope == .project
    }

    // MARK: Mutations

    @available(
        *,
        deprecated,
        message: "Use the async writeEntry(content:workspaceRootURL:category:tags:)."
    )
    @discardableResult
    public func writeEntry(
        content: String,
        scope: MemoryScope,
        workingDirectory: URL?
    ) throws -> MemoryEntry {
        try legacyWriteEntry(content: content, workspaceRootURL: workingDirectory)
    }

    @available(
        *,
        deprecated,
        message: "Use the async writeEntry(content:workspaceRootURL:category:tags:)."
    )
    @discardableResult
    public func writeEntry(
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        try legacyWriteEntry(content: content, workspaceRootURL: workspaceRootURL)
    }

    private func legacyWriteEntry(
        content: String,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        return try MemoryLegacyBridge.runBlockingMutation("MemoryService.writeEntry(content:scope:…)") { [self] in
            try await writeEntry(content: content, workspaceRootURL: root)
        }
    }

    /// In-place content update preserving the entry id, its creation date and
    /// its archive state. Matches the 1.1.x behaviour of keeping the original
    /// `Timestamp` and stamping `Updated` when the caller omits them.
    @available(
        *,
        deprecated,
        message: "Use the async updateEntry(id:content:workspaceRootURL:tags:updatedAt:timeZone:)."
    )
    @discardableResult
    public func updateEntry(
        id: UUID,
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?,
        updatedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> MemoryEntry {
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        return try MemoryLegacyBridge.runBlockingMutation("MemoryService.updateEntry(id:content:scope:…)") { [self] in
            try await updateEntry(
                id: id.uuidString,
                content: content,
                workspaceRootURL: root,
                tags: nil,
                updatedAt: updatedAt,
                timeZone: timeZone
            )
        }
    }

    /// Overwrites the stored content of an entry.
    ///
    /// Known deviation from 1.1.4: the journal implementation assigned the
    /// normalized content verbatim, so a replacement without a `Timestamp:` /
    /// `Updated:` line stayed without one. The graph store owns the only
    /// in-place content mutation and always applies the journal metadata rule,
    /// and `MemoryGraphStore` is out of scope for this change, so a replacement
    /// whose content omits those lines now gets them stamped. Content that
    /// already carries both is byte-identical to the legacy result.
    @available(
        *,
        deprecated,
        message: """
        Use the async updateEntry(id:content:workspaceRootURL:tags:updatedAt:timeZone:). \
        Unlike 1.1.4, replacement content without Timestamp/Updated lines is stamped.
        """
    )
    @discardableResult
    public func replaceEntry(
        id: UUID,
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        return try MemoryLegacyBridge.runBlockingMutation("MemoryService.replaceEntry(id:content:scope:…)") { [self] in
            try await updateEntry(
                id: id.uuidString,
                content: content,
                workspaceRootURL: root,
                tags: nil
            )
        }
    }

    @available(
        *,
        deprecated,
        message: "Use the async archiveEntry(id:workspaceRootURL:)."
    )
    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MemoryScope?,
        workingDirectory: URL?
    ) throws -> MemoryEntry {
        try legacyArchiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workingDirectory
        )
    }

    @available(
        *,
        deprecated,
        message: "Use the async archiveEntry(id:workspaceRootURL:)."
    )
    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        try legacyArchiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workspaceRootURL
        )
    }

    private func legacyArchiveEntry(
        id rawIdentifier: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        // 1.1.x rejected a malformed id before it looked at any document.
        guard let id = UUID(uuidString: rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }
        guard Self.legacyScopeMatchesProject(scope) else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        return try MemoryLegacyBridge.runBlockingMutation("MemoryService.archiveEntry(id:scope:…)") { [self] in
            try await archiveEntry(id: id.uuidString, workspaceRootURL: root)
        }
    }

    @available(
        *,
        deprecated,
        message: "Use the async setArchived(_:id:workspaceRootURL:)."
    )
    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: UUID,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        return try MemoryLegacyBridge.runBlockingMutation("MemoryService.setArchived(_:id:scope:…)") { [self] in
            try await setArchived(isArchived, id: id.uuidString, workspaceRootURL: root)
        }
    }

    @available(
        *,
        deprecated,
        message: "Use the async deleteEntry(id:workspaceRootURL:)."
    )
    public func deleteEntry(
        id: UUID,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws {
        let root = try Self.legacyRequiredRoot(workspaceRootURL)
        try MemoryLegacyBridge.runBlockingMutation("MemoryService.deleteEntry(id:scope:…)") { [self] in
            try await deleteEntry(id: id.uuidString, workspaceRootURL: root)
        }
    }

    /// 1.1.x mutations reported `scopeUnavailable("project")` when the project
    /// scope had no working directory. Preserved exactly.
    private static func legacyRequiredRoot(_ workspaceRootURL: URL?) throws -> URL {
        guard let workspaceRootURL else {
            throw MemoryServiceError.scopeUnavailable("project")
        }
        return workspaceRootURL.standardizedFileURL
    }
}

// MARK: - MemoryTool: legacy synchronous execute

extension MemoryTool {
    /// The 1.1.4 synchronous `execute`.
    ///
    /// The modern entry point is ``executeAsync(_:context:memoryService:)``.
    /// Renaming it avoids the async/sync overload ambiguity that would
    /// otherwise force legacy `try MemoryTool.execute(…)` call sites to add
    /// `await` inside an async context.  This wrapper is the sole `execute`,
    /// so `try MemoryTool.execute(…)` compiles unchanged everywhere — sync or
    /// async.
    ///
    /// **Timeout semantics.**  Reads use a bounded wait and can be abandoned
    /// (a late read result is harmless).  Mutations use
    /// ``MemoryLegacyBridge/runBlockingMutation(_:timeout:work:)``, which never
    /// abandons while the work may still commit: on timeout it keeps waiting
    /// for the definitive outcome without cancelling.  No mutation can
    /// become durable after an error that says "abandoned".
    @available(
        *,
        deprecated,
        message: "Use MemoryTool.executeAsync(_:context:memoryService:); this wrapper blocks the calling thread."
    )
    public static func execute(
        _ request: ToolRequest,
        context: MemoryToolContext,
        memoryService: MemoryService = MemoryService()
    ) throws -> ToolExecutionOutput {
        let operation = "MemoryTool.execute(\(request.name))"
        let isMutation = mutatingToolDescriptors.contains { $0.name == request.name }

        if isMutation {
            return try MemoryLegacyBridge.runBlockingMutation(operation) {
                try await executeAsync(request, context: context, memoryService: memoryService)
            }
        }
        return try MemoryLegacyBridge.runBlocking(operation) {
            try await executeAsync(request, context: context, memoryService: memoryService)
        }
    }
}
