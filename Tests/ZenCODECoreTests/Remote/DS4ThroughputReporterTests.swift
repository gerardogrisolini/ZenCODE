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
    func prefillStartSetsTheBaselineAndEmitsAtOnce() async throws {
        let harness = ThroughputHarness()

        // The shim announces the reused prefix and the prompt length.
        harness.reporter.reportPrefill(event: "prefill_start", current: 4_000, total: 12_000)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 5_000, total: 12_000)
        let emitted = await harness.emitted()

        #expect(emitted.count == 2)
        let first = try #require(emitted.first?.throughput)
        #expect(first.phase == .prefill)
        #expect(first.processedTokens == 0)
        #expect(first.targetTokens == 8_000)
        #expect(first.prefillTokensPerSecond == nil)
        #expect(first.generationTokensPerSecond == nil)
        let second = try #require(emitted.last?.throughput)
        #expect(second.phase == .prefill)
        #expect(second.processedTokens == 1_000)
        #expect(second.targetTokens == 8_000)
        #expect(second.prefillTokensPerSecond == 1_000)
        #expect(second.generationTokensPerSecond == nil)
    }

    @Test
    func aSingleChunkEndEventStillShowsThePrefillLikeQwen() async throws {
        let harness = ThroughputHarness()

        // Qwen reports one absolute `prefill_chunk` per chunk, at its end.
        harness.reporter.reportPrefill(event: "prefill_start", current: 4_000, total: 12_000)
        harness.advance(.seconds(4))
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 12_000, total: 12_000)
        let emitted = await harness.emitted()

        let throughputs = emitted.compactMap(\.throughput)
        #expect(throughputs.count == 2)
        #expect(throughputs.map(\.phase) == [.prefill, .prefill])
        #expect(throughputs.map(\.processedTokens) == [0, 8_000])
        #expect(throughputs.map(\.targetTokens) == [8_000, 8_000])
        #expect(throughputs[0].prefillTokensPerSecond == nil)
        #expect(isClose(throughputs[1].prefillTokensPerSecond, to: 2_000))
    }

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

    @Test
    func processedIsLimitedToTheTargetAndNeverNegative() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_start", current: 4_000, total: 12_000)
        harness.advance(.seconds(1))
        // Absolute position below the baseline, then past the prompt.
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 3_000, total: 12_000)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 13_000, total: 12_000)
        // A relative position past the relative total.
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 9_000, total: 8_000)
        let emitted = await harness.emitted()

        let processed = emitted.compactMap { $0.throughput?.processedTokens }
        #expect(processed == [0, 0, 8_000, 8_000])
    }

    @Test
    func aFullyCachedPromptAnnouncedByPrefillStartEmitsNothing() async {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_start", current: 500, total: 500)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 500, total: 500)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
    }

    @Test
    func prefillStartWithoutATotalIsIgnored() async {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_start", current: 100, total: 0)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
    }

    @Test
    func prefillEventsAfterPrefillStartAreThrottled() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_start", current: 0, total: 1_000)
        harness.advance(.milliseconds(100))
        harness.reporter.reportPrefill(event: "prefill_display", current: 100, total: 1_000)
        harness.advance(.milliseconds(149))
        harness.reporter.reportPrefill(event: "prefill_display", current: 249, total: 1_000)
        harness.advance(.milliseconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 250, total: 1_000)
        let emitted = await harness.emitted()

        let processed = emitted.compactMap { $0.throughput?.processedTokens }
        #expect(processed == [0, 250])
        let rate = try #require(emitted.last?.throughput?.prefillTokensPerSecond)
        #expect(isClose(rate, to: 1_000))
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
    func withoutPrefillStartASingleEndEventShowsNothing() async {
        let harness = ThroughputHarness()

        // The baseline is the event itself: target 0, as before prefill_start.
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 12_000, total: 12_000)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
    }

    @Test
    func liveEventsCarryOnlyTheThroughput() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_chunk", current: 0, total: 100)
        let metrics = try #require(await harness.emitted().first)

        #expect(metrics.isLiveProgress)
        #expect(!metrics.replacesPreviousMetrics)
        #expect(!metrics.clearsPromptMetrics)
        #expect(metrics.promptTokenCount == nil)
        #expect(metrics.cachedPromptTokenCount == nil)
        #expect(metrics.completionTokenCount == nil)
        #expect(metrics.responseDurationSeconds == nil)
        #expect(metrics.contextTokenCount == nil)
        #expect(metrics.throughput != nil)
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

    @Test
    func eventsThatAreNotPrefillProgressAreIgnored() async {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "distributed_route_wait", current: 0, total: 0)
        harness.reporter.reportPrefill(event: "distributed_route_wait", current: 3, total: 100)
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 10, total: 0)
        harness.reporter.reportPrefill(event: "decode", current: 10, total: 100)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
    }

    @Test
    func ignoredEventsDoNotSetTheBaseline() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "distributed_route_wait", current: 900, total: 1_000)
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 0, total: 1_000)
        let emitted = await harness.emitted()

        #expect(emitted.count == 1)
        #expect(emitted.first?.throughput?.targetTokens == 1_000)
    }

    @Test
    func nothingIsEmittedWhenThereIsNoPrefillToEvaluate() async {
        let harness = ThroughputHarness()

        // Fully cached prompt (or a test double reporting its suffix twice).
        harness.reporter.reportPrefill(event: "prefill_chunk", current: 500, total: 500)
        harness.advance(.seconds(1))
        harness.reporter.reportPrefill(event: "prefill_display", current: 500, total: 500)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
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

    @Test
    func generationSpeedIsUnknownBeforeAnyTimeElapsed() async throws {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: nil)
        harness.reporter.recordGeneratedToken()
        let emitted = await harness.emitted()

        let throughput = try #require(emitted.first?.throughput)
        #expect(throughput.phase == .generation)
        #expect(throughput.generationTokensPerSecond == nil)
    }

    @Test
    func beginGenerationEmitsThePrefillSpeedBeforeTheFirstToken() async throws {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: 512)
        let emitted = await harness.emitted()

        #expect(emitted.count == 1)
        let metrics = try #require(emitted.first)
        #expect(metrics.isLiveProgress)
        #expect(
            metrics.throughput == DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: 512,
                generationTokensPerSecond: nil
            )
        )
    }

    @Test
    func beginGenerationWithoutAPrefillSpeedEmitsNothing() async {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: nil)
        let emitted = await harness.emitted()

        #expect(emitted.isEmpty)
    }

    @Test
    func theFirstTokenIsEmittedAtOnceEvenRightAfterBeginGeneration() async throws {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: 512)
        // The same instant: the begin update must not hold the token back.
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(100))
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(150))
        harness.reporter.recordGeneratedToken()
        let emitted = await harness.emitted()

        let throughputs = emitted.compactMap(\.throughput)
        // begin, first token (immediate), then the 250 ms throttle.
        #expect(throughputs.count == 3)
        #expect(throughputs[0].generationTokensPerSecond == nil)
        #expect(throughputs[1].generationTokensPerSecond == nil)
        #expect(isClose(throughputs[2].generationTokensPerSecond, to: 3 / 0.25))
    }

    @Test
    func everyGenerationUpdateKeepsThePrefillSpeed() async throws {
        let harness = ThroughputHarness()

        harness.reporter.beginGeneration(prefillTokensPerSecond: 512)
        harness.advance(.milliseconds(500))
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(500))
        harness.reporter.recordGeneratedToken()
        let emitted = await harness.emitted()

        let throughputs = emitted.compactMap(\.throughput)
        #expect(throughputs.count == 3)
        for throughput in throughputs {
            #expect(throughput.phase == .generation)
            #expect(throughput.prefillTokensPerSecond == 512)
            #expect(throughput.processedTokens == nil)
            #expect(throughput.targetTokens == nil)
        }
        #expect(isClose(throughputs[1].generationTokensPerSecond, to: 2))
        #expect(isClose(throughputs[2].generationTokensPerSecond, to: 2))
    }

    @Test
    func theFirstEmissionOfEachPhaseIsImmediate() async throws {
        let harness = ThroughputHarness()

        harness.reporter.reportPrefill(event: "prefill_chunk", current: 0, total: 1_000)
        harness.advance(.milliseconds(50))
        harness.reporter.beginGeneration(prefillTokensPerSecond: nil)
        harness.advance(.milliseconds(50))
        // Still inside the prefill throttle window: the phase switch is not held back.
        harness.reporter.recordGeneratedToken()
        harness.advance(.milliseconds(10))
        harness.reporter.recordGeneratedToken()
        let emitted = await harness.emitted()

        let phases = emitted.compactMap { $0.throughput?.phase }
        #expect(phases == [.prefill, .generation])
        let rate = try #require(emitted.last?.throughput?.generationTokensPerSecond)
        #expect(isClose(rate, to: 1 / 0.05))
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

    @Test
    func finalThroughputFallsBackToThePrefillSpeedWithoutGeneratedTokens() {
        var stats = DS4SessionStats.empty
        stats.generatedTokens = 0
        stats.prefillTokensPerSecond = 910

        let throughput = RemoteGenerationClient.ds4FinalThroughput(
            sync: DS4SyncResult(tokenCount: 9_000, cached: 4_000, suffix: 5_000),
            stats: stats
        )

        // Only the speed: a finished round has no progress to show.
        #expect(
            throughput == DirectAgentGenerationThroughput(
                phase: .prefill,
                prefillTokensPerSecond: 910
            )
        )
        #expect(throughput?.processedTokens == nil)
        #expect(throughput?.targetTokens == nil)
    }

    @Test
    func finalThroughputHasNoPrefillSpeedWhenThePromptWasFullyCached() {
        var stats = DS4SessionStats.empty
        stats.generatedTokens = 64
        stats.generationTokensPerSecond = 41.2
        // A stale value of an earlier sync must not leak into this round.
        stats.prefillTokensPerSecond = 910

        let throughput = RemoteGenerationClient.ds4FinalThroughput(
            sync: DS4SyncResult(tokenCount: 9_000, cached: 9_000, suffix: 0),
            stats: stats
        )

        #expect(
            throughput == DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: nil,
                generationTokensPerSecond: 41.2
            )
        )
    }

    @Test
    func finalThroughputIsNilWhenNothingWasEvaluatedOrGenerated() {
        let throughput = RemoteGenerationClient.ds4FinalThroughput(
            sync: DS4SyncResult(tokenCount: 9_000, cached: 9_000, suffix: 0),
            stats: .empty
        )

        #expect(throughput == nil)
    }

    @Test
    func prefillSpeedHelperNeedsASuffixAndAUsableEngineValue() {
        func speed(suffix: Int, rate: Double) -> Double? {
            var stats = DS4SessionStats.empty
            stats.prefillTokensPerSecond = rate
            return RemoteGenerationClient.ds4PrefillTokensPerSecond(
                sync: DS4SyncResult(tokenCount: 9_000, cached: 9_000 - suffix, suffix: suffix),
                stats: stats
            )
        }

        #expect(speed(suffix: 5_000, rate: 910) == 910)
        #expect(speed(suffix: 0, rate: 910) == nil)
        #expect(speed(suffix: 5_000, rate: 0) == nil)
        #expect(speed(suffix: 5_000, rate: -1) == nil)
        #expect(speed(suffix: 5_000, rate: .nan) == nil)
        #expect(speed(suffix: 5_000, rate: .infinity) == nil)
    }
}
