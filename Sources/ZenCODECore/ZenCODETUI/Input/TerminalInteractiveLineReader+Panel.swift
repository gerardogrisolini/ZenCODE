//
//  TerminalInteractiveLineReader+Panel.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

extension TerminalInteractiveLineReader {
    @discardableResult
    public func startPanelInput(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion] = [],
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) -> Bool {
        panelLock.lock()
        if panelTask != nil {
            panelLock.unlock()
            return true
        }
        panelStatusBar = statusBar
        panelBuffer.removeAll()
        panelCursorIndex = 0
        panelOverlayOverride = nil
        panelCommandSuggestions = commandSuggestions
        panelCommandSuggestionIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()
        guard rawInput.beginRawMode() else {
            if let failureDescription = rawInput.lastRawModeFailureDescription() {
                AgentOutput.standardError.writeString(
                    "[ZenCODE] Interactive prompt raw input failed: \(failureDescription)\n"
                )
            }
            panelStatusBar = nil
            panelLock.unlock()
            return false
        }
        panelLock.unlock()

        renderPanel()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            self.runPanelInputLoop(statusBar: statusBar, onEvent: onEvent)
        }

        panelLock.lock()
        panelTask = task
        panelLock.unlock()
        return true
    }

    public func stopPanelInput(clearPanel: Bool = true) async {
        let stopState = takePanelTaskForStop()

        stopState.task?.cancel()
        await stopState.task?.value
        rawInput.restoreRawMode()
        if clearPanel {
            stopState.statusBar?.clearInputPanel()
        }
        finishPanelStop(clearPanel: clearPanel)
    }

    func takePanelTaskForStop() -> (
        task: Task<Void, Never>?,
        statusBar: TerminalStatusBar?
    ) {
        panelLock.lock()
        defer { panelLock.unlock() }

        let state = (task: panelTask, statusBar: panelStatusBar)
        panelTask = nil
        return state
    }

    func finishPanelStop(clearPanel: Bool) {
        panelLock.lock()
        defer { panelLock.unlock() }

        if clearPanel {
            panelStatusBar = nil
            panelBuffer.removeAll()
            panelCursorIndex = 0
            panelOverlayOverride = nil
            panelCommandSuggestions.removeAll()
            panelCommandSuggestionIndex = 0
        }
        historyIndex = nil
        draftBeforeHistory.removeAll()
    }

    public func setPanelProcessing(_ isProcessing: Bool) {
        panelLock.lock()
        panelIsProcessing = isProcessing
        panelLock.unlock()
        renderPanel()
    }

    public func setPanelCommandSuggestions(_ suggestions: [TerminalCommandSuggestion]) {
        panelLock.lock()
        panelCommandSuggestions = suggestions
        panelCommandSuggestionIndex = 0
        panelLock.unlock()
        renderPanel()
    }

    public func setQueuedPromptCount(_ count: Int) {
        panelLock.lock()
        panelQueuedPromptCount = max(0, count)
        panelLock.unlock()
        renderPanel()
    }

    public func setPanelModeOverride(_ override: TerminalPanelModeOverride?) {
        setPanelOverlay(override)
    }

    public func setPanelOverlay(
        _ override: TerminalPanelModeOverride?,
        isProcessing: Bool? = nil
    ) {
        panelLock.lock()
        panelOverlayOverride = override
        if let isProcessing {
            panelIsProcessing = isProcessing
        }
        panelCommandSuggestionIndex = 0
        panelLock.unlock()
        renderPanel()
    }

    public func setPanelText(_ text: String, cursorIndex: Int? = nil) {
        panelLock.lock()
        panelBuffer = Array(text)
        panelCursorIndex = min(max(0, cursorIndex ?? panelBuffer.count), panelBuffer.count)
        panelCommandSuggestionIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()
        panelLock.unlock()
        renderPanel()
    }

    public func refreshPanel() {
        renderPanel()
    }

    func runPanelInputLoop(
        statusBar _: TerminalStatusBar,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) {
        while !Task.isCancelled {
            guard let key = readKey(pollTimeoutMilliseconds: 100) else {
                continue
            }
            handlePanelKey(key, onEvent: onEvent)
        }
    }

    func handlePanelKey(
        _ key: Key,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) {
        switch key {
        case let .character(text), let .paste(text):
            let characters = Array(text)
            guard !characters.isEmpty else {
                return
            }
            panelLock.lock()
            panelBuffer.insert(contentsOf: characters, at: panelCursorIndex)
            panelCursorIndex += characters.count
            historyIndex = nil
            panelLock.unlock()
            renderPanel()
        case .enter:
            panelLock.lock()
            if let submission = acceptPanelCommandSuggestionLocked(
                submitCommandWithoutArguments: true
            ) {
                panelLock.unlock()
                if let submittedLine = submission.submittedLine {
                    recordHistory(submittedLine)
                    onEvent(.submitted(submittedLine))
                }
                renderPanel()
                return
            }

            let line = String(panelBuffer)
            panelBuffer.removeAll()
            panelCursorIndex = 0
            historyIndex = nil
            draftBeforeHistory.removeAll()
            panelLock.unlock()

            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordHistory(line)
            }
            onEvent(.submitted(line))
            renderPanel()
        case .tab:
            panelLock.lock()
            let accepted = acceptPanelCommandSuggestionLocked(
                submitCommandWithoutArguments: false
            ) != nil
            panelLock.unlock()
            if accepted {
                renderPanel()
            }
        case .newline:
            panelLock.lock()
            panelBuffer.insert("\n", at: panelCursorIndex)
            panelCursorIndex += 1
            panelCommandSuggestionIndex = 0
            historyIndex = nil
            panelLock.unlock()
            renderPanel()
        case .backspace:
            panelLock.lock()
            guard panelCursorIndex > 0 else {
                panelLock.unlock()
                return
            }
            panelBuffer.remove(at: panelCursorIndex - 1)
            panelCursorIndex -= 1
            panelLock.unlock()
            renderPanel()
        case .delete:
            panelLock.lock()
            guard panelCursorIndex < panelBuffer.count else {
                panelLock.unlock()
                return
            }
            panelBuffer.remove(at: panelCursorIndex)
            panelLock.unlock()
            renderPanel()
        case .left:
            panelLock.lock()
            if panelCursorIndex > 0 {
                panelCursorIndex -= 1
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .right:
            panelLock.lock()
            if panelCursorIndex < panelBuffer.count {
                panelCursorIndex += 1
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .up:
            panelLock.lock()
            if hasActiveCommandSuggestionsLocked() {
                movePanelCommandSuggestionSelectionLocked(delta: -1)
            } else if let previous = previousHistory(currentBuffer: panelBuffer) {
                panelBuffer = previous
                panelCursorIndex = panelBuffer.count
            }
            panelLock.unlock()
            renderPanel()
        case .down:
            panelLock.lock()
            if hasActiveCommandSuggestionsLocked() {
                movePanelCommandSuggestionSelectionLocked(delta: 1)
            } else if let next = nextHistory() {
                panelBuffer = next
                panelCursorIndex = panelBuffer.count
            }
            panelLock.unlock()
            renderPanel()
        case .home:
            panelLock.lock()
            panelCursorIndex = 0
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .end:
            panelLock.lock()
            panelCursorIndex = panelBuffer.count
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .clearBeforeCursor:
            panelLock.lock()
            if panelCursorIndex > 0 {
                panelBuffer.removeSubrange(0..<panelCursorIndex)
                panelCursorIndex = 0
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .clearAfterCursor:
            panelLock.lock()
            if panelCursorIndex < panelBuffer.count {
                panelBuffer.removeSubrange(panelCursorIndex..<panelBuffer.count)
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .toggleToolDetails:
            onEvent(.toggleToolDetailsRequested)
            renderPanel()
        case .cancel:
            panelLock.lock()
            let isProcessing = panelIsProcessing
            if !isProcessing {
                panelBuffer.removeAll()
                panelCursorIndex = 0
                panelCommandSuggestionIndex = 0
                historyIndex = nil
                draftBeforeHistory.removeAll()
            }
            panelLock.unlock()
            if isProcessing {
                onEvent(.cancelRequested)
            }
            renderPanel()
        case .endOfInput:
            panelLock.lock()
            let isEmpty = panelBuffer.isEmpty
            panelLock.unlock()
            if isEmpty {
                onEvent(.endOfInput)
            }
        case .unknown:
            return
        }
    }

    func renderPanel() {
        panelLock.lock()
        let statusBar = panelStatusBar
        let text = String(panelBuffer)
        let cursorIndex = panelCursorIndex
        let modeText = panelModeTextLocked()
        let helpText = panelHelpTextLocked()
        let suggestionLines = panelCommandSuggestionLinesLocked()
        panelLock.unlock()

        statusBar?.updateInputPanel(
            text: text,
            cursorIndex: cursorIndex,
            modeText: modeText,
            helpText: helpText,
            suggestionLines: suggestionLines
        )
    }

    func panelModeTextLocked() -> String {
        if let modeText = panelOverlayOverride?.modeText {
            return modeText
        }

        var modeText = panelIsProcessing ? "Next prompt" : "Prompt"
        if panelQueuedPromptCount > 0 {
            modeText += " · queued \(panelQueuedPromptCount)"
        }
        return modeText
    }

    func panelHelpTextLocked() -> String {
        if let helpText = panelOverlayOverride?.helpText {
            return helpText
        }

        if hasActiveCommandSuggestionsLocked() {
            return "↑/↓ select · Tab complete · Enter choose"
        }
        return "Enter queue · Option+Enter newline · Ctrl+T tools · Esc stop"
    }

    struct CommandSuggestionSelection {
        let submittedLine: String?
    }

    func acceptPanelCommandSuggestionLocked(
        submitCommandWithoutArguments: Bool
    ) -> CommandSuggestionSelection? {
        guard let selectedSuggestion = selectedPanelCommandSuggestionLocked() else {
            return nil
        }

        let replacement = selectedSuggestion.requiresArgument
            ? "\(selectedSuggestion.command) "
            : selectedSuggestion.command
        panelBuffer = Array(replacement)
        panelCursorIndex = panelBuffer.count
        panelCommandSuggestionIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()

        guard submitCommandWithoutArguments,
              !selectedSuggestion.requiresArgument else {
            return CommandSuggestionSelection(submittedLine: nil)
        }

        let submittedLine = String(panelBuffer)
        panelBuffer.removeAll()
        panelCursorIndex = 0
        return CommandSuggestionSelection(submittedLine: submittedLine)
    }

    func selectedPanelCommandSuggestionLocked() -> TerminalCommandSuggestion? {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            return nil
        }
        panelCommandSuggestionIndex = min(
            max(0, panelCommandSuggestionIndex),
            suggestions.count - 1
        )
        return suggestions[panelCommandSuggestionIndex]
    }

    func hasActiveCommandSuggestionsLocked() -> Bool {
        !activeCommandSuggestionsLocked().isEmpty
    }

    func movePanelCommandSuggestionSelectionLocked(delta: Int) {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            panelCommandSuggestionIndex = 0
            return
        }
        let count = suggestions.count
        panelCommandSuggestionIndex = (panelCommandSuggestionIndex + delta + count) % count
    }

    func panelCommandSuggestionLinesLocked() -> [String] {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            panelCommandSuggestionIndex = 0
            return []
        }

        panelCommandSuggestionIndex = min(
            max(0, panelCommandSuggestionIndex),
            suggestions.count - 1
        )

        let visibleSuggestions = Self.visiblePanelCommandSuggestionWindow(
            suggestions: suggestions,
            selectedIndex: panelCommandSuggestionIndex,
            maximumLineCount: Self.maximumPanelCommandSuggestionLines
        )
        return visibleSuggestions.map { item in
            let marker = item.index == panelCommandSuggestionIndex ? "›" : " "
            return "\(marker) \(item.suggestion.command)  \(item.suggestion.summary)"
        }
    }

    static func visiblePanelCommandSuggestionWindow(
        suggestions: [TerminalCommandSuggestion],
        selectedIndex: Int,
        maximumLineCount: Int = maximumPanelCommandSuggestionLines
    ) -> [(index: Int, suggestion: TerminalCommandSuggestion)] {
        guard !suggestions.isEmpty, maximumLineCount > 0 else {
            return []
        }

        let boundedSelectedIndex = min(
            max(0, selectedIndex),
            suggestions.count - 1
        )
        let visibleCount = min(maximumLineCount, suggestions.count)
        let minimumStart = max(0, boundedSelectedIndex - visibleCount + 1)
        let maximumStart = max(0, suggestions.count - visibleCount)
        let start = min(minimumStart, maximumStart)
        let end = min(start + visibleCount, suggestions.count)
        return suggestions[start..<end].enumerated().map { offset, suggestion in
            (index: start + offset, suggestion: suggestion)
        }
    }

    static func matchingPanelCommandSuggestions(
        text: String,
        cursorIndex: Int,
        suggestions: [TerminalCommandSuggestion]
    ) -> [TerminalCommandSuggestion] {
        guard let commandPrefix = commandPrefixForSuggestions(
            text: text,
            cursorIndex: cursorIndex
        ) else {
            return []
        }

        let normalizedPrefix = commandPrefix.lowercased()
        let matches = suggestions.filter { suggestion in
            suggestion.command.lowercased().hasPrefix(normalizedPrefix)
        }
        let exactMatches = matches.filter { suggestion in
            suggestion.command.lowercased() == normalizedPrefix
        }
        guard !exactMatches.isEmpty else {
            return matches
        }
        return exactMatches + matches.filter { suggestion in
            suggestion.command.lowercased() != normalizedPrefix
        }
    }

    func activeCommandSuggestionsLocked() -> [TerminalCommandSuggestion] {
        guard panelOverlayOverride == nil else {
            return []
        }

        return Self.matchingPanelCommandSuggestions(
            text: String(panelBuffer),
            cursorIndex: panelCursorIndex,
            suggestions: panelCommandSuggestions
        )
    }

    static func commandPrefixForSuggestions(
        text: String,
        cursorIndex: Int
    ) -> String? {
        guard text.hasPrefix("/"), !text.contains("\n") else {
            return nil
        }

        let characters = Array(text)
        let boundedCursorIndex = min(max(0, cursorIndex), characters.count)
        let tokenEnd = characters.firstIndex { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
        } ?? characters.count
        guard boundedCursorIndex <= tokenEnd else {
            return nil
        }

        let prefix = String(characters.prefix(tokenEnd))
        return prefix.isEmpty ? nil : prefix
    }

}
