//
//  DS4ThroughputReporter.swift
//  ZenCODE
//
//  Live prefill and generation throughput of the DS4 engine, reported as
//  throttled `.metrics` events.
//

import Foundation
import Synchronization
import ToolCore

/// Turns the DS4 prefill progress and per-token generation callbacks (engine
/// thread) into live `.metrics` events that carry only the throughput.
///
/// Events are throttled to one every `minimumInterval`; the first one of each
/// phase is immediate, so the label switches from prefill to generation before
/// the first token and then follows the generation. The callbacks only take a
/// short lock and yield: they never block the engine thread.
///
/// Prefill progress is relative to the sync. The shim announces the sync with a
/// `prefill_start` event whose `current` is the reused prefix and whose `total`
/// is the prompt length: that is the baseline of both the progress and the
/// rate. DS4 then reports absolute positions (`total` still the prompt length);
/// the GLM tensor-parallel path reports positions relative to the start
/// instead. Without a `prefill_start`, the first prefill event is the baseline.
/// The final values of the round are not computed here: the engine reports
/// them exactly (`DS4SessionStats`).
final class DS4ThroughputReporter: Sendable {
    typealias Phase = DirectAgentGenerationThroughput.Phase

    static let minimumInterval = Duration.milliseconds(250)
    /// Event the shim emits once, before DS4 starts evaluating the prompt.
    static let prefillStartEvent = "prefill_start"

    private struct PrefillBaseline {
        /// Absolute position the evaluation starts from (the reused prefix).
        var cached: Int
        /// Prompt length announced by `prefill_start`; `nil` when the baseline
        /// was inferred from the first prefill event.
        var announcedPromptTotal: Int?
        var instant: ContinuousClock.Instant
    }

    private struct State {
        var prefillBaseline: PrefillBaseline?
        var prefillTokensPerSecond: Double?
        var generationStartedAt: ContinuousClock.Instant?
        var generatedTokens = 0
        var lastEmission: (phase: Phase, instant: ContinuousClock.Instant)?
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<DirectAgentEvent>.Continuation
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        continuation: AsyncStream<DirectAgentEvent>.Continuation,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.continuation = continuation
        self.now = now
    }

    /// Progress callback of `sync`. Only `prefill*` events with a known total
    /// describe the evaluation of the prompt; the others (for example
    /// `distributed_route_wait`) are ignored.
    func reportPrefill(event: String, current: Int, total: Int) {
        guard event.hasPrefix("prefill"), total > 0 else {
            return
        }
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            let baseline: PrefillBaseline
            if event == Self.prefillStartEvent {
                baseline = PrefillBaseline(cached: current, announcedPromptTotal: total, instant: instant)
            } else if let known = state.prefillBaseline {
                baseline = known
            } else {
                baseline = PrefillBaseline(cached: current, announcedPromptTotal: nil, instant: instant)
            }
            state.prefillBaseline = baseline

            let promptTotal = baseline.announcedPromptTotal ?? total
            let target = promptTotal - baseline.cached
            guard target > 0 else {
                return nil
            }
            // A `total` other than the prompt length marks positions that are
            // already relative to the start of the evaluation.
            let position = total == promptTotal ? current - baseline.cached : current
            let processed = min(max(position, 0), target)
            let elapsed = Self.seconds(from: baseline.instant, to: instant)
            guard Self.shouldEmit(.prefill, at: instant, state: &state) else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .prefill,
                prefillTokensPerSecond: processed > 0 && elapsed > 0 ? Double(processed) / elapsed : nil,
                processedTokens: processed,
                targetTokens: target
            )
        }
        emit(throughput)
    }

    /// Records the start of the generation, right after the sync has ended.
    ///
    /// `prefillTokensPerSecond` is the exact prefill speed of the engine for
    /// this round (`nil` when no prompt was evaluated). When it is known the
    /// phase switches to generation at once, so the label shows it before the
    /// first token. That update does not delay the one of the first token.
    func beginGeneration(prefillTokensPerSecond: Double?) {
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            state.generationStartedAt = instant
            state.generatedTokens = 0
            state.prefillTokensPerSecond = prefillTokensPerSecond
            // The first generated token is always emitted immediately.
            state.lastEmission = nil
            guard let prefillTokensPerSecond else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: prefillTokensPerSecond,
                generationTokensPerSecond: nil
            )
        }
        emit(throughput)
    }

    /// `onText` callback of `generate`: one call per committed token.
    func recordGeneratedToken() {
        let instant = now()
        let throughput = state.withLock { state -> DirectAgentGenerationThroughput? in
            state.generatedTokens += 1
            let startedAt = state.generationStartedAt ?? instant
            let elapsed = Self.seconds(from: startedAt, to: instant)
            guard Self.shouldEmit(.generation, at: instant, state: &state) else {
                return nil
            }
            return DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: state.prefillTokensPerSecond,
                generationTokensPerSecond: elapsed > 0 ? Double(state.generatedTokens) / elapsed : nil
            )
        }
        emit(throughput)
    }

    private func emit(_ throughput: DirectAgentGenerationThroughput?) {
        guard let throughput else {
            return
        }
        continuation.yield(.metrics(DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            completionTokenCount: nil,
            throughput: throughput,
            isLiveProgress: true
        )))
    }

    private static func shouldEmit(_ phase: Phase, at instant: ContinuousClock.Instant, state: inout State) -> Bool {
        if let last = state.lastEmission,
           last.phase == phase,
           last.instant.duration(to: instant) < minimumInterval {
            return false
        }
        state.lastEmission = (phase: phase, instant: instant)
        return true
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
