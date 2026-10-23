import Foundation

extension TerminalInteractiveLineReader {
    /// Enqueues a redraw without making the caller wait for terminal I/O.
    ///
    /// The input task calls this after reducing every visual change. If the
    /// status bar is busy repainting the transcript, a newer edit replaces the
    /// one pending frame rather than creating an unbounded redraw backlog.
    @discardableResult
    func requestPanelRender() -> UInt64 {
        let request = withPanelLock { state -> (revision: UInt64, shouldStart: Bool) in
            state.panelRenderRevision &+= 1
            let revision = state.panelRenderRevision
            let suggestionProjection = panelSuggestionProjectionLocked(state: state)
            state.pendingPanelRender = PanelRenderSnapshot(
                statusBar: state.panelStatusBar,
                text: String(state.panelBuffer),
                cursorIndex: state.panelCursorIndex,
                modeText: panelModeTextLocked(state: state),
                helpText: panelHelpTextLocked(state: state),
                compactHelpText: panelCompactHelpTextLocked(state: state),
                prioritizesModeText: state.panelOverlayOverride == nil && state.editor.pressAndHoldMenu != nil,
                suggestionLines: suggestionProjection.lines,
                suggestionSelectedIndex: suggestionProjection.selectedIndex,
                revision: revision
            )
            guard !state.isPanelRenderInFlight else {
                return (revision, false)
            }
            state.isPanelRenderInFlight = true
            return (revision, true)
        }

        guard request.shouldStart else {
            return request.revision
        }
        Task(name: "ZenCODE.TUI.panel-render") { [weak self] in
            guard let self else {
                return
            }
            await self.drainPanelRenders()
        }
        return request.revision
    }

    /// Preserves the completion boundary used by panel start and explicit
    /// refresh calls. Live key handling deliberately uses
    /// ``requestPanelRender()`` instead.
    func renderPanel() async {
        let revision = requestPanelRender()
        await awaitPanelRender(revision: revision)
    }

    private func drainPanelRenders() async {
        while let snapshot = takeNextPanelRenderSnapshot() {
            let beforeUpdate = withPanelLock { state in
                state.panelRenderBeforeUpdateForTesting
            }
            await beforeUpdate?()
            await snapshot.statusBar?.updateInputPanel(
                text: snapshot.text,
                cursorIndex: snapshot.cursorIndex,
                modeText: snapshot.modeText,
                helpText: snapshot.helpText,
                compactHelpText: snapshot.compactHelpText,
                prioritizesModeText: snapshot.prioritizesModeText,
                suggestionLines: snapshot.suggestionLines,
                suggestionSelectedIndex: snapshot.suggestionSelectedIndex,
                revision: snapshot.revision
            )
            completePanelRender(revision: snapshot.revision)
        }
    }

    /// Removes one immutable frame. Clearing the in-flight flag in the same
    /// critical section that observes an empty queue prevents a producer from
    /// leaving a frame stranded between the check and task completion.
    private func takeNextPanelRenderSnapshot() -> PanelRenderSnapshot? {
        let result = withPanelLock { state -> (
            snapshot: PanelRenderSnapshot?,
            waiters: [CheckedContinuation<Void, Never>]
        ) in
            if let snapshot = state.pendingPanelRender {
                state.pendingPanelRender = nil
                return (snapshot, [])
            }
            state.isPanelRenderInFlight = false
            let waiters = state.panelRenderDrainWaiters
            state.panelRenderDrainWaiters.removeAll()
            return (nil, waiters)
        }
        result.waiters.forEach { $0.resume() }
        return result.snapshot
    }

    /// Marks a snapshot applied and releases only the explicit refreshes that it
    /// satisfies. A coalesced newer snapshot deliberately completes waiters for
    /// every older revision it replaced.
    private func completePanelRender(revision: UInt64) {
        let waiters = withPanelLock { state -> [CheckedContinuation<Void, Never>] in
            state.completedPanelRenderRevision = max(state.completedPanelRenderRevision, revision)
            var remaining: [PanelRenderWaiter] = []
            var completed: [CheckedContinuation<Void, Never>] = []
            for waiter in state.panelRenderWaiters {
                if waiter.revision <= state.completedPanelRenderRevision {
                    completed.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            state.panelRenderWaiters = remaining
            return completed
        }
        waiters.forEach { $0.resume() }
    }

    /// Waits until this refresh's revision has been applied or superseded. Newer
    /// input may keep the renderer busy without delaying this caller.
    private func awaitPanelRender(revision: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isComplete = withPanelLock { state -> Bool in
                guard state.completedPanelRenderRevision < revision else {
                    return true
                }
                state.panelRenderWaiters.append(PanelRenderWaiter(revision: revision, continuation: continuation))
                return false
            }
            if isComplete {
                continuation.resume()
            }
        }
    }

    /// Lifecycle-only join for the single renderer task. Unlike explicit refresh
    /// barriers, stop must know no detached terminal write can occur afterward.
    func awaitPanelRenderDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isDrained = withPanelLock { state -> Bool in
                guard state.isPanelRenderInFlight || state.pendingPanelRender != nil else {
                    return true
                }
                state.panelRenderDrainWaiters.append(continuation)
                return false
            }
            if isDrained {
                continuation.resume()
            }
        }
    }

    /// Compact, single-line status of the draft.
    ///
    /// The panel is one row tall, so state the operator cannot otherwise see —
    /// which line of a multi-line draft the cursor is on, staged attachments,
    /// queued prompts — is summarised here rather than spent on extra rows.
    func panelModeTextLocked(state: State) -> String {
        if let modeText = state.panelOverlayOverride?.modeText {
            return modeText
        }
        if let menu = state.editor.pressAndHoldMenu {
            return "Accent \(menu.base) \(menu.selectedIndex + 1)/\(menu.variants.count) \(menu.selectedVariant)"
        }
        var modeText = state.panelIsProcessing ? "Next prompt" : "Prompt"
        let lineCount = state.editor.logicalLineCount
        if lineCount > 1 {
            modeText += " · ln \(state.editor.cursorLineIndex + 1)/\(lineCount)"
        }
        if state.panelPendingAttachmentCount > 0 {
            modeText += " · attach \(state.panelPendingAttachmentCount)"
        }
        if state.panelQueuedPromptCount > 0 {
            modeText += " · queued \(state.panelQueuedPromptCount)"
        }
        return modeText
    }

    /// Help for the mode the prompt is actually in, so a key it lists is a key
    /// that currently does something.
    func panelHelpTextLocked(state: State) -> String {
        if let helpText = state.panelOverlayOverride?.helpText {
            return helpText
        }
        if state.editor.pressAndHoldMenu != nil {
            return "1–8 choose · ←/→ ↑/↓ select · Enter choose · Esc dismiss"
        }

        if state.panelIsProcessing {
            if hasActiveCommandSuggestionsLocked(state: state) {
                return "↑/↓ select · Tab complete · Enter choose · Esc stop"
            }
            return "Enter queue · Ctrl+G access · Ctrl+Y chat · Esc stop"
        }
        if state.panelIsSpeaking {
            if hasActiveCommandSuggestionsLocked(state: state) {
                return "↑/↓ select · Tab complete · Enter choose · Esc stop reading"
            }
            return "Enter send · Ctrl+G access · Ctrl+Y chat · Esc stop reading"
        }
        if hasActiveCommandSuggestionsLocked(state: state) {
            return "↑/↓ select · Tab complete · Enter choose · Esc dismiss"
        }
        return "Enter send · Ctrl+G access · Ctrl+Y chat · Esc clear"
    }

    func panelCompactHelpTextLocked(state: State) -> String? {
        guard state.panelOverlayOverride == nil else {
            return nil
        }
        if state.editor.pressAndHoldMenu != nil {
            return "1–8 choose · arrows select · Enter choose · Esc dismiss"
        }
        guard !hasActiveCommandSuggestionsLocked(state: state) else {
            return nil
        }
        if state.panelIsProcessing {
            return "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat"
        }
        if state.panelIsSpeaking {
            return "Enter send · Esc stop reading · Ctrl+G access · Ctrl+Y chat"
        }
        return "Enter send · Esc clear · Ctrl+G access · Ctrl+Y chat"
    }

    func hasActiveCommandSuggestionsLocked(state: State) -> Bool {
        !activeCommandSuggestionsLocked(state: state).isEmpty
    }

    /// Accent choices precede command completions and carry their selected row
    /// into the status bar so a height-constrained render can keep it visible.
    func panelSuggestionProjectionLocked(
        state: State
    ) -> (lines: [String], selectedIndex: Int?) {
        if let menu = state.editor.pressAndHoldMenu {
            return (
                lines: menu.variants.enumerated().map { index, variant in
                    let marker = index == menu.selectedIndex ? "›" : " "
                    return "\(marker) \(index + 1) \(variant)"
                },
                selectedIndex: menu.selectedIndex
            )
        }
        return (lines: panelCommandSuggestionLinesLocked(state: state), selectedIndex: nil)
    }

    /// Pure projection of the menu.
    ///
    /// Rendering must not repair the selection: the reducer already reconciled
    /// it after the key that changed the match set, and a second, hidden
    /// mutation here would make the visible state depend on how often the panel
    /// happened to redraw.
    func panelCommandSuggestionLinesLocked(state: State) -> [String] {
        let suggestions = activeCommandSuggestionsLocked(state: state)
        guard !suggestions.isEmpty else {
            return []
        }

        let selectedIndex = min(max(0, state.panelCommandSuggestionIndex), suggestions.count - 1)
        let visibleSuggestions = Self.visiblePanelCommandSuggestionWindow(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            maximumLineCount: Self.maximumPanelCommandSuggestionLines
        )
        return visibleSuggestions.map { item in
            let marker = item.index == selectedIndex ? "›" : " "
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

        let boundedSelectedIndex = min(max(0, selectedIndex), suggestions.count - 1)
        let visibleCount = min(maximumLineCount, suggestions.count)
        let minimumStart = max(0, boundedSelectedIndex - visibleCount + 1)
        let maximumStart = max(0, suggestions.count - visibleCount)
        let start = min(minimumStart, maximumStart)
        let end = min(start + visibleCount, suggestions.count)
        return suggestions[start..<end].enumerated().map { offset, suggestion in
            (index: start + offset, suggestion: suggestion)
        }
    }

    /// Completion matches for the token under the cursor.
    ///
    /// Kept as the shared entry point for both the command token and the
    /// subcommand slot, so callers never have to know which one is being
    /// completed.
    static func matchingPanelCommandSuggestions(
        text: String,
        cursorIndex: Int,
        suggestions: [TerminalCommandSuggestion]
    ) -> [TerminalCommandSuggestion] {
        TerminalPromptCompletion.matches(buffer: Array(text), cursorIndex: cursorIndex, commands: suggestions)
    }

    func activeCommandSuggestionsLocked(state: State) -> [TerminalCommandSuggestion] {
        state.editor.visibleSuggestions(context: editorContextLocked(state: state))
    }
}
