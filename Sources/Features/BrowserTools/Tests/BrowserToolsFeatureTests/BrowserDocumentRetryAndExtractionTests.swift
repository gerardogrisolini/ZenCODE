import Foundation
import Testing
@testable import BrowserToolsFeature

/// Bounded retry of the document URL read, and the incremental length counter
/// of the page extraction script (checked on its text: no browser is started).
@Suite
struct BrowserDocumentRetryAndExtractionTests {
    private struct Transient: Error, Equatable { let attempt: Int }

    private func retry(
        budget: Duration = .seconds(5), interval: Duration = .milliseconds(1), terminated: Bool = false,
        _ evaluate: () async throws -> String
    ) async throws -> String {
        try await BrowserNetworkGuard.retryingTransientEvaluationErrors(
            budget: budget, interval: interval, isTerminated: { terminated }, evaluate
        )
    }

    @Test
    func aTransientFailureIsRetriedAndTheLastErrorIsThrownOnceTheBudgetIsSpent() async throws {
        var attempts = 0
        let url = try await retry {
            attempts += 1
            if attempts == 1 { throw Transient(attempt: attempts) }
            return "https://example.com/"
        }
        #expect(url == "https://example.com/")
        #expect(attempts == 2)

        attempts = 0
        let error = await #expect(throws: Transient.self) {
            try await retry(budget: .milliseconds(100), interval: .milliseconds(20)) {
                attempts += 1
                throw Transient(attempt: attempts)
            }
        }
        #expect(attempts > 1)
        #expect(error == Transient(attempt: attempts))
    }

    @Test
    func cancellationAndATerminatedSessionAreNotRetried() async {
        var attempts = 0
        await #expect(throws: CancellationError.self) {
            try await retry { attempts += 1; throw CancellationError() }
        }
        await #expect(throws: Transient.self) {
            try await retry(terminated: true) { attempts += 1; throw Transient(attempt: attempts) }
        }
        #expect(attempts == 2)
    }

    @Test
    func pageExtractionCountsTheLengthIncrementallyWithTheSameThreshold() throws {
        let script = CDPSession.extractPageJS
        let loopStart = try #require(script.range(of: "for(const el of blocks)"))
        let loopEnd = try #require(script.range(of: "lines.push('','## Visible links')"))
        let loop = script[loopStart.lowerBound..<loopEnd.lowerBound]
        #expect(!loop.contains("lines.join"))
        #expect(loop.contains("if(joinedLength>900000)"))
    }
}
