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
        /// Start/end of the current line (`Ctrl+A`/`Ctrl+E`, `Home`/`End`).
        case home
        case end
        /// Start/end of the whole draft (`Alt+<`/`Alt+>`, `Ctrl+Home`/`Ctrl+End`).
        case bufferStart
        case bufferEnd
        /// Word-wise motion (`Alt+←/→`, `Ctrl+←/→`, `ESC b`/`ESC f`).
        case wordLeft
        case wordRight
        /// Word-wise deletion (`Ctrl+W`, `Alt+D`).
        case deleteWordBefore
        case deleteWordAfter
        /// Whole-draft deletion (`Alt+Backspace`, macOS `Option+Delete`).
        case clearDraft
        case clearBeforeCursor
        case clearAfterCursor
        /// `Ctrl+G`.
        case toggleAccessMode
        /// `Ctrl+Y` opens the transient shared-chat reader.
        /// (`Ctrl+O` also works but is intercepted by some macOS terminals.)
        case toggleSharedChatReader
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
    /// Upper bound on retained history entries.
    ///
    /// The history lives for the whole process and is copied into the editor
    /// context on every keystroke, so it must not grow without limit in a long
    /// session. Two hundred entries cover realistic recall while keeping the
    /// copy cheap.
    static let maximumHistoryEntryCount = 200

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
        var panelTask: Task<Void, Never>?
        var panelLifecycle: PanelLifecycleState = .idle
        /// Callers parked until the in-flight start or stop reaches a settled state.
        var panelTransitionWaiters: [CheckedContinuation<Void, Never>] = []
        var panelStatusBar: TerminalStatusBar?
        /// All draft semantics live in the pure reducer; the mutex only owns
        /// the value, never the behaviour.
        var editor = TerminalPromptEditor()
        var panelIsProcessing = false
        var panelQueuedPromptCount = 0
        var panelPendingAttachmentCount = 0
        var panelOverlayOverride: TerminalPanelModeOverride?
        var panelSharedChatReaderIsOpen = false
        var panelCommandSuggestions: [TerminalCommandSuggestion] = []
        /// Pull-based source of live `@mention` suggestions.
        ///
        /// Roster changes reach the panel as push events, but those events are
        /// the only evictable entry of the bounded terminal queue and are emitted
        /// only when the roster signature changes. Asking for the current roster
        /// while the operator is actually typing a mention makes the list correct
        /// even when a push notification was dropped.
        var panelMentionSuggestionsProvider: (@Sendable () async -> [TerminalCommandSuggestion])?
        /// Single-flight guard so a burst of keystrokes cannot start one roster
        /// query per key.
        var isRefreshingMentionSuggestions = false
        /// Cancellation token of the panel loop's in-flight blocking read. Stopping
        /// the panel cancels it so the loop unwinds at once instead of waiting out
        /// the current read timeout while the caller awaits the task.
        var panelReadToken: TerminalBlockingReadToken?
        var panelRenderRevision: UInt64 = 0

        // Projections kept so existing call sites and lifecycle tests keep
        // addressing the draft by name instead of reaching into the reducer.
        var panelBuffer: [Character] {
            get { editor.buffer }
            set { editor.buffer = newValue }
        }

        var panelCursorIndex: Int {
            get { editor.cursorIndex }
            set { editor.cursorIndex = newValue }
        }

        var historyIndex: Int? {
            get { editor.historyIndex }
            set { editor.historyIndex = newValue }
        }

        var draftBeforeHistory: [Character] {
            get { editor.draftBeforeHistory }
            set { editor.draftBeforeHistory = newValue }
        }

        var panelCommandSuggestionIndex: Int {
            get { editor.suggestionIndex }
            set { editor.suggestionIndex = newValue }
        }
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
        // The fallback reader owns a private editor value: it runs only when
        // the panel cannot, and sharing the reducer here is what keeps a single
        // definition of motion, word edits and history for both paths.
        var editor = TerminalPromptEditor()
        let initialTerminalColumns = TerminalChat.terminalColumnCount(forceRefresh: true)
        let initialLayout = Self.renderLayout(
            prompt: prompt,
            buffer: editor.buffer,
            cursorIndex: editor.cursorIndex,
            terminalColumns: initialTerminalColumns
        )
        var renderedLineCount = initialLayout.lineCount
        var renderedCursorRow = initialLayout.cursorRow
        withPanelLock { state in
            state.historyIndex = nil
            state.draftBeforeHistory.removeAll()
        }

        AgentOutput.standardError.writeString(initialLayout.text)

        return rawInput.withRawTerminal {
            // Tracks the full old cursor location as well as the old footprint:
            // after navigating within a multi-line draft, the cursor is often
            // not on its final row and clearing must start at the first row.
            func redrawBuffer() {
                let terminalColumns = TerminalChat.terminalColumnCount(forceRefresh: true)
                AgentOutput.standardError.writeString(
                    Self.redrawSequence(
                        prompt: prompt,
                        buffer: editor.buffer,
                        cursorIndex: editor.cursorIndex,
                        previousLineCount: renderedLineCount,
                        previousCursorRow: renderedCursorRow,
                        terminalColumns: terminalColumns
                    )
                )
                let layout = Self.renderLayout(
                    prompt: prompt,
                    buffer: editor.buffer,
                    cursorIndex: editor.cursorIndex,
                    terminalColumns: terminalColumns
                )
                renderedLineCount = layout.lineCount
                renderedCursorRow = layout.cursorRow
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

                // The blocking reader has no completion menu and must not
                // discard a half-typed answer on `Esc`.
                let context = TerminalPromptEditorContext(
                    history: withPanelLock { $0.history },
                    supportsCompletions: false,
                    clearsDraftOnCancel: false
                )

                switch editor.apply(key, context: context) {
                case .ignored, .toggleAccessMode, .toggleSharedChatReader, .cancelRequested:
                    continue
                case .changed:
                    redrawBuffer()
                case let .submitted(line):
                    AgentOutput.standardError.writeString("\n")
                    recordHistory(line)
                    return line
                case .endOfInput:
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }
            }
        }
    }
}
