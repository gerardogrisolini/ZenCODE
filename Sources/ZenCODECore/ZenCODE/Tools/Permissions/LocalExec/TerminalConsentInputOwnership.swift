//
//  TerminalConsentInputOwnership.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Arbitrates who may consume bytes from the shared controlling terminal.
///
/// A consent prompt (`local.exec` / destructive tool authorization) blocks the
/// turn until the operator answers, but it is presented while other terminal
/// readers may be alive — most notably the Esc-to-stop monitor, which polls the
/// same TTY during generation. Two readers on one file descriptor split the
/// input stream non-deterministically: whichever `read` wins gets the byte, and
/// the monitor discards everything that is not ESC. The operator then sees the
/// authorization card still waiting after pressing `r` or `a`.
///
/// Consent therefore claims exclusive ownership for the whole prompt, including
/// its retry rounds, and background readers stand down while that claim is held.
/// `beginConsent()` additionally waits for an in-flight background read to
/// finish, so no keystroke can be stolen by a read that started moments earlier.
///
/// `shared` guards the process's single controlling terminal; the type is
/// instantiable so tests can exercise the arbitration without contending on
/// that process-wide state.
final class TerminalConsentInputOwnership: Sendable {
    private struct State {
        var consentClaims = 0
        var activeBackgroundReads = 0
    }

    static let shared = TerminalConsentInputOwnership()

    private let state = Mutex(State())

    /// Poll interval used while waiting for background readers to stand down.
    private let quiescencePollNanoseconds: UInt64 = 5_000_000
    /// Upper bound on that wait. Background reads are short (≤100 ms polls), so
    /// this only guards against a reader that never reports completion.
    private let quiescenceAttemptLimit = 60

    /// Whether a consent prompt currently owns terminal input.
    var isConsentActive: Bool {
        state.withLock { $0.consentClaims > 0 }
    }

    /// Claims terminal input for a consent prompt and waits until no background
    /// reader is mid-`read`.
    func beginConsent() async {
        state.withLock { $0.consentClaims += 1 }
        for _ in 0..<quiescenceAttemptLimit {
            let isQuiescent = state.withLock { $0.activeBackgroundReads == 0 }
            if isQuiescent {
                return
            }
            try? await Task.sleep(nanoseconds: quiescencePollNanoseconds)
        }
    }

    func endConsent() {
        state.withLock { $0.consentClaims = max(0, $0.consentClaims - 1) }
    }

    /// Attempts to start a background terminal read. Returns `false` when a
    /// consent prompt owns the terminal, in which case the caller must not read.
    func beginBackgroundRead() -> Bool {
        state.withLock { state in
            guard state.consentClaims == 0 else {
                return false
            }
            state.activeBackgroundReads += 1
            return true
        }
    }

    func endBackgroundRead() {
        state.withLock { $0.activeBackgroundReads = max(0, $0.activeBackgroundReads - 1) }
    }

    /// Runs `body` only when no consent prompt owns the terminal, reporting the
    /// read as in flight so a concurrent `beginConsent()` waits for it.
    func withBackgroundRead<T>(_ body: () -> T) -> T? {
        guard beginBackgroundRead() else {
            return nil
        }
        defer { endBackgroundRead() }
        return body()
    }
}

extension TerminalConsentInputOwnership {
    /// Process-wide entry points used by the consent prompt and the terminal's
    /// background readers, which all share one controlling terminal.
    static var isConsentActive: Bool {
        shared.isConsentActive
    }

    static func beginConsent() async {
        await shared.beginConsent()
    }

    static func endConsent() {
        shared.endConsent()
    }

    static func withBackgroundRead<T>(_ body: () -> T) -> T? {
        shared.withBackgroundRead(body)
    }
}
