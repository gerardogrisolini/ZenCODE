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

        #expect(resolver.waitUntilStarted())
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private final class BlockingBrowserHostResolver: BrowserHostResolving, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func resolve(host _: String) throws -> [String] {
        started.signal()
        release.wait()
        return ["93.184.216.34"]
    }

    func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 1) == .success
    }

    func unblock() {
        release.signal()
    }
}
