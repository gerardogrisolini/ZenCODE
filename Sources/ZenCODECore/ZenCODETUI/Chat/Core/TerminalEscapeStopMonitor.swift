//
//  TerminalEscapeStopMonitor.swift
//  ZenCODE
//

import Foundation

enum TerminalEscapeStopMonitor {
    static func startIfNeeded(
        isEnabled: Bool,
        onStop: @escaping @Sendable () -> Void
    ) -> Task<Void, Never>? {
        guard isEnabled else {
            return nil
        }

        return Task.detached {
            let rawInput = TerminalRawInput()
            guard rawInput.beginRawMode() else {
                return
            }

            defer {
                rawInput.restoreRawMode()
            }

            while !Task.isCancelled {
                // Stand down while a consent prompt owns the terminal: this
                // monitor discards every byte that is not ESC, so reading here
                // would swallow the operator's `r`/`a`/`c` answer.
                guard let byte = TerminalConsentInputOwnership.withBackgroundRead({
                    rawInput.readByte(timeoutMilliseconds: 100)
                }) else {
                    if TerminalConsentInputOwnership.isConsentActive {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    continue
                }
                guard byte == 0x1B else {
                    continue
                }
                if rawInput.readByte(timeoutMilliseconds: 25) == nil {
                    onStop()
                    return
                }
                drainPendingEscapeSequence(rawInput: rawInput)
            }
        }
    }

    static func drainPendingEscapeSequence(rawInput: TerminalRawInput) {
        while rawInput.readByte(timeoutMilliseconds: 5) != nil {}
    }
}
