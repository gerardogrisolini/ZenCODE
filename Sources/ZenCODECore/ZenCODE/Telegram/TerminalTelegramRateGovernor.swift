//
//  TerminalTelegramRateGovernor.swift
//  ZenCODE
//

import Foundation

/// A single wait the governor asks the caller to perform.
///
/// The governor never sleeps itself: it computes *when* sending becomes legal
/// again and hands the decision back, so the caller's wait stays inside the
/// caller's task and remains cancellable end-to-end.
public struct TerminalTelegramGovernedDelay: Sendable, Equatable {
    public let duration: Duration
    public let reason: TerminalTelegramRateLimitReason

    init(duration: Duration, reason: TerminalTelegramRateLimitReason) {
        self.duration = duration
        self.reason = reason
    }
}

/// Why a send must wait: which window is exhausted.
public enum TerminalTelegramRateLimitReason: Sendable, Equatable {
    case perChat(Int64)
    case global
}

/// Message-send rate governor for the Telegram Bot API.
///
/// The Bot API enforces two windows: roughly one message per second to the
/// *same* chat and roughly 30 messages per second overall. This actor budgets
/// sends against both windows before the caller performs any network I/O.
///
/// Semantics:
/// * **Reservation is atomic per caller** — `reserve()` does not suspend, so
///   between the legality check and the timestamp write no other sender can
///   interleave and take the same slot.
/// * **Waits are cancellable** — the governor returns a delay and the *caller*
///   sleeps inside its own task; `Task.sleep` therefore reacts to cancellation
///   immediately instead of holding the task hostage in an actor queue.
/// * **Only explicit 429 retries** — `retryAfterFailure` records a
///   server-reported `retry_after` and returns `true` solely for a 429 whose
///   envelope carries one. Any other failure (including an ambiguous outcome)
///   returns `false`: the caller must surface the error and must not retry, so
///   a timeout or a network drop can never turn into an unsolicited duplicate
///   send.
actor TerminalTelegramRateGovernor {
    /// Per-chat window: 1 send per second to the same chat, as enforced by the
    /// Bot API.
    static let perChatWindow: Duration = .seconds(1)
    /// Global window: ~30 sends per second overall, with headroom kept below
    /// the hard ceiling so bursts stay inside it.
    static let globalWindow: Duration = .milliseconds(35)
    /// Upper bound on a server-provided `retry_after`, so a hostile or corrupt
    /// envelope cannot stall outbound traffic for hours.
    static let maximumServerRetryAfter: Duration = .seconds(60)
    /// Maximum retries for one logical send. The first attempt is not counted.
    static let maximumRetryCount = 2

    /// Timestamps (monotonic continuous time) of the sends already admitted.
    private var perChatSends: [Int64: ContinuousClock.Instant] = [:]
    private var globalSends: [ContinuousClock.Instant] = []
    /// Instants until which the global stream must pause, from server 429s.
    private var globalPauseUntil: ContinuousClock.Instant?
    /// Injectable monotonic time source. Default is the continuous clock; tests
    /// substitute a controllable one so window math is verified without real
    /// sleeping.
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    /// Returns the delay the caller must wait before sending to `chatID`, or
    /// `nil` when sending is legal now. Does not record anything.
    func delay(forChat chatID: Int64) -> TerminalTelegramGovernedDelay? {
        let now = now()

        if let pause = globalPauseUntil, now < pause {
            return TerminalTelegramGovernedDelay(
                duration: pause - now,
                reason: .global
            )
        }

        if let lastPerChat = perChatSends[chatID],
           let remaining = Self.remainingDuration(from: lastPerChat, window: Self.perChatWindow, now: now),
           remaining > .zero {
            return TerminalTelegramGovernedDelay(
                duration: remaining,
                reason: .perChat(chatID)
            )
        }

        if let delay = globalDelay(now: now) {
            return delay
        }
        return nil
    }

    /// Atomically checks and reserves one outbound slot. A caller receiving a
    /// delay must sleep and call `reserve` again; no timestamp is written until
    /// the reservation is legal, so concurrent callers cannot share a slot.
    func reserve(chatID: Int64) -> TerminalTelegramGovernedDelay? {
        if let delay = delay(forChat: chatID) {
            return delay
        }
        record(chatID: chatID)
        return nil
    }

    /// Records a send to `chatID` as admitted. Split from `delay(forChat:)` so
    /// a caller that waits (or gives up) records exactly one send attempt.
    func record(chatID: Int64) {
        let now = now()
        perChatSends[chatID] = now
        globalSends.append(now)
        trimGlobalSends(now: now)
        // Bounded memory: the per-chat map is keyed by remote identifiers. In
        // the single-link deployment it holds one entry; if a caller ever
        // multiplexes, stale stamps are dropped wholesale rather than growing.
        if perChatSends.count > 64 {
            perChatSends = [chatID: now]
        }
    }

    /// Convenience: checks, and records only when legal now.
    func tryRecord(chatID: Int64) -> Bool {
        guard delay(forChat: chatID) == nil else {
            return false
        }
        record(chatID: chatID)
        return true
    }

    /// Reports a failed send attempt to the governor.
    ///
    /// Returns `true` only for an explicit 429 with a decodable
    /// `retry_after`, in which case the caller may retry the *same* send after
    /// the delay returned by a following `delay(forChat:)` call. Every other
    /// outcome returns `false` and must be surfaced without a retry.
    @discardableResult
    func retryAfterFailure(
        _ error: TerminalTelegramControlError,
        chatID: Int64
    ) -> Bool {
        guard case let .apiFailure(status, _, _, retryAfter) = error,
              status == 429,
              let retryAfter,
              retryAfter >= 0 else {
            return false
        }
        let delay = Self.boundedRetryDelay(retryAfter: retryAfter)
        let resume = now() + delay
        if let pause = globalPauseUntil {
            globalPauseUntil = max(pause, resume)
        } else {
            globalPauseUntil = resume
        }
        // A 429 on one chat is evidence the per-chat window was misjudged too:
        // align that chat's stamp with the server-reported resume instant so
        // the retry waits for the full reported window.
        perChatSends[chatID] = resume
        return true
    }

    /// Drops all recorded admissions (used at teardown/rebind).
    func reset() {
        perChatSends.removeAll()
        globalSends.removeAll()
        globalPauseUntil = nil
    }

    // MARK: - Internals

    private func globalDelay(now: ContinuousClock.Instant) -> TerminalTelegramGovernedDelay? {
        trimGlobalSends(now: now)
        // With a spacing-based budget (one send per `globalWindow`) the oldest
        // admission inside the window is exactly what the next send waits on.
        if let oldest = globalSends.first,
           let remaining = Self.remainingDuration(
               from: oldest,
               window: Self.globalWindow,
               now: now
           ),
           remaining > .zero {
            return TerminalTelegramGovernedDelay(
                duration: remaining,
                reason: .global
            )
        }
        return nil
    }

    private func trimGlobalSends(now: ContinuousClock.Instant) {
        while let oldest = globalSends.first,
              Self.remainingDuration(from: oldest, window: Self.globalWindow, now: now) == nil {
            globalSends.removeFirst()
        }
    }

    private static func remainingDuration(
        from instant: ContinuousClock.Instant,
        window: Duration,
        now: ContinuousClock.Instant
    ) -> Duration? {
        let elapsed = now - instant
        // elapsed is a Swift Duration; compare against the window directly.
        if elapsed >= window {
            return nil
        }
        return window - elapsed
    }

    private static func boundedRetryDelay(retryAfter: Int) -> Duration {
        let raw = Duration.seconds(retryAfter)
        return min(raw, maximumServerRetryAfter)
    }
}
