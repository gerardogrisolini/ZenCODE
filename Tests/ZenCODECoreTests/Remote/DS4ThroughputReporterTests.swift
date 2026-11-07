//
//  DS4ThroughputReporterTests.swift
//  ZenCODE
//
//  The live DS4 throughput events: prefill progress relative to the sync, the
//  prefill speed kept through the generation, throttling and the exact values
//  of a finished round.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// A clock the test moves by hand.
private final class ManualClock: Sendable {
    private let origin = ContinuousClock.now
    private let elapsed = Mutex(Duration.zero)

    func advance(_ duration: Duration) {
        elapsed.withLock { $0 += duration }
    }

    func now() -> ContinuousClock.Instant {
        origin + elapsed.withLock { $0 }
    }
}

private struct ThroughputHarness {
    let clock = ManualClock()
    let reporter: DS4ThroughputReporter
    private let events: AsyncStream<DirectAgentEvent>
    private let continuation: AsyncStream<DirectAgentEvent>.Continuation

    init() {
        let (events, continuation) = AsyncStream<DirectAgentEvent>.makeStream()
        let clock = clock
        self.events = events
        self.continuation = continuation
        self.reporter = DS4ThroughputReporter(continuation: continuation, now: { clock.now() })
    }

    func advance(_ duration: Duration) {
        clock.advance(duration)
    }

    /// Everything yielded so far. Call it once, at the end of a test.
    func emitted() async -> [DirectAgentGenerationMetrics] {
        continuation.finish()
        var metrics: [DirectAgentGenerationMetrics] = []
        for await event in events {
            if case let .metrics(value) = event {
                metrics.append(value)
            } else {
                Issue.record("Unexpected non-metrics event: \(event)")
            }
        }
        return metrics
    }
}

private func isClose(_ value: Double?, to expected: Double) -> Bool {
    guard let value else {
        return false
    }
    return abs(value - expected) < 1e-9
}

@Suite("DS4 live throughput")
struct DS4ThroughputReporterTests {
    // MARK: - Prefill with the baseline of prefill_start

    @Test
    func relativeTotalsAreRecognizedAfterPrefillStart() async throws {
        let harness = ThroughputHarness()

        // The GLM tensor-parallel path: current = i + 1 - start,
        // total = prompt_len - start.
        harness.reporter.reportPrefill(event: "prefill_start", current: 4_000, total: 12_000)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 1_000, total: 8_000)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 8_000, total: 8_000)
        let emitted = await harness.emitted()

        let throughputs = emitted.compactMap(\.throughput)
        #expect(throughputs.map(\.processedTokens) == [0, 1_000, 8_000])
        #expect(throughputs.map(\.targetTokens) == [8_000, 8_000, 8_000])
        #expect(isClose(throughputs[1].prefillTokensPerSecond, to: 1_000))
        #expect(isClose(throughputs[2].prefillTokensPerSecond, to: 4_000))
    }

    // MARK: - Prefill without prefill_start (first event as baseline)

    @Test
    func withoutPrefillStartTheFirstEventIsTheBaseline() async throws {
        let harness = ThroughputHarness()

        // DS4 reports the length of the cached prefix before evaluating.
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 4_000, total: 12_000)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 5_000, total: 12_000)
        let emitted = await harness.emitted()

        #expect(emitted.count == 2)
        let first = try #require(emitted.first?.throughput)
        #expect(first.phase == .prefill)
        #expect(first.processedTokens == 0)
        #expect(first.targetTokens == 8_000)
        #expect(first.prefillTokensPerSecond == nil)
        let second = try #require(emitted.last?.throughput)
        #expect(second.phase == .prefill)
        #expect(second.processedTokens == 1_000)
        #expect(second.targetTokens == 8_000)
        #expect(second.prefillTokensPerSecond == 1_000)
    }

    @Test
    func prefillEventsAreThrottledAndTheFirstOneIsImmediate() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_display", current: 0, total: 1_000)
        harness.advance(.milliseconds(100))
        harness.reporter.reportPrefill(event: "prefill_display", current: 100, total: 1_000)
        harness.advance(.milliseconds(149))
        harness.reporter.reportPrefill(event: "prefill_display", current: 249, total: 1_000)
        harness.advance(.milliseconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 250, total: 1_000)
        harness.advance(.milliseconds(10))
        harness.reporter.reportPrefill(event: "prefill_display", current: 260, total: 1_000)
        let emitted = await harness.emitted()

        let processed = emitted.compactMap { $0.throughput?.processedTokens }
        #expect(processed == [0, 250])
        let rate = try #require(emitted.last?.throughput?.prefillTokensPerSecond)
        #expect(isClose(rate, to: 1_000))
    }

    // MARK: - Generation

    @Test
    func generationSpeedIsTokensOverTheTimeSinceGenerateStarted() async throws {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: nil)
        harness.advance(.milliseconds(500))
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(100))
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(400))
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(250))
        harness.reporter.recordGeneratedToken()
        let emitted = await harness.emitted()

        // 1 token after 0.5 s, then the 0.25 s throttle: 4 tokens after 1.25 s.
        #expect(emitted.count == 3)
        let rates = emitted.compactMap { $0.throughput?.generationTokensPerSecond }
        #expect(rates.count == 3)
        #expect(isClose(rates[0], to: 2))
        #expect(isClose(rates[1], to: 3))
        #expect(isClose(rates[2], to: 3.2))
        for metrics in emitted {
            #expect(metrics.throughput?.phase == .generation)
            #expect(metrics.throughput?.prefillTokensPerSecond == nil)
            #expect(metrics.throughput?.processedTokens == nil)
            #expect(metrics.throughput?.targetTokens == nil)
        }
    }

    // MARK: - Final values

    @Test
    func finalThroughputCarriesBothEngineSpeedsWhenTokensWereGenerated() {
        var stats = DS4SessionStats.empty
        stats.generatedTokens = 120
        stats.generationTokensPerSecond = 38.5
        stats.prefillTokensPerSecond = 910

        let throughput = RemoteGenerationClient.ds4FinalThroughput(
            sync: DS4SyncResult(tokenCount: 9_000, cached: 4_000, suffix: 5_000),
            stats: stats
        )

        #expect(
            throughput == DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: 910,
                generationTokensPerSecond: 38.5
            )
        )
    }
}
