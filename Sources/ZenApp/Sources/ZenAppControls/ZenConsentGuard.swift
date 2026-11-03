//
//  ZenConsentGuard.swift
//  ZenApp
//
//  Keeps the inline consent card from being answered by a key or a click
//  meant for something else: the Return that sent the prompt, a held key,
//  a click that lands as the card slides in.
//

import Foundation

/// An input that can answer the consent card.
enum ZenConsentTrigger: Equatable, Sendable {
    /// Return on the focused choice; `isRepeat` for the auto-repeat of a
    /// held key.
    case key(isRepeat: Bool)
    /// A click on a choice button.
    case click
    /// Esc, which denies.
    case escape
}

/// The answer rules of the consent card, with an injectable clock.
///
/// The terminal semantics stay: the card takes the focus, Allow once is the
/// default, Return chooses and Esc denies. On top of them:
/// - Return and clicks answer only once the grace period
///   (``defaultGracePeriod``, 0.5 s) has passed since the card appeared,
///   since its request changed, or since the last key it does not handle
///   (``noteTyping()``); earlier ones are ignored, so a typist must pause
///   before Return answers.
/// - Key repeats never answer, whenever they arrive.
/// - Esc denies at once, even during the grace period.
/// - The card answers once per request.
struct ZenConsentGuard {
    /// The time after the card appears during which Return and clicks are
    /// ignored.
    static let defaultGracePeriod: Duration = .milliseconds(500)

    let gracePeriod: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    /// When the grace period last started: the card appeared, changed
    /// request, or received a key it does not handle.
    private(set) var presentedAt: ContinuousClock.Instant
    /// Whether the card has answered its request.
    private(set) var hasDecided = false

    /// - Parameters:
    ///   - gracePeriod: The time during which activations are ignored.
    ///   - now: The clock; tests inject a manual one.
    init(
        gracePeriod: Duration = Self.defaultGracePeriod,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.gracePeriod = gracePeriod
        self.now = now
        self.presentedAt = now()
    }

    /// The card appeared or shows a new request: the grace period starts
    /// again and the card can answer once more.
    mutating func restart() {
        presentedAt = now()
        hasDecided = false
    }

    /// The card received a key it does not handle (typing meant for the
    /// composer): the grace period starts again, so Return answers only
    /// after a pause of ``gracePeriod``. The answer, if any, stays.
    mutating func noteTyping() {
        presentedAt = now()
    }

    /// The time left before Return and clicks answer; zero once the card is
    /// armed.
    var remainingGrace: Duration {
        max(.zero, gracePeriod - (now() - presentedAt))
    }

    /// Whether Return and clicks answer now.
    var isArmed: Bool {
        remainingGrace == .zero
    }

    /// Whether `trigger` answers the card now. When it does, the answer is
    /// recorded and every later trigger is refused.
    mutating func admit(_ trigger: ZenConsentTrigger) -> Bool {
        guard !hasDecided else {
            return false
        }
        switch trigger {
        case .escape:
            break
        case .key(isRepeat: true):
            return false
        case .key(isRepeat: false), .click:
            guard isArmed else {
                return false
            }
        }
        hasDecided = true
        return true
    }
}
