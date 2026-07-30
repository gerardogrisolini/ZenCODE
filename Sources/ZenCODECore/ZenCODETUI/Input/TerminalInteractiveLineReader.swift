//
//  TerminalInteractiveLineReader.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization
#if canImport(os)
import os
#endif

public final class TerminalInteractiveLineReader: Sendable {
    enum Key: Equatable {
        case character(String)
        case paste(String)
        case enter
        case newline
        case tab
        case backspace
        case delete
        case left
        case right
        case up
        case down
        case home
        case end
        case clearBeforeCursor
        case clearAfterCursor
        case toggleToolDetails
        case toggleAccessMode
        case endOfInput
        case cancel
        case unknown
    }

    enum KeyReadResult: Equatable {
        case key(Key)
        case timedOut
        case endOfInput
    }

    /// Poll granularity used by cancellation-aware blocking reads. Short enough
    /// that a cancelled read unwinds promptly, long enough not to spin.
    static let cancellationPollTimeout: Int32 = 50
    /// Idle interval used while a consent prompt owns the terminal.
    static let consentBackoffSeconds: TimeInterval = 0.02
    static let escapeSequenceInitialTimeout: Int32 = 120
    static let escapeSequenceContinuationTimeout: Int32 = 60
    static let bracketedPasteByteTimeout: Int32 = 2000
    static let escapeSequenceMaximumLength = 24
    static let maximumPanelCommandSuggestionLines = 6

    /// Ownership of the terminal by the input panel.
    ///
    /// Only one code path may hold the TTY at a time, and the transient states
    /// matter as much as the settled ones: a stop is not done when it clears
    /// `panelTask`, it is done when it has awaited the loop task *and* restored
    /// raw mode. A start admitted before that would call `beginRawMode()`, get
    /// `true` because the terminal is still raw from the previous session, and
    /// then have its termios state torn down by the predecessor's
    /// `restoreRawMode()`. Modelling `starting`/`stopping` explicitly lets the
    /// racing side wait for quiescence instead of stepping into that window.
    enum PanelLifecycleState: Sendable {
        /// No panel owns the terminal and no transition is in flight.
        case idle
        /// A start has been admitted and is acquiring raw mode.
        case starting
        /// The panel loop owns the terminal; `panelTask` is its task.
        case running
        /// A stop is unwinding the loop and restoring raw mode.
        case stopping
    }

    /// Outcome of trying to claim the panel for a new start.
    enum PanelStartAdmission: Equatable, Sendable {
        /// The caller owns the `starting` transition and must publish or
        /// abandon it.
        case admitted
        /// A panel is already running or being started; the caller must not
        /// touch the terminal.
        case alreadyActive
        /// A stop is still unwinding; the caller has to wait for quiescence
        /// before it can be admitted.
        case transitionInFlight
    }

    /// All mutable reader state is owned by this mutex. Keeping the input
    /// history together with the panel state is important: raw line reads and
    /// panel reads can both navigate history, and neither may observe a partial
    /// update from the other.
    struct State {
        var history: [String] = []
        var historyIndex: Int?
        var draftBeforeHistory: [Character] = []
        var panelTask: Task<Void, Never>?
        var panelLifecycle: PanelLifecycleState = .idle
        /// Callers parked until the in-flight start or stop reaches a settled state.
        var panelTransitionWaiters: [CheckedContinuation<Void, Never>] = []
        var panelStatusBar: TerminalStatusBar?
        var panelBuffer: [Character] = []
        var panelCursorIndex = 0
        var panelIsProcessing = false
        var panelQueuedPromptCount = 0
        var panelOverlayOverride: TerminalPanelModeOverride?
        var panelCommandSuggestions: [TerminalCommandSuggestion] = []
        var panelCommandSuggestionIndex = 0
        /// Cancellation token of the panel loop's in-flight blocking read. Stopping
        /// the panel cancels it so the loop unwinds at once instead of waiting out
        /// the current read timeout while the caller awaits the task.
        var panelReadToken: TerminalBlockingReadToken?
        var panelRenderRevision: UInt64 = 0
    }

    let rawInput: TerminalRawInput
    let state = Mutex(State())

    public init() {
        rawInput = TerminalRawInput()
    }

    init(rawInput: TerminalRawInput) {
        self.rawInput = rawInput
    }

    func withPanelLock<T: Sendable>(
        _ body: @Sendable (inout State) throws -> T
    ) rethrows -> T {
        try state.withLock { state in
            try body(&state)
        }
    }

    public func readSingleKey(prompt: String) -> String? {
        readSingleKeyInternal(prompt: prompt, shouldCancel: nil)
    }

    func readSingleKey(
        prompt: String,
        shouldCancel: @escaping @Sendable () -> Bool
    ) -> String? {
        readSingleKeyInternal(prompt: prompt, shouldCancel: shouldCancel)
    }

    private func readSingleKeyInternal(
        prompt: String,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> String? {
        AgentOutput.standardError.writeString(prompt)

        // Raw mode is what makes this a *single-key* read. When it cannot be
        // enabled the terminal stays canonical and delivers nothing until Enter,
        // which looks exactly like a prompt that ignores `r`/`a`/`c`. Say so
        // once instead of leaving the operator pressing keys with no effect.
        let isRawMode = rawInput.beginRawMode()
        if !isRawMode {
            AgentOutput.standardError.writeString(
                "\n[ZenCODE] Single-key input unavailable; type your choice and press Enter.\n"
            )
        }
        defer {
            if isRawMode {
                rawInput.restoreRawMode()
            }
        }

        while true {
            if shouldCancel?() == true {
                AgentOutput.standardError.writeString("\n")
                return nil
            }
            let readResult = readKeyResult(
                pollTimeoutMilliseconds: shouldCancel == nil ? nil : 100
            )
            let key: Key
            switch readResult {
            case let .key(value):
                key = value
            case .timedOut:
                continue
            case .endOfInput:
                AgentOutput.standardError.writeString("\n")
                return nil
            }

            switch key {
            case let .character(text):
                AgentOutput.standardError.writeString("\(text)\n")
                return text
            case let .paste(text):
                guard let firstCharacter = text.first else {
                    continue
                }
                let value = String(firstCharacter)
                AgentOutput.standardError.writeString("\(value)\n")
                return value
            case .enter:
                AgentOutput.standardError.writeString("\n")
                return ""
            case .endOfInput:
                AgentOutput.standardError.writeString("\n")
                return nil
            default:
                continue
            }
        }
    }

    public func readLine(prompt: String) -> String? {
        readLineInternal(prompt: prompt, shouldCancel: nil)
    }

    /// Cancellation-aware variant used by the async bridges.
    ///
    /// A blocking `read` cannot observe `Task.isCancelled` (it runs off the
    /// cooperative pool), so the caller supplies a token that is polled between
    /// short read timeouts. The read then unwinds on cancellation instead of
    /// holding the terminal until the operator presses a key.
    func readLine(
        prompt: String,
        shouldCancel: @escaping @Sendable () -> Bool
    ) -> String? {
        readLineInternal(prompt: prompt, shouldCancel: shouldCancel)
    }

    private func readLineInternal(
        prompt: String,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> String? {
        var buffer: [Character] = []
        var cursorIndex = 0
        var renderedLineCount = 1
        withPanelLock { state in
            state.historyIndex = nil
            state.draftBeforeHistory.removeAll()
        }

        AgentOutput.standardError.writeString(prompt)

        return rawInput.withRawTerminal {
            // Tracks how many terminal rows the previous redraw spanned so the
            // next one can clear every row it occupied. Without this, a buffer
            // containing newlines (Option/Shift+Enter) would leave earlier rows
            // on screen and each redraw would reprint the whole buffer, making
            // the prompt appear to duplicate itself line after line.
            func redrawBuffer() {
                AgentOutput.standardError.writeString(
                    Self.redrawSequence(
                        prompt: prompt,
                        buffer: buffer,
                        cursorIndex: cursorIndex,
                        previousLineCount: renderedLineCount
                    )
                )
                renderedLineCount = Self.lineCount(for: buffer)
            }

            while true {
                if shouldCancel?() == true {
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }
                let key: Key
                switch readKeyResult(
                    pollTimeoutMilliseconds: shouldCancel == nil
                        ? nil
                        : Self.cancellationPollTimeout
                ) {
                case let .key(value):
                    key = value
                case .timedOut:
                    continue
                case .endOfInput:
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }

                switch key {
                case let .character(text), let .paste(text):
                    let characters = Array(text)
                    guard !characters.isEmpty else {
                        continue
                    }
                    buffer.insert(contentsOf: characters, at: cursorIndex)
                    cursorIndex += characters.count
                    redrawBuffer()
                case .enter:
                    let line = String(buffer)
                    AgentOutput.standardError.writeString("\n")
                    recordHistory(line)
                    return line
                case .newline:
                    buffer.insert("\n", at: cursorIndex)
                    cursorIndex += 1
                    redrawBuffer()
                case .tab:
                    continue
                case .backspace:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.remove(at: cursorIndex - 1)
                    cursorIndex -= 1
                    redrawBuffer()
                case .delete:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.remove(at: cursorIndex)
                    redrawBuffer()
                case .left:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    cursorIndex -= 1
                    AgentOutput.standardError.writeString("\u{1B}[1D")
                case .right:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    cursorIndex += 1
                    AgentOutput.standardError.writeString("\u{1B}[1C")
                case .up:
                    guard let previous = previousHistory(currentBuffer: buffer) else {
                        continue
                    }
                    buffer = previous
                    cursorIndex = buffer.count
                    redrawBuffer()
                case .down:
                    guard let next = nextHistory() else {
                        continue
                    }
                    buffer = next
                    cursorIndex = buffer.count
                    redrawBuffer()
                case .home:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(cursorIndex)D")
                    cursorIndex = 0
                case .end:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(buffer.count - cursorIndex)C")
                    cursorIndex = buffer.count
                case .clearBeforeCursor:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.removeSubrange(0..<cursorIndex)
                    cursorIndex = 0
                    redrawBuffer()
                case .clearAfterCursor:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.removeSubrange(cursorIndex..<buffer.count)
                    redrawBuffer()
                case .toggleToolDetails, .toggleAccessMode:
                    continue
                case .endOfInput:
                    if buffer.isEmpty {
                        AgentOutput.standardError.writeString("\n")
                        return nil
                    }
                case .cancel:
                    continue
                case .unknown:
                    continue
                }
            }
        }
    }
}
