//
//  MemoryAPICompatibilityTests.swift
//  ZenCODECoreTests
//
//  Verifies that ZenCODECore's public memory surface matches the 1.1.x
//  contract: `MemoryEntry` has `id: UUID`, is `Hashable`, and neither the
//  types nor the method signatures expose MemoryEngine engine types.
//

import Foundation
import Synchronization
import ToolCore
@testable import ZenCODECore
import Testing

@Suite
struct MemoryAPICompatibilityTests {

    // MARK: - MemoryEntry DTO contract

    @Test
    func memoryEntryIdIsUUID() {
        let entry = MemoryEntry(content: "Summary: test fact.")
        // The public id is typed as UUID.
        let _: UUID = entry.id
    }

    @Test
    func memoryEntryIsHashable() {
        let entry = MemoryEntry(content: "Summary: hashable entry.")
        // Hashable conformance is satisfied; the type is usable in Set/Dictionary.
        let set: Set<MemoryEntry> = [entry]
        #expect(set.contains(entry))
        #expect(set.count == 1)
    }

    @Test
    func memoryEntryIsIdentifiable() {
        let id = UUID()
        let entry = MemoryEntry(content: "x", id: id)
        #expect(entry.id == id)
    }

    @Test
    func memoryEntryScopeIsProject() {
        let entry = MemoryEntry(content: "x")
        #expect(entry.scope == .project)
        #expect(MemoryScope.allCases == [.project])
    }

    @Test
    func memoryEntryCodableRoundTrips() throws {
        let original = MemoryEntry(
            content: "Summary: codable round-trip.",
            category: .preference,
            tags: ["api", "compat"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.content == original.content)
        #expect(decoded.category == .preference)
        #expect(decoded.tags == ["api", "compat"])
    }

    @Test
    func memoryEntryCodableBackwardCompatibleWithLegacyPayload() throws {
        // Simulates a 1.1.x payload that only carried id, scope, content, isArchived.
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "scope": "project",
          "content": "Summary: legacy entry.",
          "isArchived": false
        }
        """
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        #expect(decoded.scope == .project)
        #expect(decoded.content == "Summary: legacy entry.")
        #expect(decoded.isArchived == false)
        // New fields receive safe defaults.
        #expect(decoded.category == .fact)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.trust == "medium")
        #expect(decoded.confidence == 1.0)
    }

    // MARK: - MemoryScope / MemoryCategory contract

    @Test
    func memoryScopeIsHashableAndCaseIterable() {
        let scopes: Set<MemoryScope> = [.project, .project]
        #expect(scopes.count == 1)
        #expect(MemoryScope.project.rawValue == "project")
    }

    @Test
    func memoryCategoryIsHashableAndCodable() throws {
        let categories: Set<MemoryCategory> = [.fact, .preference, .entity, .correction, .fact]
        #expect(categories.count == 4)

        let data = try JSONEncoder().encode(MemoryCategory.preference)
        let decoded = try JSONDecoder().decode(MemoryCategory.self, from: data)
        #expect(decoded == .preference)
    }

    // MARK: - DTO preserves engine data

    @Test
    func dtoConversionPreservesContentAndCategory() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let written = try await service.writeEntry(
                content: "Summary: facade preserves data.",
                workspaceRootURL: workspace.workspaceURL,
                category: .entity,
                tags: ["dto"]
            )
            #expect(written.category == .entity)
            #expect(written.tags == ["dto"])
            #expect(written.scope == .project)
            #expect(written.isArchived == false)

            let read = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 5
            )
            #expect(read.count == 1)
            #expect(read.first?.content == written.content)
            #expect(read.first?.id == written.id)
        }
    }

    // MARK: - Legacy 1.1.x signatures (compile-style)
    //
    // These bind each pre-3003ddc entry point to an *explicitly typed function
    // value*. That pins the whole signature — argument labels, parameter types,
    // effects (`throws` / non-`throws` / not `async`) and return type — so the
    // suite fails to compile if any of them drifts. Checking labels alone would
    // not catch a sync→async migration, which is exactly the regression class
    // this guards.
    //
    // The enclosing declarations are marked deprecated so that referencing the
    // deprecated shims does not spam the build with warnings.

    @available(*, deprecated)
    @Test
    func legacyServiceSignaturesAreSourceCompatible() {
        let service = MemoryService()

        // readEntries(scope:workingDirectory:includeArchived:limit:) -> [MemoryEntry]
        let readWorkingDirectory: (MemoryScope?, URL?, Bool, Int) -> [MemoryEntry] =
            service.readEntries(scope:workingDirectory:includeArchived:limit:)

        // readEntries(scope:workspaceRootURL:includeArchived:limit:) -> [MemoryEntry]
        let readWorkspaceRoot: (MemoryScope?, URL?, Bool, Int) -> [MemoryEntry] =
            service.readEntries(scope:workspaceRootURL:includeArchived:limit:)

        // searchEntries(query:scope:workingDirectory:includeArchived:limit:) -> [MemoryEntry]
        let searchWorkingDirectory: (String, MemoryScope?, URL?, Bool, Int) -> [MemoryEntry] =
            service.searchEntries(query:scope:workingDirectory:includeArchived:limit:)

        // searchEntries(query:scope:workspaceRootURL:includeArchived:limit:) -> [MemoryEntry]
        let searchWorkspaceRoot: (String, MemoryScope?, URL?, Bool, Int) -> [MemoryEntry] =
            service.searchEntries(query:scope:workspaceRootURL:includeArchived:limit:)

        // writeEntry(content:scope:workingDirectory:) throws -> MemoryEntry
        let writeWorkingDirectory: (String, MemoryScope, URL?) throws -> MemoryEntry =
            service.writeEntry(content:scope:workingDirectory:)

        // writeEntry(content:scope:workspaceRootURL:) throws -> MemoryEntry
        let writeWorkspaceRoot: (String, MemoryScope, URL?) throws -> MemoryEntry =
            service.writeEntry(content:scope:workspaceRootURL:)

        // updateEntry(id:content:scope:workspaceRootURL:updatedAt:timeZone:) throws -> MemoryEntry
        let update: (UUID, String, MemoryScope, URL?, Date, TimeZone) throws -> MemoryEntry =
            service.updateEntry(id:content:scope:workspaceRootURL:updatedAt:timeZone:)

        // replaceEntry(id:content:scope:workspaceRootURL:) throws -> MemoryEntry
        let replace: (UUID, String, MemoryScope, URL?) throws -> MemoryEntry =
            service.replaceEntry(id:content:scope:workspaceRootURL:)

        // archiveEntry(id:scope:workingDirectory:) throws -> MemoryEntry
        let archiveWorkingDirectory: (String, MemoryScope?, URL?) throws -> MemoryEntry =
            service.archiveEntry(id:scope:workingDirectory:)

        // archiveEntry(id:scope:workspaceRootURL:) throws -> MemoryEntry
        let archiveWorkspaceRoot: (String, MemoryScope?, URL?) throws -> MemoryEntry =
            service.archiveEntry(id:scope:workspaceRootURL:)

        // setArchived(_:id:scope:workspaceRootURL:) throws -> MemoryEntry
        let setArchived: (Bool, UUID, MemoryScope, URL?) throws -> MemoryEntry =
            service.setArchived(_:id:scope:workspaceRootURL:)

        // deleteEntry(id:scope:workspaceRootURL:) throws -> Void
        let delete: (UUID, MemoryScope, URL?) throws -> Void =
            service.deleteEntry(id:scope:workspaceRootURL:)

        // MemoryEntry.normalizedContent(_:) -> String
        let normalize: (String) -> String = MemoryEntry.normalizedContent(_:)

        // Statics that were part of the same contract.
        let _: String = MemoryService.filename
        let _: Notification.Name = MemoryService.entriesDidChangeNotification
        let _: String = MemoryService.defaultProjectMemoryContent
        let _: () -> Void = MemoryService.notifyMemoryEntriesChanged
        let _: () -> String = MemoryService.toolUsagePromptSection

        // Silence "never used" without invoking any I/O.
        let bindings: [Any] = [
            readWorkingDirectory, readWorkspaceRoot,
            searchWorkingDirectory, searchWorkspaceRoot,
            writeWorkingDirectory, writeWorkspaceRoot,
            update, replace,
            archiveWorkingDirectory, archiveWorkspaceRoot,
            setArchived, delete, normalize
        ]
        #expect(bindings.count == 13)

        // The normalization shim must still behave like the 1.1.x original.
        #expect(normalize("  Summary:   spaced\r\n  out  ") == "Summary: spaced\n out")
        #expect(normalize("x") == MemoryContent.normalized("x"))
    }

    @available(*, deprecated)
    @Test
    func legacyMemoryToolExecuteIsSynchronousInASyncContext() {
        // The 1.1.4 spelling: `try MemoryTool.execute(...)`, no `await`.
        let execute: (ToolRequest, MemoryToolContext, MemoryService) throws -> ToolExecutionOutput =
            MemoryTool.execute(_:context:memoryService:)
        // Unapplied reference proves the sync overload exists with the exact
        // legacy signature; `memoryService` also still has its default value.
        _ = execute
    }

    /// The legacy tool entry point, driven the 1.1.4 way from a synchronous
    /// test: `try MemoryTool.execute(...)` with no `await` and no explicit
    /// service argument.
    @available(*, deprecated)
    @Test
    func legacyMemoryToolExecuteRunsFromASyncContext() throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try AppStorageDirectory.withSupportDirectoryURL(workspace.supportDirectoryURL) {
            let context = MemoryToolContext(workingDirectory: workspace.workspaceURL)

            let written = try MemoryTool.execute(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string("Summary: sync tool execute.")]
                ),
                context: context
            )
            #expect(written.rawResult?.objectValue?["written"]?.boolValue == true)

            let read = try MemoryTool.execute(
                ToolRequest(name: "memory.read", arguments: [:]),
                context: context
            )
            #expect(read.rawResult?.objectValue?["count"]?.numberValue == 1)

            // An unknown tool still reports the legacy error.
            #expect(throws: (any Error).self) {
                try MemoryTool.execute(
                    ToolRequest(name: "memory.nope", arguments: [:]),
                    context: context
                )
            }
        }
    }

    /// Inside an async function the async overload wins, so the blocking one has
    /// to be requested explicitly. Doing so must still complete rather than
    /// deadlock against the concurrency pool.
    @available(*, deprecated)
    @Test
    func legacyMemoryToolExecuteDoesNotDeadlockFromAnAsyncContext() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let context = MemoryToolContext(workingDirectory: workspace.workspaceURL)
            let blockingExecute: (ToolRequest, MemoryToolContext, MemoryService) throws -> ToolExecutionOutput =
                MemoryTool.execute(_:context:memoryService:)

            let written = try blockingExecute(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string("Summary: async-context tool execute.")]
                ),
                context,
                MemoryService()
            )
            #expect(written.rawResult?.objectValue?["written"]?.boolValue == true)

            // The modern async entry point confirms the blocking wrapper wrote.
            let read = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.read", arguments: [:]),
                context: context
            )
            #expect(read.rawResult?.objectValue?["count"]?.numberValue == 1)
        }
    }

    // MARK: - Legacy reads with a nil directory

    @available(*, deprecated)
    @Test
    func legacyReadsWithNilDirectoryReturnEmptyInsteadOfThrowing() {
        // 1.1.x resolved no memory document for a nil directory, so the read
        // API answered `[]`. It never surfaced an error for a read.
        let service = MemoryService()

        #expect(service.readEntries(scope: .project, workingDirectory: nil, limit: 10).isEmpty)
        #expect(service.readEntries(scope: .project, workspaceRootURL: nil, limit: 10).isEmpty)
        #expect(service.readEntries(scope: nil, workingDirectory: nil, limit: 10).isEmpty)
        #expect(service.searchEntries(query: "x", scope: .project, workingDirectory: nil, limit: 10).isEmpty)
        #expect(service.searchEntries(query: "x", scope: .project, workspaceRootURL: nil, limit: 10).isEmpty)
        #expect(service.searchEntries(query: "x", scope: nil, workspaceRootURL: nil, limit: 10).isEmpty)
    }

    @available(*, deprecated)
    @Test
    func legacyMutationsWithNilDirectoryReportScopeUnavailable() {
        // Mutations did throw `scopeUnavailable` in 1.1.x — only reads were lenient.
        let service = MemoryService()

        #expect(throws: MemoryServiceError.self) {
            try service.writeEntry(content: "Summary: x.", scope: .project, workingDirectory: nil)
        }
        #expect(throws: MemoryServiceError.self) {
            try service.updateEntry(
                id: UUID(),
                content: "Summary: x.",
                scope: .project,
                workspaceRootURL: nil
            )
        }
        #expect(throws: MemoryServiceError.self) {
            try service.replaceEntry(
                id: UUID(),
                content: "Summary: x.",
                scope: .project,
                workspaceRootURL: nil
            )
        }
        #expect(throws: MemoryServiceError.self) {
            try service.setArchived(true, id: UUID(), scope: .project, workspaceRootURL: nil)
        }
        #expect(throws: MemoryServiceError.self) {
            try service.deleteEntry(id: UUID(), scope: .project, workspaceRootURL: nil)
        }
        // A malformed identifier is still rejected before any document lookup.
        #expect(throws: MemoryServiceError.self) {
            try service.archiveEntry(id: "not-a-uuid", scope: .project, workingDirectory: nil)
        }
    }

    /// The modern async read keeps throwing, which is what the tool layer relies
    /// on to report a missing workspace instead of silently reading nothing.
    @Test
    func asyncReadWithNilWorkspaceStillThrows() async {
        let service = MemoryService()
        await #expect(throws: MemoryServiceError.self) {
            try await service.readEntries(workspaceRootURL: nil, limit: 10)
        }
    }

    // MARK: - Deprecated sync bridge: real behaviour, both contexts

    /// Drives the legacy synchronous API from a genuinely synchronous test.
    @available(*, deprecated)
    @Test
    func legacySynchronousAPIWorksFromASyncContext() throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try AppStorageDirectory.withSupportDirectoryURL(workspace.supportDirectoryURL) {
            let service = MemoryService()

            let written = try service.writeEntry(
                content: "Summary: sync-context legacy write.",
                scope: .project,
                workingDirectory: workspace.workspaceURL
            )
            #expect(written.scope == .project)
            #expect(written.isArchived == false)

            let entries = service.readEntries(
                scope: .project,
                workingDirectory: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.count == 1)
            #expect(entries.first?.id == written.id)

            let matches = service.searchEntries(
                query: "sync-context",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL,
                limit: 5
            )
            #expect(matches.contains { $0.id == written.id })

            // A blank query degraded to "first N entries" in 1.1.x rather than failing.
            let blank = service.searchEntries(
                query: "   ",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL,
                limit: 5
            )
            #expect(blank.count == 1)

            // updateEntry keeps the id and stamps Updated.
            let updated = try service.updateEntry(
                id: written.id,
                content: "Summary: sync-context legacy update.",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(updated.id == written.id)
            #expect(updated.content.contains("Updated:"))

            // replaceEntry also preserves identity.
            let replaced = try service.replaceEntry(
                id: written.id,
                content: "Summary: sync-context legacy replace.",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(replaced.id == written.id)
            #expect(replaced.content.contains("legacy replace"))

            // archive / unarchive / delete round trip on the legacy signatures.
            let archived = try service.archiveEntry(
                id: written.id.uuidString,
                scope: .project,
                workingDirectory: workspace.workspaceURL
            )
            #expect(archived.isArchived)
            #expect(service.readEntries(
                scope: .project,
                workingDirectory: workspace.workspaceURL,
                limit: 10
            ).isEmpty)

            let unarchived = try service.setArchived(
                false,
                id: written.id,
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(unarchived.isArchived == false)

            try service.deleteEntry(
                id: written.id,
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(service.readEntries(
                scope: .project,
                workingDirectory: workspace.workspaceURL,
                includeArchived: true,
                limit: 10
            ).isEmpty)
        }
    }

    /// The same blocking wrappers, invoked from inside an async context. This is
    /// the deadlock-prone direction: the bounded bridge must still complete.
    @available(*, deprecated)
    @Test
    func legacySynchronousAPIDoesNotDeadlockFromAnAsyncContext() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()

            // No `await`: this binds the deprecated blocking wrapper while the
            // caller is an async function running on the concurrency pool.
            let written = try service.writeEntry(
                content: "Summary: async-context legacy write.",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )

            let entries = service.readEntries(
                scope: .project,
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.count == 1)
            #expect(entries.first?.id == written.id)

            // The bridge inherits task-locals, so it saw the isolated support
            // directory rather than the developer's real one.
            let viaAsync = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(viaAsync.map(\.id) == entries.map(\.id))
        }
    }

    /// Several blocking wrappers at once, from concurrent async tasks: proves the
    /// bridge does not serialize itself into a deadlock under contention.
    @available(*, deprecated)
    @Test
    func concurrentLegacyBlockingCallsAllComplete() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try service.writeEntry(
                content: "Summary: contended legacy entry.",
                scope: .project,
                workspaceRootURL: workspace.workspaceURL
            )

            let counts = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        service.readEntries(
                            scope: .project,
                            workspaceRootURL: workspace.workspaceURL,
                            limit: 10
                        ).count
                    }
                }
                var results: [Int] = []
                for await count in group {
                    results.append(count)
                }
                return results
            }

            #expect(counts.count == 8)
            #expect(counts.allSatisfy { $0 == 1 })
        }
    }

    // MARK: - memory.write reports created vs deduplicated

    @Test
    func memoryWriteReportsCreatedThenDeduplicated() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let context = MemoryToolContext(workingDirectory: workspace.workspaceURL)
            let request = ToolRequest(
                name: "memory.write",
                arguments: ["content": .string("Summary: dedup contract.\nState: first write.")]
            )

            let first = try await MemoryTool.executeAsync(request, context: context)
            #expect(first.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(first.rawResult?.objectValue?["deduplicated"]?.boolValue == false)
            #expect(first.text.contains("Saved memory entry"))

            // Same content again: the store deduplicates, so the tool must not
            // claim a second write.
            let second = try await MemoryTool.executeAsync(request, context: context)
            #expect(second.rawResult?.objectValue?["written"]?.boolValue == false)
            #expect(second.rawResult?.objectValue?["deduplicated"]?.boolValue == true)
            #expect(second.text.contains("Duplicate"))
            #expect(!second.text.contains("Saved memory entry"))

            // The reused entry is the original one, so its id stays usable.
            let firstID = first.rawResult?.objectValue?["entry"]?.objectValue?["id"]?.stringValue
            let secondID = second.rawResult?.objectValue?["entry"]?.objectValue?["id"]?.stringValue
            #expect(firstID != nil)
            #expect(firstID == secondID)

            // And only one entry actually exists.
            let stored = try await MemoryService().readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(stored.count == 1)
        }
    }

    @Test
    func writeEntryOutcomePropagatesCreatedFlag() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntryOutcome(
                content: "Summary: outcome flag.",
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(first.created)
            #expect(first.deduplicated == false)

            let second = try await service.writeEntryOutcome(
                content: "Summary: outcome flag.",
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(second.created == false)
            #expect(second.deduplicated)
            #expect(second.entry.id == first.entry.id)

            // The public signature is unchanged and still yields the entry.
            let viaPublicAPI = try await service.writeEntry(
                content: "Summary: outcome flag.",
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(viaPublicAPI.id == first.entry.id)
        }
    }

    // MARK: - executeAsync rename: direct legacy call in async context

    /// The exact 1.1.4 call `try MemoryTool.execute(...)` — **no `await`** —
    /// must compile unchanged inside an `async` function.
    ///
    /// Before the rename this failed: Swift picked the async `execute` overload
    /// in async contexts and required `try await`.  Now `execute` is the sole
    /// (sync) overload and `executeAsync` is the modern entry point, so the
    /// legacy spelling compiles everywhere.
    @available(*, deprecated)
    @Test
    func legacyExecuteCompilesWithoutAwaitInsideAsyncFunction() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let context = MemoryToolContext(workingDirectory: workspace.workspaceURL)

            // Direct call — no function-value binding, no `await`.
            // Regression guard: re-introducing an async `execute` overload
            // makes this line fail to compile.
            _ = try MemoryTool.execute(
                ToolRequest(name: "memory.read", arguments: [:]),
                context: context
            )
        }
    }

    /// A mutation dispatched through the legacy sync `execute` must route
    /// through the commit-gate, not the bounded read bridge.
    @available(*, deprecated)
    @Test
    func legacyExecuteRoutesMutationsThroughCommitGate() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let context = MemoryToolContext(workingDirectory: workspace.workspaceURL)

            // A write via the sync wrapper must succeed (not throw "abandoned").
            let written = try MemoryTool.execute(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string("Summary: commit-gate write.")]
                ),
                context: context
            )
            #expect(written.rawResult?.objectValue?["written"]?.boolValue == true)

            // The async API confirms the mutation committed.
            let read = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.read", arguments: [:]),
                context: context
            )
            #expect(read.rawResult?.objectValue?["count"]?.numberValue == 1)
        }
    }

    // MARK: - Mutation commit-gate: no durable side-effect reported as abandoned

    /// A mutation that takes longer than the bounded budget must still return
    /// its actual result — never an "abandoned" error.
    @Test
    func mutationBridgeWaitsForDefinitiveOutcome() throws {
        let shortTimeout: TimeInterval = 0.05

        // The operation takes 0.08s — longer than the 0.05s budget — but it
        // completes successfully.  The bridge must wait and return "committed".
        let result = try MemoryLegacyBridge.runBlockingMutation(
            "test-slow-mutation",
            timeout: shortTimeout
        ) {
            try await Task.sleep(nanoseconds: 80_000_000)
            return "committed"
        }

        #expect(result == "committed")
    }

    /// The defining contract: a mutation whose durable side-effect lands
    /// *after* the bounded budget must be visible to the caller — the caller
    /// must not see "abandoned" while the write silently committed.
    @Test
    func mutationBridgeLateSideEffectIsVisibleToCaller() throws {
        let shortTimeout: TimeInterval = 0.05
        let sideEffect = Mutex(false)

        let result = try MemoryLegacyBridge.runBlockingMutation(
            "test-late-commit",
            timeout: shortTimeout
        ) {
            // Simulate a slow store commit that lands after the timeout.
            try await Task.sleep(nanoseconds: 500_000_000)
            sideEffect.withLock { $0 = true }
            return "ok"
        }

        #expect(result == "ok")
        // Because the bridge waited for the definitive outcome, the caller
        // observes the side-effect rather than being told it was abandoned.
        #expect(sideEffect.withLock { $0 })
    }

    /// A mutation that fails after the budget still reports the actual error,
    /// not "abandoned".
    @Test
    func mutationBridgeReportsActualErrorAfterTimeout() {
        let shortTimeout: TimeInterval = 0.05
        struct SentinelError: Error {}

        #expect(throws: SentinelError.self) {
            try MemoryLegacyBridge.runBlockingMutation(
                "test-slow-failure",
                timeout: shortTimeout
            ) {
                try await Task.sleep(nanoseconds: 500_000_000)
                throw SentinelError()
            }
        }
    }

    /// Contrast: a read that exceeds its bounded budget is abandoned — late
    /// reads are harmless, so the bounded timeout is the correct semantics.
    @Test
    func readBridgeAbandonsOnTimeout() {
        // The sleep must comfortably exceed the timeout so that the bounded
        // wait always expires first, even under CI load or CPU contention.
        let shortTimeout: TimeInterval = 0.05

        #expect(throws: MemoryLegacyBridgeError.self) {
            try MemoryLegacyBridge.runBlocking(
                "test-slow-read",
                timeout: shortTimeout
            ) {
                try await Task.sleep(nanoseconds: 500_000_000)
                return "late"
            }
        }
    }

    /// A mutation that finishes within the budget returns immediately, just
    /// like the read bridge.
    @Test
    func mutationBridgeFastPathReturnsImmediately() throws {
        let result = try MemoryLegacyBridge.runBlockingMutation(
            "test-fast-mutation",
            timeout: 5.0
        ) {
            return "fast"
        }

        #expect(result == "fast")
    }
}
