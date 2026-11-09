//
//  TerminalInteractiveLineReader.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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
    enum Key: Equatable, Sendable {
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
        /// `PgUp`/`PgDn` (`CSI 5~`/`CSI 6~`, with or without a modifier).
        /// The prompt editor ignores them; only full-screen readers such as the
        /// sub-agent detail give them a meaning.
        case pageUp
        case pageDown
        /// Start/end of the current line (`Ctrl+A`/`Ctrl+E`, `Home`/`End`).
        case home
        case end
        /// Start/end of the whole draft (`Alt+<`/`Alt+>`, `Ctrl+Home`/`Ctrl+End`).
        case bufferStart
        case bufferEnd
        /// Word-wise motion (`Alt+←/→`, `Ctrl+←/→`, `ESC b`/`ESC f`).
        case wordLeft
        case wordRight
        /// Word-wise deletion (`Ctrl+W`, `Ctrl+Delete`).
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

    enum KeyReadResult: Equatable, Sendable {
        case key(Key)
        /// The parser consumed a base repeat behind Esc, not just Esc itself.
        case pickerEscape(consumedRepeat: Character)
        case timedOut
        case endOfInput

        var consumedPickerRepeat: Character? {
            guard case let .pickerEscape(base) = self else { return nil }
            return base
        }
    }

    /// A panel read timestamped on the blocking worker before it crosses back to
    /// the async loop. Uptime milliseconds are monotonic and never persisted.
    struct TimedPanelKeyReadResult: Sendable {
        let result: KeyReadResult
        let timestampMilliseconds: UInt64
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

    /// A caller parked on a panel transition, a render revision or a render
    /// drain. Resumed only after the panel lock is released.
    typealias PanelWaiter = CheckedContinuation<Void, Never>

    /// All mutable reader state is owned by this mutex. Keeping the input
    /// history together with the panel state is important: raw line reads and
    /// panel reads can both navigate history, and neither may observe a partial
    /// update from the other.
    struct State {
        var history: [String] = []
        /// Who owns the terminal through the panel: the start/stop transitions,
        /// the loop task, its read token and the callers parked on a transition.
        var panelLifecycle = PanelLifecycle<PanelWaiter>()
        var panelStatusBar: TerminalStatusBar?
        /// All draft semantics live in the pure reducer; the mutex only owns
        /// the value, never the behaviour.
        var editor = TerminalPromptEditor()
        /// Every live terminal panel uses the conservative repeat heuristic.
        var panelSupportsPressAndHold = true
        var panelIsProcessing = false
        /// Voice mode is reading an answer aloud; `Esc` stops it.
        var panelIsSpeaking = false
        var panelQueuedPromptCount = 0
        var panelPendingAttachmentCount = 0
        var panelOverlayOverride: TerminalPanelModeOverride?
        var panelSharedChatReaderIsOpen = false
        /// What the `/subagent` detail does with the panel keys. Unlike the
        /// draft it is not session state of the panel: stopping or resuming
        /// the panel (for a consent prompt, say) leaves it untouched, because
        /// only the chat loop that opened the detail may change it.
        var panelSubAgentDetailMode: SubAgentDetailMode = .closed
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
        /// The single-renderer pipeline that carries prompt snapshots to the
        /// status bar: queued frame, revisions and render waiters.
        var panelRender = PanelRenderPipeline<PanelWaiter>()
        /// The voice dictation previewed at the end of the draft.
        var voiceDictation = TerminalPromptDictation()
        /// Told the id of a dictation an edit ended, so voice forgets what
        /// it accumulated. Called outside the panel lock.
        var voiceDictationEndedHandler: (@Sendable (UInt64) -> Void)?

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

        // Read-only projections kept so lifecycle tests keep observing the
        // panel by its former field names. Every transition goes through
        // `panelLifecycle`.
        var panelTransitionWaiters: [PanelWaiter] {
            panelLifecycle.transitionWaiters
        }

        var panelReadToken: TerminalBlockingReadToken? {
            panelLifecycle.readToken
        }
    }

    let rawInput: TerminalRawInput
    let consentInputOwnership: TerminalConsentInputOwnership
    /// Resolves a plain `CR` to Shift+Enter, a plain `DEL`/`BS` to
    /// Option+Backspace and the layout's Option+</> characters to draft-wide
    /// motion where the terminal cannot encode the modifier.
    let modifierKeyState: TerminalModifierKeyState
    let state = Mutex(State())

    public init() {
        rawInput = TerminalRawInput()
        consentInputOwnership = .shared
        modifierKeyState = .system()
    }

    init(
        rawInput: TerminalRawInput,
        consentInputOwnership: TerminalConsentInputOwnership = .shared,
        modifierKeyState: TerminalModifierKeyState = .system()
    ) {
        self.rawInput = rawInput
        self.consentInputOwnership = consentInputOwnership
        self.modifierKeyState = modifierKeyState
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
        shouldCancel: @escaping @Sendable () -> Bool,
        screen: TerminalPrimaryScreen? = nil
    ) -> String? {
        readSingleKeyInternal(prompt: prompt, shouldCancel: shouldCancel, screen: screen)
    }

    private func readSingleKeyInternal(
        prompt: String,
        shouldCancel: (@Sendable () -> Bool)?,
        screen injectedScreen: TerminalPrimaryScreen? = nil
    ) -> String? {
        let modal = (injectedScreen ?? TerminalPrimaryScreen.active).map { TerminalModalSession(screen: $0) }
        defer { modal?.close() }
        if let modal {
            modal.updateDialog(TerminalDialogPresentation(prompt: prompt))
        } else { AgentOutput.standardError.writeString(prompt) }
        func echo(_ text: String) {
            if modal == nil { AgentOutput.standardError.writeString(text) }
        }

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
            if modal?.isCancelled == true || shouldCancel?() == true {
                echo("\n")
                return nil
            }
            let readResult = readKeyResult(
                pollTimeoutMilliseconds: (shouldCancel == nil && modal == nil) ? nil : 100
            )
            let key: Key
            switch readResult {
            case let .key(value):
                key = value
            case .pickerEscape:
                key = .cancel
            case .timedOut:
                continue
            case .endOfInput:
                echo("\n")
                return nil
            }

            guard modal?.isCancelled != true else { return nil }
            switch key {
            case let .character(text):
                echo("\(text)\n")
                if let modal { return modal.accepted(text) }
                return text
            case let .paste(text):
                guard let firstCharacter = text.first else {
                    continue
                }
                let value = String(firstCharacter)
                echo("\(value)\n")
                if let modal { return modal.accepted(value) }
                return value
            case .enter:
                echo("\n")
                if let modal { return modal.accepted("") }
                return ""
            case .endOfInput:
                echo("\n")
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
        if TerminalPrimaryScreen.active != nil {
            return readCompositedLine(prompt: prompt, shouldCancel: shouldCancel)
        }
        // The fallback reader owns a private editor value: it runs only when
        // the panel cannot, and sharing the reducer here is what keeps a single
        // definition of motion, word edits and history for both paths.
        var editor = TerminalPromptEditor()
        let initialTerminalColumns = TerminalTextMetrics.terminalColumnCount(forceRefresh: true)
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
                let redraw = Self.redrawSequence(
                    prompt: prompt,
                    buffer: editor.buffer,
                    cursorIndex: editor.cursorIndex,
                    previousLineCount: renderedLineCount,
                    previousCursorRow: renderedCursorRow,
                    terminalColumns: TerminalTextMetrics.terminalColumnCount(forceRefresh: true)
                )
                AgentOutput.standardError.writeString(redraw.sequence)
                renderedLineCount = redraw.layout.lineCount
                renderedCursorRow = redraw.layout.cursorRow
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
                case .pickerEscape:
                    key = .cancel
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
