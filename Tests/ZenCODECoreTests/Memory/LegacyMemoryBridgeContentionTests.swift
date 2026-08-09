//
//  LegacyMemoryBridgeContentionTests.swift
//  ZenCODECoreTests
//
//  Regression coverage for the deprecated synchronous memory surface when it
//  is invoked concurrently.
//
//  The deprecated wrappers park the calling thread in a non-cancellable
//  semaphore wait (`MemoryLegacyBridge.runBlockingMutation`) while the async
//  graph work runs. Launching 16 of those calls from plain Swift tasks would
//  park 16 cooperative workers, so this suite instead runs the legacy calls on
//  a dedicated dispatch-backed task executor: each blocking call parks a
//  dispatch thread, the cooperative pool stays free, and the group children
//  still inherit the task-local support-directory override from this test.
//

import Dispatch
import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct LegacyMemoryBridgeContentionTests {

    /// Dispatch-backed executor that keeps this suite's blocking legacy calls
    /// off Swift's cooperative global pool. The queue is concurrent, so all 16
    /// children start at once; threads parked in the bridge's semaphore wait
    /// are dispatch threads, never cooperative workers.
    private final class LegacyContentionExecutor: TaskExecutor {
        private let queue = DispatchQueue(
            label: "zencode.tests.legacy-contention",
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

    @available(*, deprecated)
    @Test
    func legacySynchronousWritesRemainVisibleToAsyncReadsUnderContention() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let total = 16

            // Each child blocks in the 1.1.x wrapper while its async operation
            // is dispatched. The children run on the dispatch-backed executor
            // below instead of the cooperative global pool, so the contention
            // parks dispatch threads and the modern async facade must observe
            // every completed write afterwards.
            let executor = LegacyContentionExecutor()
            let completed = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<total {
                    group.addTask(executorPreference: executor) {
                        do {
                            _ = try service.writeEntry(
                                content: "Summary: legacy bridge contention entry \(index).",
                                scope: .project,
                                workspaceRootURL: workspace.workspaceURL
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var successes = 0
                for await result in group where result {
                    successes += 1
                }
                return successes
            }

            #expect(completed == total)
            let asyncEntries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: total + 1
            )
            #expect(asyncEntries.count == total)
        }
    }
}
