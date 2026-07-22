//
//  LocalExecPermissionDialog.swift
//  ZenCODE
//

import Dispatch
import Foundation

/// Reads a single consent answer for a given prompt. Abstracted so the
/// terminal authorizer can present consent without owning the terminal reader,
/// letting the TUI route consent through its existing (single) interactive
/// reader and tests supply deterministic answers.
typealias ConsentKeyReader = @Sendable (String) async -> String?

extension LocalExecPermissionAuthorizer {
    /// Presents consent on the terminal itself, so the same flow works on
    /// macOS, Linux, and WSL — including over SSH, where a GUI `osascript`
    /// dialog would never reach the operator's screen.
    func presentDialog(
        for request: AgentToolAuthorizationRequest
    ) async -> PermissionDecision? {
        let reader = consentReader

        // Only the default terminal reader needs the headless diagnostic: an
        // injected reader (TUI panel path or tests) owns its own availability
        // and must not be bypassed by this check.
        if reader == nil, !TerminalRawInput.supportsInteractiveInput() {
            AgentOutput.standardError.writeString(
                Self.nonInteractiveConsentMessage(for: request)
            )
            return nil
        }

        let readKey: ConsentKeyReader = reader ?? { prompt in
            await Self.readTerminalKey(prompt: prompt)
        }

        var firstAttempt = true
        while true {
            let prompt = firstAttempt
                ? Self.terminalPrompt(for: request)
                : Self.terminalRetryPrompt()
            firstAttempt = false
            guard let answer = await readKey(prompt) else {
                // EOF / Ctrl+D: no consent obtainable.
                return nil
            }
            if let decision = Self.permissionDecision(forTerminalAnswer: answer) {
                return decision
            }
        }
    }

    /// Reads a single key from the terminal on a non-cooperative thread, so the
    /// authorizer actor (and its cooperative executor) is not blocked while the
    /// operator decides.
    static func readTerminalKey(prompt: String) async -> String? {
        guard TerminalRawInput.supportsInteractiveInput() else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: TerminalInteractiveLineReader().readSingleKey(prompt: prompt)
                )
            }
        }
    }

    static func nonInteractiveConsentMessage(for request: AgentToolAuthorizationRequest) -> String {
        """
        \nPermission required but no interactive terminal is available (this \
        happens in CI, pipes, or background sessions).
        The command was blocked by design (fail-closed) and was not run.

        Command:
        \(request.command)
        """
    }

    static func terminalPrompt(for request: AgentToolAuthorizationRequest) -> String {
        let title = Self.sanitizedForTerminal(request.title)
        let directory = Self.sanitizedForTerminal(request.workingDirectory)
        let command = Self.sanitizedForTerminal(request.command)
        return """
        \n\(title)

        Directory:
        \(directory)

        Command:
        \(command)
        
        If you continue, the command may read or modify files, run scripts, \
        and launch other local processes.

        [R]un once / [A]lways / [C]ancel (r/a/c):
        """
    }

    static func terminalRetryPrompt() -> String {
        "Please choose [R]un once / [A]lways / [C]ancel (r/a/c):"
    }

    /// Maps a single-key terminal answer to a permission decision. A genuine
    /// Enter (empty input) defaults to run-once, mirroring the previous macOS
    /// dialog's default button. Whitespace and unrecognized keys yield no
    /// decision so the prompt re-asks, rather than silently authorizing.
    static func permissionDecision(forTerminalAnswer answer: String) -> PermissionDecision? {
        if answer.isEmpty {
            return .allowOnce
        }
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "r":
            return .allowOnce
        case "a":
            return .allowAlways
        case "c":
            return .deny
        default:
            return nil
        }
    }

    /// Strips terminal control characters (ESC, CSI/OSC introducers, carriage
    /// return, bell, …) from untrusted request fields so a crafted command or
    /// title cannot clear, overwrite, or spoof the consent prompt. Newlines and
    /// tabs are preserved; other control bytes collapse to a space.
    static func sanitizedForTerminal(_ text: String) -> String {
        String(text.map { character -> Character in
            guard let scalar = character.unicodeScalars.first else {
                return " "
            }
            if character == "\n" || character == "\t" {
                return character
            }
            let value = scalar.value
            if value < 0x20 || (value > 0x7E && value < 0xA0) {
                return " "
            }
            return character
        })
    }
}
