//
//  TerminalModifierKeyState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

#if os(macOS)
import CoreGraphics
#endif
import Foundation

/// Live modifier state of the keyboard the operator is typing on.
///
/// Terminals without an extended keyboard protocol (notably macOS
/// Terminal.app) send the same `CR` byte for Enter and Shift+Enter, the same
/// `DEL` byte for Backspace and Option+Backspace, and type a layout character
/// for Option+< and Option+>, so the byte stream alone cannot tell them apart.
/// In a local macOS session the keyboard belongs to the same login session as
/// zen, so the decoder can ask the system whether Shift or Option is held when
/// it reads one of those inputs. Over SSH and on other platforms the probes
/// are unavailable and always answer `false`.
struct TerminalModifierKeyState: Sendable {
    let isShiftPressed: @Sendable () -> Bool
    let isOptionPressed: @Sendable () -> Bool

    init(
        isShiftPressed: @escaping @Sendable () -> Bool = { false },
        isOptionPressed: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isShiftPressed = isShiftPressed
        self.isOptionPressed = isOptionPressed
    }

    /// A probe that never reports a pressed modifier.
    static let unavailable = TerminalModifierKeyState()

    /// The probe used in production for the current process.
    static func system(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalModifierKeyState {
        #if os(macOS)
        guard isLocalSession(environment: environment) else {
            return .unavailable
        }
        return TerminalModifierKeyState(
            isShiftPressed: {
                CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
            },
            isOptionPressed: {
                CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
            }
        )
        #else
        return .unavailable
        #endif
    }

    /// Whether zen runs on the machine whose keyboard produces the input.
    ///
    /// Over SSH zen receives the remote operator's bytes but cannot see their
    /// keyboard: the host's modifier state is unrelated, so Enter must keep
    /// submitting and Backspace keep deleting one character there.
    static func isLocalSession(environment: [String: String]) -> Bool {
        let sshVariables = ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]
        return !sshVariables.contains { environment[$0]?.isEmpty == false }
    }
}
