//
//  LocalExecPermissionDialog.swift
//  ZenCODE
//

import Dispatch
import Foundation
import Synchronization

/// Reads a single consent answer for a given prompt. Abstracted so the
/// terminal authorizer can present consent without owning the terminal reader,
/// letting the TUI route consent through its existing (single) interactive
/// reader and tests supply deterministic answers.
typealias ConsentKeyReader = @Sendable (String) async -> String?

final class ConsentReadCancellationFlag: Sendable {
    private let state = Mutex(false)

    func cancel() {
        state.withLock { $0 = true }
    }

    func isCancelled() -> Bool {
        state.withLock { $0 }
    }
}

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
        let cancellation = ConsentReadCancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(
                        returning: TerminalInteractiveLineReader().readSingleKey(
                            prompt: prompt,
                            shouldCancel: cancellation.isCancelled
                        )
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func nonInteractiveConsentMessage(for request: AgentToolAuthorizationRequest) -> String {
        let hint = Self.alwaysChoiceHint(forToolName: request.toolName)
        return """
        \nPermission required but no interactive terminal is available (this \
        happens in CI, pipes, or background sessions).
        The command was blocked by design (fail-closed) and was not run.

        Command:
        \(request.command)

        To pre-approve it, run in an interactive session and choose \
        [A]lways. \(hint)
        """
    }

    static func terminalPrompt(for request: AgentToolAuthorizationRequest) -> String {
        let useColor = AgentOutput.standardErrorIsTerminal

        let directory = Self.abbreviatedHomePath(
            Self.singleLined(Self.sanitizedForTerminal(request.workingDirectory))
        )
        let command = Self.singleLined(Self.sanitizedForTerminal(request.command))
        let hint = Self.compactAlwaysHint(forToolName: request.toolName)

        let title = Self.singleLined(Self.sanitizedForTerminal(request.title))
        let commandLine = Self.commandLine(command: command, colored: useColor)
        let directoryPlain = "⊙ \(directory)"

        // Each card row carries both its plain text (for box-width math) and its
        // ANSI-rendered form, so padding never counts invisible escape bytes.
        // The request title leads the body (what is being authorized); the
        // generic "Authorization" label is the card title in the top border.
        let innerLines: [(plain: String, rendered: String)] = [
            (title, Self.wrap(title, code: Self.ansiOrangeBold, colored: useColor)),
            (commandLine.plain, commandLine.rendered),
            (directoryPlain, Self.wrap(directoryPlain, code: Self.ansiDim, colored: useColor)),
            (hint, Self.wrap(hint, code: Self.ansiDim, colored: useColor))
        ]

        // The run/always/cancel options are the card footer, set off from the
        // command details by a divider rule and colored with the original cyan
        // accent so the decision reads as part of the box (matching the retry
        // prompt). The `(r/a/c):` prompt is the last text emitted (no trailing
        // newline) so the single-key reader echoes the operator's answer inline,
        // right after the colon.
        let options = "[R]un once / [A]lways / [C]ancel"
        let footer: (plain: String, rendered: String) = (
            options,
            Self.wrap(options, code: Self.ansiCyanBold, colored: useColor)
        )
        let box = Self.renderConsentBox(
            title: "Authorization",
            innerLines: innerLines,
            footer: footer,
            colored: useColor
        )
        let suffix = Self.wrap("(r/a/c): ", code: Self.ansiCyanBold, colored: useColor)
        return "\n\(box)\n  \(suffix)"
    }

    /// Orange ANSI accents reused across the consent card. Kept private so the
    /// dialog owns its palette without leaking terminal styling elsewhere.
    private static let ansiOrange = "\u{1B}[38;5;208m"
    private static let ansiOrangeBold = "\u{1B}[1;38;5;208m"
    private static let ansiCyanBold = "\u{1B}[1;38;5;81m"
    private static let ansiDim = "\u{1B}[38;5;244m"
    private static let ansiReset = "\u{1B}[0m"

    private static func wrap(_ text: String, code: String, colored: Bool) -> String {
        colored ? "\(code)\(text)\(Self.ansiReset)" : text
    }

    /// Compact one-line summary of the "Always" scope so the card stays tight.
    /// The longer explanation still lives in `alwaysChoiceHint` for the headless
    /// (non-interactive) message; the substrings here keep the prompt tests green.
    private static func compactAlwaysHint(forToolName toolName: String) -> String {
        toolName == "local.exec"
            ? "always · remembered across sessions"
            : "always · this session only"
    }

    /// Collapses newlines, tabs, and repeated whitespace so every card row is a
    /// single visual line — the box renderer assumes exactly one line per row.
    private static func singleLined(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Replaces the user's home-directory prefix with `~` so paths stay short.
    private static func abbreviatedHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Splits the command into its executable token (bold cyan, so the operator
    /// can spot what would actually run) and the remaining arguments. Falls back
    /// to the whole string when the command is a single token.
    private static func commandLine(
        command: String,
        colored: Bool
    ) -> (plain: String, rendered: String) {
        let marker = "❯ "
        guard !command.isEmpty else {
            return (marker, marker)
        }
        guard let boundary = command.firstIndex(where: { $0.isWhitespace }) else {
            return (
                marker + command,
                marker + Self.wrap(command, code: Self.ansiCyanBold, colored: colored)
            )
        }
        let executable = String(command[..<boundary])
        let rest = String(command[boundary...])
        let rendered = Self.wrap(marker, code: Self.ansiOrange, colored: colored)
            + Self.wrap(executable, code: Self.ansiCyanBold, colored: colored)
            + rest
        return (marker + executable + rest, rendered)
    }

    /// Builds the orange-bordered card around the consent information. Width is
    /// content-driven (not full terminal) because the prompt is printed once and
    /// never redrawn frame by frame. The `title` is drawn inside the top border
    /// so it reads as the card heading rather than a body row. When a `footer`
    /// is supplied it is drawn as the last row, preceded by a divider rule that
    /// separates the choice options from the command details above.
    private static func renderConsentBox(
        title: String,
        innerLines: [(plain: String, rendered: String)],
        footer: (plain: String, rendered: String)?,
        colored: Bool
    ) -> String {
        var rowWidths = innerLines.map(\.plain.count)
        if let footer { rowWidths.append(footer.plain.count) }
        let innerWidth = max(28, rowWidths.max() ?? 0)
        let rule = String(repeating: "─", count: innerWidth + 2)
        let border = { Self.wrap($0, code: Self.ansiOrange, colored: colored) }

        // Top border embeds the title (`╭─ Title ────╮`), padded to the content
        // width so the title is the card heading, not a body row.
        let titleSegment = " \(title) "
        let titleSuffix = String(
            repeating: "─",
            count: max(0, innerWidth + 2 - (1 + titleSegment.count))
        )
        var rows: [String] = [border("╭─\(titleSegment)\(titleSuffix)╮")]
        for line in innerLines {
            let padding = String(repeating: " ", count: max(0, innerWidth - line.plain.count))
            let body = " \(line.rendered)\(padding) "
            rows.append(border("│") + body + border("│"))
        }
        if let footer {
            rows.append(border("├\(rule)┤"))
            let padding = String(repeating: " ", count: max(0, innerWidth - footer.plain.count))
            let body = " \(footer.rendered)\(padding) "
            rows.append(border("│") + body + border("│"))
        }
        rows.append(border("╰\(rule)╯"))
        return rows.joined(separator: "\n")
    }

    /// Explains the scope of the "Always" choice so the consent dialog makes
    /// the authorization duration unambiguous:
    /// - `local.exec`: every executable identity in the request is remembered
    ///   across sessions (persisted to the permissions manifest), so future
    ///   commands ask only when they introduce an unapproved identity.
    /// - Destructive direct tools (delete, push, restore, …): "Always" grants
    ///   the tool for the current session/process only; it is never persisted.
    static func alwaysChoiceHint(forToolName toolName: String) -> String {
        if toolName == "local.exec" {
            "Always: remember every executable identity in this request across sessions."
        } else {
            "Always: allow this tool for this session only."
        }
    }

    static func terminalRetryPrompt() -> String {
        Self.colorChoiceLine("Please choose [R]un once / [A]lways / [C]ancel (r/a/c): ")
    }

    /// Accent-colors the run/always/cancel choice line so the consent decision
    /// stands out, mirroring the cyan accent used for `/undo`. Color is applied
    /// only when standard error is an interactive terminal — the same gate the
    /// rest of the TUI uses — so pipes and captured output keep the plain,
    /// log-readable text. The whole line is colored as one unit so the option
    /// text stays contiguous.
    static func colorChoiceLine(_ line: String) -> String {
        guard AgentOutput.standardErrorIsTerminal else {
            return line
        }
        let accent = Self.ansiCyanBold
        let reset = "\u{1B}[0m"
        return "\(accent)\(line)\(reset)"
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
