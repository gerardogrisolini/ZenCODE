import Dispatch
import Foundation
@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserNetworkGuardConcurrencyTests {
    @Test
    func offloadedDNSValidationPropagatesCancellationWithoutWaitingForResolver() async {
        let resolver = BlockingBrowserHostResolver()
        let policy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: resolver
        )
        let task = Task.detached {
            try await policy.validateRequestURLOffloaded("https://safe.example/path")
        }
        defer { resolver.unblock() }

        // Wait for the resolver to start without holding a cooperative thread
        // pool worker. A blocking DispatchSemaphore.wait here would keep the only
        // pool thread busy while the detached task below — the one that actually
        // signals the semaphore — waits for a worker of its own. The Swift
        // runtime on Linux does not grow the cooperative pool around an
        // uninstrumented block, so that is a deadlock and the signal never
        // arrives within the timeout. Probing with a non-blocking wait and
        // yielding between attempts keeps the pool responsive on every platform.
        let resolverDidStart = await resolver.waitUntilStarted(timeout: .seconds(10))
        #expect(
            resolverDidStart,
            "Resolver did not enter resolve(host:) within 10 seconds"
        )
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private final class BlockingBrowserHostResolver: BrowserHostResolving, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    /// Signals the start semaphore from a global-queue thread (never the
    /// cooperative pool), so blocking on `release` below is safe.
    func resolve(host _: String) throws -> [String] {
        started.signal()
        release.wait()
        return ["93.184.216.34"]
    }

    /// Awaits the start signal without blocking a cooperative thread pool
    /// worker. See the call site for why a blocking `wait(timeout:)` here
    /// deadlocks on platforms (Linux) that do not grow the cooperative pool
    /// around an uninstrumented block. `wait(timeout:)` is also unavailable from
    /// async contexts, so the non-blocking probe is isolated in a synchronous
    /// helper; it returns immediately and never holds the cooperative thread.
    func waitUntilStarted(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if consumeStartSignalIfPending() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Non-blocking probe: decrements the start semaphore only if it has already
    /// been signalled, otherwise returns immediately.
    private func consumeStartSignalIfPending() -> Bool {
        started.wait(timeout: .now()) == .success
    }

    func unblock() {
        release.signal()
    }
}
