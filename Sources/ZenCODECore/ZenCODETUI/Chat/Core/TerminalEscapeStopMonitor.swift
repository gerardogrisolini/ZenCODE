//
//  TerminalEscapeStopMonitor.swift
//  ZenCODE
//

import Foundation

enum TerminalEscapeStopMonitor {
    /// Poll granularity of the ESC watch. Short enough to observe cancellation
    /// promptly, long enough not to spin on an idle terminal.
    static let pollTimeoutMilliseconds: Int32 = 100

    /// Idle interval used while a consent prompt owns the terminal.
    static let consentBackoffSeconds: TimeInterval = 0.02

    /// Watches the terminal for a bare ESC while a turn is generating.
    ///
    /// The watch loop blocks on a POSIX `poll`/`read`. `Task.detached` would
    /// still schedule it on the Swift concurrency cooperative pool, so it is
    /// bridged through ``TerminalBlockingRead``: the blocking loop occupies a
    /// dedicated thread while the returned task only awaits it. Cancelling the
    /// task cancels the token, so the loop unwinds at its next poll boundary and
    /// restores the terminal instead of holding raw mode.
    static func startIfNeeded(
        isEnabled: Bool,
        rawInput: TerminalRawInput = TerminalRawInput(),
        managesRawMode: Bool = true,
        onStop: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard isEnabled else {
            return nil
        }

        return Task(name: "ZenCODE.TUI.escape-stop-monitor") {
            let didStop = await TerminalBlockingRead.run { token in
                watchForEscape(
                    token: token,
                    rawInput: rawInput,
                    managesRawMode: managesRawMode,
                    onStop: {}
                )
            }
            // Keep propagation inside the monitor task. The prompt lifecycle
            // awaits this task during teardown, so delegated agents are stopped
            // before the terminal turn is allowed to finish.
            if didStop == true {
                await onStop()
            }
        }
    }

    /// Blocking ESC watch. Returns when ESC is observed, on end of input, or on
    /// cancellation, always restoring the terminal it put into raw mode.
    static func watchForEscape(
        token: TerminalBlockingReadToken,
        rawInput: TerminalRawInput = TerminalRawInput(),
        managesRawMode: Bool = true,
        onPollStarted: @escaping @Sendable () -> Void = {},
        onStop: @Sendable () -> Void
    ) -> Bool? {
        guard !managesRawMode || rawInput.beginRawMode() else {
            return nil
        }

        defer {
            if managesRawMode {
                rawInput.restoreRawMode()
            }
        }

        while !token.isCancelled() {
            // Stand down while a consent prompt owns the terminal: this
            // monitor discards every byte that is not ESC, so reading here
            // would swallow the operator's `r`/`a`/`c` answer.
            guard let byte = TerminalConsentInputOwnership.withBackgroundRead({
                onPollStarted()
                return rawInput.readByte(timeoutMilliseconds: pollTimeoutMilliseconds)
            }) else {
                // Consent owns the terminal and no read happened, so nothing
                // throttled this iteration: idle on this dedicated thread
                // instead of spinning on the arbiter.
                Thread.sleep(forTimeInterval: consentBackoffSeconds)
                continue
            }
            guard byte == 0x1B else {
                continue
            }
            if rawInput.readByte(timeoutMilliseconds: 25) == nil {
                onStop()
                return true
            }
            drainPendingEscapeSequence(rawInput: rawInput)
        }
        return false
    }

    static func drainPendingEscapeSequence(rawInput: TerminalRawInput) {
        while rawInput.readByte(timeoutMilliseconds: 5) != nil {}
    }
}
