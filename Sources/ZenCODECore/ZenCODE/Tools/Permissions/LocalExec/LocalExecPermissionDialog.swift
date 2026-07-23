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

    static func terminalPrompt(
        for request: AgentToolAuthorizationRequest,
        terminalColumns: Int? = nil
    ) -> String {
        let useColor = AgentOutput.standardErrorIsTerminal
        let columns = terminalColumns ?? TerminalWidth.current(
            descriptors: [AgentOutput.standardError.fileDescriptor],
            fallback: 100,
            forceRefresh: true
        )

        let directory = Self.abbreviatedHomePath(
            Self.singleLined(Self.sanitizedForTerminal(request.workingDirectory))
        )
        let command = Self.singleLined(Self.sanitizedForTerminal(request.command))
        let hint = Self.compactAlwaysHint(forToolName: request.toolName)

        let commandLine = Self.commandLine(command: command, colored: useColor)
        let directoryPlain = "⊙ \(directory)"

        // The top border already identifies this as an authorization request;
        // the command itself is the primary body content, so repeating the
        // request title here would duplicate the same action in most prompts.
        // `renderConsentBox` measures visible terminal cells, excluding ANSI
        // escapes, and reflows these rows before it draws either border.
        let innerLines = [
            commandLine,
            Self.wrap(directoryPlain, code: Self.ansiDim, colored: useColor),
            Self.wrap(hint, code: Self.ansiDim, colored: useColor)
        ]

        // The run/always/cancel options and their compact key hint form the card
        // footer, set off from the command details by a divider rule. Keeping
        // `(r/a/c)` here avoids repeating the available choices below the box.
        let options = "[R]un once / [A]lways / [C]ancel"
        let footer = Self.wrap(options, code: Self.ansiCyanBold, colored: useColor)
        let box = Self.renderConsentBox(
            title: "Authorization",
            innerLines: innerLines,
            footer: footer,
            colored: useColor,
            terminalColumns: columns
        )
        // `readSingleKey` echoes the selected key followed by a newline. End the
        // box with a newline so that echo gets its own physical row and the TUI
        // resumes below the card instead of overwriting its bottom rows.
        return "\n\(box)\n"
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

    /// Collapses newlines, tabs, and repeated whitespace so untrusted fields
    /// become one logical line before the width-aware card renderer reflows them.
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
    private static func commandLine(command: String, colored: Bool) -> String {
        let marker = "❯ "
        guard !command.isEmpty else {
            return marker
        }
        guard let boundary = command.firstIndex(where: { $0.isWhitespace }) else {
            return marker + Self.wrap(command, code: Self.ansiCyanBold, colored: colored)
        }
        let executable = String(command[..<boundary])
        let rest = String(command[boundary...])
        return Self.wrap(marker, code: Self.ansiOrange, colored: colored)
            + Self.wrap(executable, code: Self.ansiCyanBold, colored: colored)
            + rest
    }

    /// Builds the orange-bordered card around the consent information. The card
    /// is content-driven up to the available terminal width, then its content is
    /// explicitly reflowed. Leaving the final terminal column unused prevents
    /// automatic right-margin wrapping from adding invisible physical rows that
    /// would desynchronize the TUI panel's cursor bookkeeping.
    private static func renderConsentBox(
        title: String,
        innerLines: [String],
        footer: String?,
        colored: Bool,
        terminalColumns: Int
    ) -> String {
        // A box row is `│ <content> │`, i.e. four visible cells of chrome.
        // Keep one terminal column spare so a row never triggers terminal
        // autowrap at the right margin.
        let safeRowWidth = max(4, terminalColumns - 1)
        let maximumInnerWidth = max(1, safeRowWidth - 4)
        var naturalWidths = innerLines.map(TerminalANSIText.visibleWidth)
        if let footer {
            naturalWidths.append(TerminalANSIText.visibleWidth(footer))
        }
        let innerWidth = min(
            maximumInnerWidth,
            max(min(28, maximumInnerWidth), naturalWidths.max() ?? 0)
        )
        let rule = String(repeating: "─", count: innerWidth + 2)
        let border = { Self.wrap($0, code: Self.ansiOrange, colored: colored) }

        // Top border embeds the title (`╭─ Title ────╮`), padded to the content
        // width so the title is the card heading, not a body row. On unusually
        // narrow terminals, fit the title itself before drawing the border.
        let topMiddleWidth = innerWidth + 1
        let untruncatedTitleSegment = " \(title) "
        let titleSegment = TerminalANSIText.visibleWidth(untruncatedTitleSegment) <= topMiddleWidth
            ? untruncatedTitleSegment
            : TerminalANSIText.truncate(title, to: topMiddleWidth)
        let titleSuffix = String(
            repeating: "─",
            count: max(0, topMiddleWidth - TerminalANSIText.visibleWidth(titleSegment))
        )
        var rows: [String] = [border("╭─\(titleSegment)\(titleSuffix)╮")]
        for line in Self.wrappedConsentRows(innerLines, width: innerWidth) {
            let padding = String(
                repeating: " ",
                count: max(0, innerWidth - TerminalANSIText.visibleWidth(line))
            )
            let body = " \(line)\(padding) "
            rows.append(border("│") + body + border("│"))
        }
        if let footer {
            rows.append(border("├\(rule)┤"))
            for line in Self.wrappedConsentRows([footer], width: innerWidth) {
                let padding = String(
                    repeating: " ",
                    count: max(0, innerWidth - TerminalANSIText.visibleWidth(line))
                )
                let body = " \(line)\(padding) "
                rows.append(border("│") + body + border("│"))
            }
        }
        rows.append(border("╰\(rule)╯"))
        return rows.joined(separator: "\n")
    }

    /// Reflows rendered content without counting ANSI escape sequences as cells.
    /// Whitespace is retained verbatim because this is a shell command preview;
    /// long unbroken arguments are split rather than allowed to overflow the
    /// border.
    private static func wrappedConsentRows(_ lines: [String], width: Int) -> [String] {
        lines.flatMap { TerminalANSIText.wrapPreservingWhitespace($0, width: width) }
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
        Self.colorChoiceLine("Please choose [R]un once / [A]lways / [C]ancel")
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
