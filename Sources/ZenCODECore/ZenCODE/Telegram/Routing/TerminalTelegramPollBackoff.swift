//
//  TerminalTelegramPollBackoff.swift
//  ZenCODE
//

import Foundation

/// One long-poll failure as reported to dispatcher subscribers.
struct TerminalTelegramPollFailure: Sendable, Equatable {
    /// Operator-facing text, bot token already redacted.
    let text: String
    /// `true` for failures retrying will not fix by itself (401/403 invalid
    /// token, 409 conflicting poller or webhook).
    let isPersistent: Bool
}

/// Poll-health transition surfaced to the interactive terminal.
enum TerminalTelegramPollHealthNotice: Sendable, Equatable {
    /// Polling entered a persistent failure: no message will arrive until the
    /// operator fixes the token or stops the other poller.
    case failing(String)
    /// The first successful poll after a notified persistent failure.
    case recovered
}

/// Pure retry policy for the Bot API long poll.
///
/// - Transient failures (network, 5xx, undecodable bodies): exponential backoff
///   from ``baseDelay`` up to ``maximumDelay`` with multiplicative jitter.
/// - 429: honours the server `retry_after`, bounded by the same cap the
///   rate governor uses.
/// - 401/403 (revoked or invalid token) and 409 (another poller / webhook):
///   not recoverable by retrying quickly, so the loop keeps going at the long
///   ``persistentFailureDelay`` (the token may be fixed from setup) while the
///   error is surfaced to the operator.
/// - The first successful poll resets the sequence.
struct TerminalTelegramPollBackoff: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case transient
        case rateLimited
        /// 401/403 or an unusable token.
        case invalidToken
        /// 409: another `getUpdates` consumer or an active webhook.
        case conflict

        /// Failures that retrying will not fix by itself.
        var isPersistent: Bool { self == .invalidToken || self == .conflict }
    }

    struct Decision: Sendable, Equatable {
        let kind: Kind
        let delay: Duration
    }

    static let baseDelay: Duration = .seconds(3)
    static let maximumDelay: Duration = .seconds(60)
    static let persistentFailureDelay: Duration = .seconds(60)
    static let maximumServerRetryAfter = TerminalTelegramRateGovernor.maximumServerRetryAfter

    /// Consecutive failures since the last successful poll.
    private(set) var consecutiveFailures = 0

    static func classify(_ error: Error) -> (kind: Kind, retryAfter: Int?) {
        guard let error = error as? TerminalTelegramControlError else {
            return (.transient, nil)
        }
        switch error {
        case .invalidToken, .missingConfiguration:
            return (.invalidToken, nil)
        case let .apiFailure(status, errorCode, _, retryAfter):
            let code = errorCode ?? status
            switch (status, code) {
            case (429, _), (_, 429):
                return (.rateLimited, retryAfter)
            case (401, _), (403, _), (_, 401), (_, 403):
                return (.invalidToken, nil)
            case (409, _), (_, 409):
                return (.conflict, nil)
            default:
                return (.transient, nil)
            }
        case let .httpError(status, _):
            switch status {
            case 401, 403: return (.invalidToken, nil)
            case 409: return (.conflict, nil)
            case 429: return (.rateLimited, nil)
            default: return (.transient, nil)
            }
        default:
            return (.transient, nil)
        }
    }

    /// Registers a failure and returns how long to wait before the next poll.
    /// `jitter` is a unit-interval sample (injected for determinism); it scales
    /// the exponential delay by 0.75...1.25 and the result never exceeds the cap.
    mutating func recordFailure(_ error: Error, jitter: Double = 0.5) -> Decision {
        consecutiveFailures += 1
        let (kind, retryAfter) = Self.classify(error)
        switch kind {
        case .invalidToken, .conflict:
            return Decision(kind: kind, delay: Self.persistentFailureDelay)
        case .rateLimited:
            if let retryAfter, retryAfter >= 0 {
                let bounded = min(Duration.seconds(max(retryAfter, 1)), Self.maximumServerRetryAfter)
                return Decision(kind: kind, delay: bounded)
            }
        case .transient:
            break
        }
        return Decision(kind: kind, delay: exponentialDelay(jitter: jitter))
    }

    /// Call after a successful poll.
    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    private func exponentialDelay(jitter: Double) -> Duration {
        let exponent = min(max(consecutiveFailures - 1, 0), 10)
        let seconds = 3.0 * Double(1 << exponent)
        let clampedJitter = min(max(jitter, 0), 1)
        let scaled = seconds * (0.75 + 0.5 * clampedJitter)
        let capped = min(scaled, 60.0)
        return .milliseconds(Int((capped * 1000).rounded()))
    }

    /// Operator-facing text for an error, with any bot token (`bot<id>:<secret>`
    /// as embedded in Bot API URLs) removed. Shared with every other Telegram
    /// diagnostic path through ``TerminalTelegramControlError/operatorDescription(_:)``.
    static func sanitizedDescription(_ error: Error) -> String {
        TerminalTelegramControlError.operatorDescription(error)
    }

    static func redactToken(in text: String) -> String {
        TerminalTelegramControlError.redactingToken(in: text)
    }
}
