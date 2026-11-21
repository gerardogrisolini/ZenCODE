//
//  TerminalPromptEditor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ZenCODERuntime

/// Effect a key produced on the draft, reported to the owner of the terminal.
///
/// The reducer never writes to the terminal itself; it only says what the
/// caller has to do next. `changed` means "re-render", everything else is an
/// application-level event the panel forwards to its consumer.
enum TerminalPromptEditorEffect: Equatable, Sendable {
    /// Nothing observable happened; the caller may skip the redraw.
    case ignored
    /// The draft, cursor, selection or search state moved.
    case changed
    /// The line is complete and must be recorded and dispatched.
    case submitted(String)
    /// `Esc` while a generation is running.
    case cancelRequested
    /// `Ctrl+D` on an empty draft.
    case endOfInput
    case toggleAccessMode
    case toggleSharedChatReader
}

/// Everything the reducer needs to know about the world without reaching for
/// it. Passing this in keeps the editor free of locks, actors and I/O.
struct TerminalPromptEditorContext: Sendable {
    /// Oldest-first history entries.
    var history: [String] = []
    /// Slash-command catalogue currently visible for the selected agent.
    var suggestions: [TerminalCommandSuggestion] = []
    /// An application overlay (voice recording, …) owns the prompt line.
    var isOverlayActive = false
    /// A generation is running, so `Esc` means "stop" rather than "clear".
    var isProcessing = false
    /// Voice mode is reading an answer aloud, so `Esc` stops the reading
    /// rather than clearing the draft.
    var isSpeaking = false
    /// The fallback reader has no completion menu, so it must not consume
    /// `Tab` or change `Enter` semantics.
    var supportsCompletions = true
    /// The panel clears the draft on `Esc`; the blocking reader keeps it.
    var clearsDraftOnCancel = true
    /// A live terminal panel can use the conservative repeat heuristic.
    /// Disabled by default so fallback readers retain their previous semantics.
    var supportsPressAndHold = false

    init(
        history: [String] = [],
        suggestions: [TerminalCommandSuggestion] = [],
        isOverlayActive: Bool = false,
        isProcessing: Bool = false,
        isSpeaking: Bool = false,
        supportsCompletions: Bool = true,
        clearsDraftOnCancel: Bool = true,
        supportsPressAndHold: Bool = false
    ) {
        self.history = history
        self.suggestions = suggestions
        self.isOverlayActive = isOverlayActive
        self.isProcessing = isProcessing
        self.isSpeaking = isSpeaking
        self.supportsCompletions = supportsCompletions
        self.clearsDraftOnCancel = clearsDraftOnCancel
        self.supportsPressAndHold = supportsPressAndHold
    }
}

/// Pure, I/O-free semantics of the interactive prompt editor.
///
/// Everything that decides *what* the draft looks like after a key lives here:
/// insertion, deletion, word and line motion, multi-line navigation, history
/// recall, and completion acceptance. The reducer never
/// touches a file descriptor, termios, a mutex or the renderer, so the whole
/// behaviour is unit-testable without a TTY and the live panel and the fallback
/// line reader share one implementation instead of drifting apart.
///
/// Indices are `Character` (grapheme) offsets into ``buffer``, never UTF-8
/// offsets, because that is the unit the renderer and the cursor arithmetic
/// already use.
struct TerminalPromptEditor: Equatable, Sendable {
    typealias Key = TerminalInteractiveLineReader.Key

    var buffer: [Character] = []
    var cursorIndex = 0
    /// Cell column a vertical move tries to return to.
    ///
    /// Moving through a short line must not truncate the cursor permanently, so
    /// the column is remembered on the first vertical move and only cleared by
    /// keys that express a new horizontal intent.
    var preferredVisualColumn: Int?
    var historyIndex: Int?
    var draftBeforeHistory: [Character] = []
    var suggestionIndex = 0
    /// `Esc` hides the completion menu for the current draft revision without
    /// destroying the draft; any edit brings it back.
    var areSuggestionsDismissed = false
    var pressAndHoldCandidate: TerminalPressAndHold.Candidate?
    var pressAndHoldMenu: TerminalPressAndHold.Menu?
    var pressAndHoldSuppression: TerminalPressAndHold.Suppression?

    init() {}

    // MARK: - Vertical motion and history

    mutating func moveVertically(
        delta: Int,
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        if !visibleSuggestions(context: context).isEmpty {
            moveSuggestionSelection(delta: delta, context: context)
            return .changed
        }

        // A recalled entry may itself be multi-line; while navigation is active
        // the arrows keep walking the history rather than its content.
        if historyIndex == nil, moveWithinBuffer(delta: delta) {
            return .changed
        }

        return delta < 0
            ? recallPreviousHistory(context: context)
            : recallNextHistory(context: context)
    }

    /// Moves between logical lines, honouring the preferred visual column.
    /// Returns `false` when there is no destination line, so the caller can
    /// fall through to history navigation at the buffer edges.
    private mutating func moveWithinBuffer(delta: Int) -> Bool {
        let currentLine = lineRange(containing: cursorIndex)
        let targetRange: Range<Int>
        if delta < 0 {
            guard currentLine.lowerBound > 0 else {
                return false
            }
            targetRange = lineRange(containing: currentLine.lowerBound - 1)
        } else {
            guard currentLine.upperBound < buffer.count else {
                return false
            }
            targetRange = lineRange(containing: currentLine.upperBound + 1)
        }

        let column = preferredVisualColumn ?? visualColumn(of: cursorIndex)
        preferredVisualColumn = column
        cursorIndex = index(inLine: targetRange, forVisualColumn: column)
        return true
    }

    private mutating func recallPreviousHistory(
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        guard !context.history.isEmpty else {
            return .ignored
        }

        let targetIndex: Int
        if let index = historyIndex {
            targetIndex = max(0, index - 1)
        } else {
            draftBeforeHistory = buffer
            targetIndex = context.history.count - 1
        }
        historyIndex = targetIndex
        buffer = Array(context.history[targetIndex])
        cursorIndex = buffer.count
        preferredVisualColumn = nil
        areSuggestionsDismissed = false
        return .changed
    }

    private mutating func recallNextHistory(
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        guard let index = historyIndex else {
            return .ignored
        }

        let nextIndex = index + 1
        if nextIndex < context.history.count {
            historyIndex = nextIndex
            buffer = Array(context.history[nextIndex])
        } else {
            historyIndex = nil
            buffer = draftBeforeHistory
        }
        cursorIndex = buffer.count
        preferredVisualColumn = nil
        areSuggestionsDismissed = false
        return .changed
    }

    // MARK: - Completions

    /// Completion matches that are currently on screen.
    ///
    /// Empty during history recall, while an overlay owns the line, or after
    /// `Esc` dismissed the menu for this revision. Editing a recalled entry
    /// clears `historyIndex` and restores ordinary completion semantics.
    func visibleSuggestions(
        context: TerminalPromptEditorContext
    ) -> [TerminalCommandSuggestion] {
        guard historyIndex == nil,
              pressAndHoldMenu == nil,
              !context.isOverlayActive,
              !areSuggestionsDismissed,
              context.supportsCompletions else {
            return []
        }
        return TerminalPromptCompletion.matches(
            buffer: buffer,
            cursorIndex: cursorIndex,
            commands: context.suggestions
        )
    }

    mutating func moveSuggestionSelection(
        delta: Int,
        context: TerminalPromptEditorContext
    ) {
        let matches = visibleSuggestions(context: context)
        guard !matches.isEmpty else {
            suggestionIndex = 0
            return
        }
        let count = matches.count
        suggestionIndex = ((suggestionIndex + delta) % count + count) % count
    }

    // MARK: - Geometry

    var logicalLineCount: Int {
        buffer.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    var cursorLineIndex: Int {
        let bounded = min(max(0, cursorIndex), buffer.count)
        return buffer[..<bounded].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Bounds of the logical (newline-delimited) line containing `index`.
    /// Soft wraps are deliberately not lines: they depend on the terminal
    /// width, so navigating by them would change meaning when the window is
    /// resized.
    func lineRange(containing index: Int) -> Range<Int> {
        let bounded = min(max(0, index), buffer.count)
        let start = buffer[..<bounded].lastIndex(of: "\n").map { $0 + 1 } ?? 0
        let end = buffer[bounded...].firstIndex(of: "\n") ?? buffer.count
        return start..<end
    }

    /// Column of `index` measured in terminal cells, matching the renderer's
    /// width rules including its fixed eight-cell tab stops.
    func visualColumn(of index: Int) -> Int {
        let bounded = min(max(0, index), buffer.count)
        let range = lineRange(containing: bounded)
        var column = 0
        for character in buffer[range.lowerBound..<bounded] {
            column = Self.advance(column: column, by: character)
        }
        return column
    }

    /// Closest index in `range` whose column does not exceed `column`, never
    /// landing inside a wide grapheme.
    func index(inLine range: Range<Int>, forVisualColumn column: Int) -> Int {
        var current = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let next = Self.advance(column: current, by: buffer[index])
            if next > column {
                return index
            }
            current = next
            index += 1
        }
        return range.upperBound
    }

    private static func advance(column: Int, by character: Character) -> Int {
        guard character != "\t" else {
            let tabStop = TerminalInteractiveLineReader.renderTabStopWidth
            return column + (tabStop - column % tabStop)
        }
        return column + max(0, TerminalANSIText.visibleWidth(of: character))
    }

    // MARK: - Word boundaries

    /// Deterministic, locale-independent word classes. Foundation's
    /// linguistic tokenizers depend on ICU data and would make `Alt+←`
    /// behave differently on macOS and Linux.
    enum CharacterClass: Equatable, Sendable {
        case whitespace
        case word
        case symbol
    }

    static func characterClass(of character: Character) -> CharacterClass {
        if character.isWhitespace || character.isNewline {
            return .whitespace
        }
        if character.isLetter || character.isNumber || character == "_" {
            return .word
        }
        return .symbol
    }

    func wordStartIndex(before index: Int) -> Int {
        var current = min(max(0, index), buffer.count)
        while current > 0, Self.characterClass(of: buffer[current - 1]) == .whitespace {
            current -= 1
        }
        guard current > 0 else {
            return current
        }
        let characterClass = Self.characterClass(of: buffer[current - 1])
        while current > 0, Self.characterClass(of: buffer[current - 1]) == characterClass {
            current -= 1
        }
        return current
    }

    func wordEndIndex(after index: Int) -> Int {
        var current = min(max(0, index), buffer.count)
        while current < buffer.count, Self.characterClass(of: buffer[current]) == .whitespace {
            current += 1
        }
        guard current < buffer.count else {
            return current
        }
        let characterClass = Self.characterClass(of: buffer[current])
        while current < buffer.count, Self.characterClass(of: buffer[current]) == characterClass {
            current += 1
        }
        return current
    }
}
