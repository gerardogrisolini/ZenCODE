//
//  TerminalPromptEditor+Reduction.swift
//  ZenCODE
//
//  Key reduction of the prompt editor: press-and-hold handling, the editing
//  primitives and the completion acceptance they share.
//

import Foundation

extension TerminalPromptEditor {
    // MARK: - Reduction

    /// Applies one semantic key and reports what the caller must do.
    ///
    /// Suggestion selection is reconciled after every key, so no other layer
    /// (least of all the renderer) has to repair an index that fell out of
    /// range when the match set changed.
    mutating func apply(
        _ key: Key,
        context: TerminalPromptEditorContext,
        timestampMilliseconds: UInt64? = nil,
        consumedPickerRepeat: Character? = nil
    ) -> TerminalPromptEditorEffect {
        let previous = self
        let effect: TerminalPromptEditorEffect
        if context.supportsPressAndHold,
           !context.isOverlayActive,
           let timestampMilliseconds {
            // Esc alone says nothing about current repeat activity. A compound
            // parser event does: refresh only the matching picker, at the time
            // that event was read, before cancellation creates suppression.
            if key == .cancel,
               let consumedPickerRepeat,
               pressAndHoldMenu?.base == consumedPickerRepeat {
                pressAndHoldMenu?.lastRepeatTimestampMilliseconds = timestampMilliseconds
            }
            effect = reducePressAndHold(
                key,
                context: context,
                timestampMilliseconds: timestampMilliseconds
            )
        } else {
            resetPressAndHold()
            effect = reduce(key, context: context)
        }
        reconcileSuggestionSelection(context: context)
        if effect == .ignored, !isObservablyEqual(to: previous) {
            return .changed
        }
        return effect
    }

    /// Clears state that is meaningful only while the live panel owns input.
    /// The return value says whether a visible picker was dismissed.
    @discardableResult
    mutating func resetPressAndHold() -> Bool {
        let dismissedMenu = pressAndHoldMenu != nil
        pressAndHoldCandidate = nil
        pressAndHoldMenu = nil
        pressAndHoldSuppression = nil
        return dismissedMenu
    }

    private func isObservablyEqual(to other: Self) -> Bool {
        let menusMatch: Bool
        switch (pressAndHoldMenu, other.pressAndHoldMenu) {
        case (nil, nil):
            menusMatch = true
        case let (.some(lhs), .some(rhs)):
            menusMatch = lhs.isVisuallyEqual(to: rhs)
        default:
            menusMatch = false
        }
        return buffer == other.buffer
            && cursorIndex == other.cursorIndex
            && preferredVisualColumn == other.preferredVisualColumn
            && historyIndex == other.historyIndex
            && draftBeforeHistory == other.draftBeforeHistory
            && suggestionIndex == other.suggestionIndex
            && areSuggestionsDismissed == other.areSuggestionsDismissed
            && menusMatch
    }

    private mutating func reducePressAndHold(
        _ key: Key,
        context: TerminalPromptEditorContext,
        timestampMilliseconds: UInt64
    ) -> TerminalPromptEditorEffect {
        if pressAndHoldMenu != nil {
            return reducePressAndHoldMenu(
                key,
                context: context,
                timestampMilliseconds: timestampMilliseconds
            )
        }

        if var suppression = pressAndHoldSuppression {
            if case let .character(text) = key,
               Array(text) == [suppression.base],
               timestampMilliseconds >= suppression.lastRepeatTimestampMilliseconds,
               timestampMilliseconds - suppression.lastRepeatTimestampMilliseconds
                   <= TerminalPressAndHold.residualRepeatWindowMilliseconds {
                suppression.lastRepeatTimestampMilliseconds = timestampMilliseconds
                pressAndHoldSuppression = suppression
                return .ignored
            }
            pressAndHoldSuppression = nil
        }

        if case let .character(text) = key {
            return reducePressAndHoldCharacter(
                text,
                timestampMilliseconds: timestampMilliseconds
            )
        }

        pressAndHoldCandidate = nil
        return reduce(key, context: context)
    }

    private mutating func reducePressAndHoldCharacter(
        _ text: String,
        timestampMilliseconds: UInt64
    ) -> TerminalPromptEditorEffect {
        let characters = Array(text)
        guard characters.count == 1,
              let base = characters.first,
              let variants = TerminalPressAndHold.variants(for: base) else {
            pressAndHoldCandidate = nil
            return insert(characters)
        }

        let insertionIndex = cursorIndex
        let effect = insert([base])
        guard var candidate = pressAndHoldCandidate,
              candidate.base == base,
              candidate.insertionIndex + candidate.insertedCount == insertionIndex,
              timestampMilliseconds >= candidate.lastTimestampMilliseconds,
              candidate.insertionIndex >= 0,
              candidate.insertionIndex + candidate.insertedCount <= buffer.count,
              buffer[candidate.insertionIndex..<(candidate.insertionIndex + candidate.insertedCount)]
                  .allSatisfy({ $0 == base }) else {
            pressAndHoldCandidate = TerminalPressAndHold.Candidate(
                base: base,
                insertionIndex: insertionIndex,
                timestampMilliseconds: timestampMilliseconds
            )
            return effect
        }

        let interval = timestampMilliseconds - candidate.lastTimestampMilliseconds
        candidate.insertedCount += 1
        candidate.lastTimestampMilliseconds = timestampMilliseconds

        if candidate.isRepeating {
            guard TerminalPressAndHold.repeatIntervalRange.contains(interval) else {
                pressAndHoldCandidate = TerminalPressAndHold.Candidate(
                    base: base,
                    insertionIndex: insertionIndex,
                    timestampMilliseconds: timestampMilliseconds
                )
                return effect
            }
            candidate.repeatIntervalCount += 1
        } else {
            guard TerminalPressAndHold.initialDelayRange.contains(interval) else {
                pressAndHoldCandidate = TerminalPressAndHold.Candidate(
                    base: base,
                    insertionIndex: insertionIndex,
                    timestampMilliseconds: timestampMilliseconds
                )
                return effect
            }
            candidate.isRepeating = true
        }

        let duration = timestampMilliseconds - candidate.firstTimestampMilliseconds
        guard candidate.repeatIntervalCount >= TerminalPressAndHold.minimumRepeatIntervalCount,
              duration >= TerminalPressAndHold.minimumHoldDurationMilliseconds,
              candidate.insertionIndex + candidate.insertedCount == cursorIndex,
              candidate.insertionIndex + candidate.insertedCount <= buffer.count,
              buffer[candidate.insertionIndex..<cursorIndex].allSatisfy({ $0 == base }) else {
            pressAndHoldCandidate = candidate
            return effect
        }

        buffer.replaceSubrange(
            candidate.insertionIndex..<cursorIndex,
            with: [base]
        )
        cursorIndex = candidate.insertionIndex + 1
        didEditBuffer()
        pressAndHoldCandidate = nil
        pressAndHoldMenu = TerminalPressAndHold.Menu(
            base: base,
            replacementIndex: candidate.insertionIndex,
            variants: variants,
            selectedIndex: 0,
            lastRepeatTimestampMilliseconds: timestampMilliseconds
        )
        return .changed
    }

    private mutating func reducePressAndHoldMenu(
        _ key: Key,
        context: TerminalPromptEditorContext,
        timestampMilliseconds: UInt64
    ) -> TerminalPromptEditorEffect {
        guard var menu = pressAndHoldMenu else {
            return reduce(key, context: context)
        }

        if case let .character(text) = key,
           Array(text) == [menu.base],
           timestampMilliseconds >= menu.lastRepeatTimestampMilliseconds,
           timestampMilliseconds - menu.lastRepeatTimestampMilliseconds
               <= TerminalPressAndHold.residualRepeatWindowMilliseconds {
            menu.lastRepeatTimestampMilliseconds = timestampMilliseconds
            pressAndHoldMenu = menu
            return .ignored
        }

        switch key {
        case let .character(text):
            if text.count == 1, let number = Int(text) {
                guard (1...menu.variants.count).contains(number) else {
                    return .ignored
                }
                menu.selectedIndex = number - 1
                return choosePressAndHoldVariant(menu)
            }
            pressAndHoldMenu = nil
            return reducePressAndHoldCharacter(
                text,
                timestampMilliseconds: timestampMilliseconds
            )
        case .enter:
            return choosePressAndHoldVariant(menu)
        case .left, .up:
            menu.selectedIndex = wrappedIndex(
                menu.selectedIndex - 1,
                count: menu.variants.count
            )
            pressAndHoldMenu = menu
            return .changed
        case .right, .down:
            menu.selectedIndex = wrappedIndex(
                menu.selectedIndex + 1,
                count: menu.variants.count
            )
            pressAndHoldMenu = menu
            return .changed
        case .cancel:
            pressAndHoldMenu = nil
            pressAndHoldSuppression = TerminalPressAndHold.Suppression(
                base: menu.base,
                lastRepeatTimestampMilliseconds: menu.lastRepeatTimestampMilliseconds
            )
            return .changed
        case .unknown, .pageUp, .pageDown:
            return .ignored
        default:
            pressAndHoldMenu = nil
            pressAndHoldCandidate = nil
            return reduce(key, context: context)
        }
    }

    private mutating func choosePressAndHoldVariant(
        _ menu: TerminalPressAndHold.Menu
    ) -> TerminalPromptEditorEffect {
        guard buffer.indices.contains(menu.replacementIndex),
              buffer[menu.replacementIndex] == menu.base else {
            resetPressAndHold()
            return .changed
        }
        buffer[menu.replacementIndex] = menu.selectedVariant
        didEditBuffer()
        pressAndHoldMenu = nil
        pressAndHoldCandidate = nil
        pressAndHoldSuppression = TerminalPressAndHold.Suppression(
            base: menu.base,
            lastRepeatTimestampMilliseconds: menu.lastRepeatTimestampMilliseconds
        )
        return .changed
    }

    private func wrappedIndex(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }

    private mutating func reduce(
        _ key: Key,
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        switch key {
        case let .character(text):
            return insert(Array(text))
        case let .paste(text):
            return insert(Array(text))
        case .newline:
            return insert(["\n"])
        case .enter:
            return submit(context: context)
        case .tab:
            guard context.supportsCompletions else {
                return .ignored
            }
            return acceptSuggestion(submitWhenComplete: false, context: context) ?? .ignored
        case .backspace:
            guard cursorIndex > 0 else {
                return .ignored
            }
            buffer.remove(at: cursorIndex - 1)
            cursorIndex -= 1
            didEditBuffer()
            return .changed
        case .delete:
            guard cursorIndex < buffer.count else {
                return .ignored
            }
            buffer.remove(at: cursorIndex)
            didEditBuffer()
            return .changed
        case .deleteWordBefore:
            let start = wordStartIndex(before: cursorIndex)
            guard start < cursorIndex else {
                return .ignored
            }
            buffer.removeSubrange(start..<cursorIndex)
            cursorIndex = start
            didEditBuffer()
            return .changed
        case .deleteWordAfter:
            let end = wordEndIndex(after: cursorIndex)
            guard end > cursorIndex else {
                return .ignored
            }
            buffer.removeSubrange(cursorIndex..<end)
            didEditBuffer()
            return .changed
        case .left:
            moveCursor(to: max(0, cursorIndex - 1))
            return .ignored
        case .right:
            moveCursor(to: min(buffer.count, cursorIndex + 1))
            return .ignored
        case .wordLeft:
            moveCursor(to: wordStartIndex(before: cursorIndex))
            return .ignored
        case .wordRight:
            moveCursor(to: wordEndIndex(after: cursorIndex))
            return .ignored
        case .home:
            moveCursor(to: lineRange(containing: cursorIndex).lowerBound)
            return .ignored
        case .end:
            moveCursor(to: lineRange(containing: cursorIndex).upperBound)
            return .ignored
        case .bufferStart:
            moveCursor(to: 0)
            return .ignored
        case .bufferEnd:
            moveCursor(to: buffer.count)
            return .ignored
        case .up:
            return moveVertically(delta: -1, context: context)
        case .down:
            return moveVertically(delta: 1, context: context)
        case .clearBeforeCursor:
            guard cursorIndex > 0 else {
                return .ignored
            }
            buffer.removeSubrange(0..<cursorIndex)
            cursorIndex = 0
            didEditBuffer()
            return .changed
        case .clearDraft:
            // Alt+Backspace discards the whole draft in one step; an empty
            // draft has nothing to clear.
            guard !buffer.isEmpty else {
                return .ignored
            }
            buffer.removeAll()
            cursorIndex = 0
            draftBeforeHistory.removeAll()
            didEditBuffer()
            return .changed
        case .clearAfterCursor:
            guard cursorIndex < buffer.count else {
                return .ignored
            }
            buffer.removeSubrange(cursorIndex..<buffer.count)
            didEditBuffer()
            return .changed
        case .toggleAccessMode:
            return .toggleAccessMode
        case .toggleSharedChatReader:
            return .toggleSharedChatReader
        case .cancel:
            return cancel(context: context)
        case .endOfInput:
            return buffer.isEmpty ? .endOfInput : .ignored
        case .pageUp, .pageDown:
            // The one-row draft has no pages; full-screen readers consume
            // these before they reach the editor.
            return .ignored
        case .unknown:
            return .ignored
        }
    }

    // MARK: - Editing primitives

    private mutating func insert(_ characters: [Character]) -> TerminalPromptEditorEffect {
        guard !characters.isEmpty else {
            return .ignored
        }
        buffer.insert(contentsOf: characters, at: cursorIndex)
        cursorIndex += characters.count
        didEditBuffer()
        return .changed
    }

    /// Replaces the draft from `start` to its end with `text` without a key:
    /// voice dictation shows the speech recognized so far at the end of the
    /// draft. Like a typed edit it ends history navigation and resets the
    /// derived navigation and press-and-hold state; a cursor past the new end
    /// is clamped to it.
    mutating func replaceTrailingText(from start: Int, with text: [Character]) {
        let boundedStart = min(max(0, start), buffer.count)
        buffer.replaceSubrange(boundedStart..<buffer.count, with: text)
        cursorIndex = min(max(0, cursorIndex), buffer.count)
        resetPressAndHold()
        didEditBuffer()
    }

    /// Any edit ends history navigation, invalidates the preferred column and
    /// brings a dismissed completion menu back for the new revision.
    private mutating func didEditBuffer() {
        preferredVisualColumn = nil
        historyIndex = nil
        // A new draft revision can produce a different ordered match list.
        // Always restart from its first suggestion rather than letting a
        // numeric position accidentally select a different command.
        suggestionIndex = 0
        areSuggestionsDismissed = false
    }

    private mutating func moveCursor(to index: Int) {
        let boundedIndex = min(max(0, index), buffer.count)
        if cursorIndex != boundedIndex {
            cursorIndex = boundedIndex
            // Completion is contextual to the token at the cursor. Moving it
            // therefore starts selection deterministically at the first match.
            suggestionIndex = 0
        }
        preferredVisualColumn = nil
    }

    private mutating func submit(
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        if context.supportsCompletions,
           let effect = acceptSuggestion(submitWhenComplete: true, context: context) {
            return effect
        }

        return submitCurrentBuffer()
    }

    private mutating func submitCurrentBuffer() -> TerminalPromptEditorEffect {
        let line = String(buffer)
        buffer.removeAll()
        cursorIndex = 0
        preferredVisualColumn = nil
        historyIndex = nil
        draftBeforeHistory.removeAll()
        suggestionIndex = 0
        areSuggestionsDismissed = false
        return .submitted(line)
    }

    private mutating func cancel(
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect {
        if context.isProcessing || context.isSpeaking {
            return .cancelRequested
        }
        // Hiding the menu is the least destructive reading of `Esc` while
        // completions are on screen, so it wins over clearing the draft.
        if !visibleSuggestions(context: context).isEmpty {
            areSuggestionsDismissed = true
            return .changed
        }
        guard context.clearsDraftOnCancel else {
            return .ignored
        }
        buffer.removeAll()
        cursorIndex = 0
        preferredVisualColumn = nil
        historyIndex = nil
        draftBeforeHistory.removeAll()
        suggestionIndex = 0
        areSuggestionsDismissed = false
        return .changed
    }

    // MARK: - Completions

    /// Replaces the token under the cursor with the selected completion.
    ///
    /// Returns `nil` when no menu is on screen or when the selected row is a
    /// guide (`isHint`), so the caller can fall through to the ordinary meaning
    /// of the key: Tab does nothing and Enter sends the line as typed. A guide
    /// is never inserted, and nothing is mutated before that check.
    private mutating func acceptSuggestion(
        submitWhenComplete: Bool,
        context: TerminalPromptEditorContext
    ) -> TerminalPromptEditorEffect? {
        let matches = visibleSuggestions(context: context)
        guard !matches.isEmpty,
              let completion = TerminalPromptCompletion.completion(
                  buffer: buffer,
                  cursorIndex: cursorIndex
              ) else {
            return nil
        }

        let boundedIndex = min(max(0, suggestionIndex), matches.count - 1)
        let suggestion = matches[boundedIndex]
        guard !suggestion.isHint else {
            return nil
        }
        let replacement = Array(completion.replacementText(for: suggestion))
        buffer.replaceSubrange(completion.replacementRange, with: replacement)
        cursorIndex = completion.replacementRange.lowerBound + replacement.count
        preferredVisualColumn = nil
        historyIndex = nil
        draftBeforeHistory.removeAll()
        suggestionIndex = 0
        areSuggestionsDismissed = false

        if suggestion.requiresArgument {
            if hasArgument(after: cursorIndex) {
                // A complete command with an existing operand must be sent as
                // typed.  In particular, do not move into or overwrite that
                // operand merely because the cursor was on its command token.
                return submitWhenComplete ? submitCurrentBuffer() : .changed
            }
            // The command is not syntactically complete yet: park the cursor
            // after a separator instead of sending an unusable line.
            if cursorIndex >= buffer.count || buffer[cursorIndex] != " " {
                buffer.insert(" ", at: cursorIndex)
            }
            cursorIndex += 1
            return .changed
        }

        guard submitWhenComplete else {
            return .changed
        }

        return submitCurrentBuffer()
    }

    /// An operand is valid here only when it follows the same literal-space
    /// grammar as the slash-command dispatcher.
    private func hasArgument(after index: Int) -> Bool {
        let start = min(max(0, index), buffer.count)
        guard start < buffer.count, buffer[start] == " " else {
            return false
        }
        return buffer[(start + 1)...].contains { $0 != " " }
    }

    private mutating func reconcileSuggestionSelection(
        context: TerminalPromptEditorContext
    ) {
        let matches = visibleSuggestions(context: context)
        guard !matches.isEmpty else {
            suggestionIndex = 0
            return
        }
        suggestionIndex = min(max(0, suggestionIndex), matches.count - 1)
    }
}
