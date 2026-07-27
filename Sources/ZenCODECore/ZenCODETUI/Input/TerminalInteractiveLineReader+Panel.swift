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
    ) async -> Bool {
        await startPanelInput(
            statusBar: statusBar,
            commandSuggestions: commandSuggestions,
            preservingState: false,
            onEvent: onEvent
        )
    }

    func resumePanelInput(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion] = [],
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) async -> Bool {
        await startPanelInput(
            statusBar: statusBar,
            commandSuggestions: commandSuggestions,
            preservingState: true,
            onEvent: onEvent
        )
    }

    private func startPanelInput(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion],
        preservingState: Bool,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) async -> Bool {
        // A start may only proceed from a settled panel. If a stop is still
        // unwinding, its `restoreRawMode()` has not run yet, so acquiring raw
        // mode here would be silently undone by the predecessor's teardown.
        let admission = await admitPanelStart(
            statusBar: statusBar,
            commandSuggestions: commandSuggestions,
            preservingState: preservingState
        )
        guard admission == .admitted else {
            return true
        }

        guard rawInput.beginRawMode() else {
            if let failureDescription = rawInput.lastRawModeFailureDescription() {
                AgentOutput.standardError.writeString(
                    "[ZenCODE] Interactive prompt raw input failed: \(failureDescription)\n"
                )
            }
            abandonPanelStart()
            return false
        }

        let task = Task(name: "ZenCODE.TUI.panel-input") { [weak self] in
            guard let self else {
                return
            }
            await self.runPanelInputLoop(statusBar: statusBar, onEvent: onEvent)
        }

        finishPanelStart(task: task)
        await renderPanel()
        return true
    }

    /// Waits out any in-flight panel transition, then tries to claim the panel
    /// for a new start.
    ///
    /// Waiting is what makes the hand-over safe: `state.panelTask == nil` says only
    /// that a stop has *begun*, not that the terminal is free. The stop still
    /// has to await its loop task and restore raw mode, and a start admitted in
    /// between would observe `beginRawMode() == true` merely because the
    /// terminal is still raw from the session being torn down.
    func admitPanelStart(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion],
        preservingState: Bool
    ) async -> PanelStartAdmission {
        while true {
            let admission = preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: commandSuggestions,
                preservingState: preservingState
            )
            guard admission == .transitionInFlight else {
                return admission
            }
            await awaitPanelTransition()
        }
    }

    /// Synchronous half of the start admission, taken under the panel lock.
    func preparePanelForStart(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion],
        preservingState: Bool
    ) -> PanelStartAdmission {
        withPanelLock { state -> PanelStartAdmission in
            switch state.panelLifecycle {
            case .running, .starting:
                // Another reader already owns (or is acquiring) the terminal.
                return .alreadyActive
            case .stopping:
                return .transitionInFlight
            case .idle:
                break
            }

            state.panelLifecycle = .starting
            state.panelStatusBar = statusBar
            state.panelCommandSuggestions = commandSuggestions
            if preservingState {
                state.panelCommandSuggestionIndex = commandSuggestions.isEmpty
                    ? 0
                    : min(state.panelCommandSuggestionIndex, commandSuggestions.count - 1)
            } else {
                state.panelCommandSuggestionIndex = 0
                state.panelBuffer.removeAll()
                state.panelCursorIndex = 0
                state.panelOverlayOverride = nil
                state.historyIndex = nil
                state.draftBeforeHistory.removeAll()
            }
            return .admitted
        }
    }

    /// Publishes the running panel and releases anyone waiting on the start.
    func finishPanelStart(task: Task<Void, Never>) {
        resumePanelTransitionWaiters { state in
            state.panelTask = task
            state.panelLifecycle = .running
        }
    }

    /// Rolls a failed start back to `idle` so a later start (or a stop) is not
    /// blocked behind a transition that will never complete.
    func abandonPanelStart() {
        resumePanelTransitionWaiters { state in
            state.panelTask = nil
            state.panelLifecycle = .idle
            state.panelStatusBar = nil
        }
    }

    public func stopPanelInput(clearPanel: Bool = true) async {
        let stopState = await claimPanelForStop()

        stopState.task?.cancel()
        await stopState.task?.value
        // Only now is the terminal provably free: the loop has left its blocking
        // read, so raw mode can be handed back. The panel stays marked
        // `stopping` until `finishPanelStop`, so no successor can acquire the
        // TTY before this restore has run.
        rawInput.restoreRawMode()
        if clearPanel {
            let revision = withPanelLock { state -> UInt64 in
                state.panelRenderRevision &+= 1
                return state.panelRenderRevision
            }
            await stopState.statusBar?.clearInputPanel(revision: revision)
        }
        finishPanelStop(clearPanel: clearPanel)
    }

    /// Waits out any in-flight transition, then marks the panel `stopping` and
    /// takes the state this teardown owns.
    ///
    /// A stop must not race a start either: during `starting` the successor has
    /// not published its task yet, so a stop would await `nil`, restore raw mode
    /// under the new reader, and leave it reading a cooked terminal.
    func claimPanelForStop() async -> (
        task: Task<Void, Never>?,
        statusBar: TerminalStatusBar?
    ) {
        while true {
            if let claim = takePanelTaskForStop() {
                return claim
            }
            await awaitPanelTransition()
        }
    }

    /// Synchronous half of the stop claim. Returns `nil` while another
    /// transition still owns the panel.
    func takePanelTaskForStop() -> (
        task: Task<Void, Never>?,
        statusBar: TerminalStatusBar?
    )? {
        withPanelLock { state -> (task: Task<Void, Never>?, statusBar: TerminalStatusBar?)? in
            switch state.panelLifecycle {
            case .starting, .stopping:
                return nil
            case .idle, .running:
                break
            }

            let panelState = (task: state.panelTask, statusBar: state.panelStatusBar)
            state.panelLifecycle = .stopping
            state.panelTask = nil
            // Unblock the in-flight terminal read before awaiting the task, so
            // the stop does not wait out the remainder of the read window.
            state.panelReadToken?.cancel()
            state.panelReadToken = nil
            return panelState
        }
    }

    func finishPanelStop(clearPanel: Bool) {
        resumePanelTransitionWaiters { state in
            if clearPanel {
                state.panelStatusBar = nil
                state.panelBuffer.removeAll()
                state.panelCursorIndex = 0
                state.panelOverlayOverride = nil
                state.panelCommandSuggestions.removeAll()
                state.panelCommandSuggestionIndex = 0
                state.historyIndex = nil
                state.draftBeforeHistory.removeAll()
            }
            state.panelTask = nil
            state.panelLifecycle = .idle
        }
    }

    /// Suspends until the in-flight transition publishes a settled state.
    ///
    /// Registration happens under the same lock that settles the panel, so a
    /// transition completing between the check and the suspension cannot strand
    /// the waiter.
    private func awaitPanelTransition() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSettled = withPanelLock { state -> Bool in
                switch state.panelLifecycle {
                case .idle, .running:
                    return true
                case .starting, .stopping:
                    state.panelTransitionWaiters.append(continuation)
                    return false
                }
            }
            if isSettled {
                continuation.resume()
            }
        }
    }

    /// Applies a settling mutation and releases the parked callers.
    ///
    /// The waiters are resumed outside the panel lock: resuming re-enters the
    /// caller, which immediately reaches for the same lock.
    private func resumePanelTransitionWaiters(
        _ settle: @Sendable (inout State) -> Void
    ) {
        let waiters = withPanelLock { state -> [CheckedContinuation<Void, Never>] in
            settle(&state)
            let waiters = state.panelTransitionWaiters
            state.panelTransitionWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func setPanelProcessing(_ isProcessing: Bool) async {
        withPanelLock { state in
            state.panelIsProcessing = isProcessing
        }
        await renderPanel()
    }

    public func setPanelCommandSuggestions(_ suggestions: [TerminalCommandSuggestion]) async {
        withPanelLock { state in
            state.panelCommandSuggestions = suggestions
            state.panelCommandSuggestionIndex = 0
        }
        await renderPanel()
    }

    public func setQueuedPromptCount(_ count: Int) async {
        withPanelLock { state in
            state.panelQueuedPromptCount = max(0, count)
        }
        await renderPanel()
    }

    public func setPanelModeOverride(_ override: TerminalPanelModeOverride?) async {
        await setPanelOverlay(override)
    }

    public func setPanelOverlay(
        _ override: TerminalPanelModeOverride?,
        isProcessing: Bool? = nil
    ) async {
        withPanelLock { state in
            state.panelOverlayOverride = override
            if let isProcessing {
                state.panelIsProcessing = isProcessing
            }
            state.panelCommandSuggestionIndex = 0
        }
        await renderPanel()
    }

    public func setPanelText(_ text: String, cursorIndex: Int? = nil) async {
        withPanelLock { state in
            state.panelBuffer = Array(text)
            state.panelCursorIndex = min(max(0, cursorIndex ?? state.panelBuffer.count), state.panelBuffer.count)
            state.panelCommandSuggestionIndex = 0
            state.historyIndex = nil
            state.draftBeforeHistory.removeAll()
        }
        await renderPanel()
    }

    public func refreshPanel() async {
        await renderPanel()
    }

    /// Drives the live input panel.
    ///
    /// The key read blocks the calling thread, so it runs through
    /// ``TerminalBlockingRead`` instead of directly on this task: a cooperative
    /// worker must never sit in a POSIX `poll`/`read` loop, or rendering, the
    /// status bar, and every background refresh task stall behind it. Reads are
    /// polled at a short timeout and gated on the panel's cancellation token, so
    /// `stopPanelInput()` unwinds the loop immediately rather than after the
    /// remainder of a long read window.
    func runPanelInputLoop(
        statusBar _: TerminalStatusBar,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) async {
        let token = TerminalBlockingReadToken()
        withPanelLock { state in
            state.panelReadToken?.cancel()
            state.panelReadToken = token
        }
        defer {
            token.cancel()
            withPanelLock { state in
                if state.panelReadToken === token {
                    state.panelReadToken = nil
                }
            }
        }

        while !Task.isCancelled, !token.isCancelled() {
            let result = await TerminalBlockingRead.run(token: token) { token in
                Self.readPanelKeyResult(reader: self, token: token)
            }
            guard let result else {
                // Cancelled: the panel is stopping and must not emit further
                // events for keys read during teardown.
                return
            }
            let key: Key
            switch result {
            case let .key(value):
                key = value
            case .timedOut:
                continue
            case .endOfInput:
                onEvent(.endOfInput)
                return
            }
            await handlePanelKey(key, onEvent: onEvent)
        }
    }

    /// Blocking half of the panel read. Polls in short slices so the loop
    /// observes cancellation promptly, and stands down while a consent prompt
    /// owns the terminal so it cannot consume the operator's authorization key.
    static func readPanelKeyResult(
        reader: TerminalInteractiveLineReader,
        token: TerminalBlockingReadToken
    ) -> KeyReadResult? {
        while !token.isCancelled() {
            guard let result = TerminalConsentInputOwnership.withBackgroundRead({
                reader.readKeyResult(
                    pollTimeoutMilliseconds: TerminalInteractiveLineReader.cancellationPollTimeout
                )
            }) else {
                // Consent owns the terminal; report a timeout so the loop
                // re-checks cancellation without consuming any byte. Idle first
                // so the arbiter is not polled in a tight loop.
                Thread.sleep(forTimeInterval: consentBackoffSeconds)
                return .timedOut
            }
            if result == .timedOut {
                // Surface the timeout so the caller can re-evaluate its state
                // instead of holding this thread indefinitely.
                return .timedOut
            }
            return result
        }
        return nil
    }

    func handlePanelKey(
        _ key: Key,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) async {
        switch key {
        case let .character(text), let .paste(text):
            let characters = Array(text)
            guard !characters.isEmpty else {
                return
            }
            withPanelLock { state in
                state.panelBuffer.insert(contentsOf: characters, at: state.panelCursorIndex)
                state.panelCursorIndex += characters.count
                state.historyIndex = nil
            }
            await renderPanel()
        case .enter:
            if let submission = withPanelLock({ state -> CommandSuggestionSelection? in
                acceptPanelCommandSuggestionLocked(
                    submitCommandWithoutArguments: true,
                    state: &state
                )
            }) {
                if let submittedLine = submission.submittedLine {
                    recordHistory(submittedLine)
                    onEvent(.submitted(submittedLine))
                }
                await renderPanel()
                return
            }

            let line = withPanelLock { state -> String in
                let line = String(state.panelBuffer)
                state.panelBuffer.removeAll()
                state.panelCursorIndex = 0
                state.historyIndex = nil
                state.draftBeforeHistory.removeAll()
                return line
            }

            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordHistory(line)
            }
            onEvent(.submitted(line))
            await renderPanel()
        case .tab:
            let accepted = withPanelLock { state -> Bool in
                acceptPanelCommandSuggestionLocked(
                    submitCommandWithoutArguments: false,
                    state: &state
                ) != nil
            }
            if accepted {
                await renderPanel()
            }
        case .newline:
            withPanelLock { state in
                state.panelBuffer.insert("\n", at: state.panelCursorIndex)
                state.panelCursorIndex += 1
                state.panelCommandSuggestionIndex = 0
                state.historyIndex = nil
            }
            await renderPanel()
        case .backspace:
            let didChange = withPanelLock { state -> Bool in
                guard state.panelCursorIndex > 0 else {
                    return false
                }
                state.panelBuffer.remove(at: state.panelCursorIndex - 1)
                state.panelCursorIndex -= 1
                return true
            }
            if didChange {
                await renderPanel()
            }
        case .delete:
            let didChange = withPanelLock { state -> Bool in
                guard state.panelCursorIndex < state.panelBuffer.count else {
                    return false
                }
                state.panelBuffer.remove(at: state.panelCursorIndex)
                return true
            }
            if didChange {
                await renderPanel()
            }
        case .left:
            withPanelLock { state in
                if state.panelCursorIndex > 0 {
                    state.panelCursorIndex -= 1
                }
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .right:
            withPanelLock { state in
                if state.panelCursorIndex < state.panelBuffer.count {
                    state.panelCursorIndex += 1
                }
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .up:
            withPanelLock { state in
                if hasActiveCommandSuggestionsLocked(state: state) {
                    movePanelCommandSuggestionSelectionLocked(delta: -1, state: &state)
                } else if let previous = previousHistoryLocked(
                    currentBuffer: state.panelBuffer,
                    state: &state
                ) {
                    state.panelBuffer = previous
                    state.panelCursorIndex = state.panelBuffer.count
                }
            }
            await renderPanel()
        case .down:
            withPanelLock { state in
                if hasActiveCommandSuggestionsLocked(state: state) {
                    movePanelCommandSuggestionSelectionLocked(delta: 1, state: &state)
                } else if let next = nextHistoryLocked(state: &state) {
                    state.panelBuffer = next
                    state.panelCursorIndex = state.panelBuffer.count
                }
            }
            await renderPanel()
        case .home:
            withPanelLock { state in
                state.panelCursorIndex = 0
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .end:
            withPanelLock { state in
                state.panelCursorIndex = state.panelBuffer.count
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .clearBeforeCursor:
            withPanelLock { state in
                if state.panelCursorIndex > 0 {
                    state.panelBuffer.removeSubrange(0..<state.panelCursorIndex)
                    state.panelCursorIndex = 0
                }
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .clearAfterCursor:
            withPanelLock { state in
                if state.panelCursorIndex < state.panelBuffer.count {
                    state.panelBuffer.removeSubrange(state.panelCursorIndex..<state.panelBuffer.count)
                }
                state.panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .toggleToolDetails:
            onEvent(.toggleToolDetailsRequested)
            await renderPanel()
        case .toggleAccessMode:
            onEvent(.toggleAccessModeRequested)
            await renderPanel()
        case .cancel:
            let isProcessing = withPanelLock { state -> Bool in
                let isProcessing = state.panelIsProcessing
                if !isProcessing {
                    state.panelBuffer.removeAll()
                    state.panelCursorIndex = 0
                    state.panelCommandSuggestionIndex = 0
                    state.historyIndex = nil
                    state.draftBeforeHistory.removeAll()
                }
                return isProcessing
            }
            if isProcessing {
                onEvent(.cancelRequested)
            }
            await renderPanel()
        case .endOfInput:
            let isEmpty = withPanelLock { state in
                state.panelBuffer.isEmpty
            }
            if isEmpty {
                onEvent(.endOfInput)
            }
        case .unknown:
            return
        }
    }

    func renderPanel() async {
        let snapshot = withPanelLock { state -> (
            statusBar: TerminalStatusBar?,
            text: String,
            cursorIndex: Int,
            modeText: String,
            helpText: String,
            compactHelpText: String?,
            suggestionLines: [String],
            revision: UInt64
        ) in
            state.panelRenderRevision &+= 1
            return (
                statusBar: state.panelStatusBar,
                text: String(state.panelBuffer),
                cursorIndex: state.panelCursorIndex,
                modeText: panelModeTextLocked(state: state),
                helpText: panelHelpTextLocked(state: state),
                compactHelpText: panelCompactHelpTextLocked(state: state),
                suggestionLines: panelCommandSuggestionLinesLocked(state: &state),
                revision: state.panelRenderRevision
            )
        }

        await snapshot.statusBar?.updateInputPanel(
            text: snapshot.text,
            cursorIndex: snapshot.cursorIndex,
            modeText: snapshot.modeText,
            helpText: snapshot.helpText,
            compactHelpText: snapshot.compactHelpText,
            suggestionLines: snapshot.suggestionLines,
            revision: snapshot.revision
        )
    }

    func panelModeTextLocked(state: State) -> String {
        if let modeText = state.panelOverlayOverride?.modeText {
            return modeText
        }

        var modeText = state.panelIsProcessing ? "Next prompt" : "Prompt"
        if state.panelQueuedPromptCount > 0 {
            modeText += " · queued \(state.panelQueuedPromptCount)"
        }
        return modeText
    }

    func panelHelpTextLocked(state: State) -> String {
        if let helpText = state.panelOverlayOverride?.helpText {
            return helpText
        }

        if hasActiveCommandSuggestionsLocked(state: state) {
            return "↑/↓ select · Tab complete · Enter choose"
        }
        return "Enter queue · Option+Enter newline · Ctrl+T tools · Ctrl+A access · Esc stop"
    }

    func panelCompactHelpTextLocked(state: State) -> String? {
        guard state.panelOverlayOverride == nil,
              !hasActiveCommandSuggestionsLocked(state: state) else {
            return nil
        }
        return "Ctrl+T · Ctrl+A access"
    }

    struct CommandSuggestionSelection: Sendable {
        let submittedLine: String?
    }

    func acceptPanelCommandSuggestionLocked(
        submitCommandWithoutArguments: Bool,
        state: inout State
    ) -> CommandSuggestionSelection? {
        guard let selectedSuggestion = selectedPanelCommandSuggestionLocked(state: &state) else {
            return nil
        }

        let replacement = selectedSuggestion.requiresArgument
            ? "\(selectedSuggestion.command) "
            : selectedSuggestion.command
        state.panelBuffer = Array(replacement)
        state.panelCursorIndex = state.panelBuffer.count
        state.panelCommandSuggestionIndex = 0
        state.historyIndex = nil
        state.draftBeforeHistory.removeAll()

        guard submitCommandWithoutArguments,
              !selectedSuggestion.requiresArgument else {
            return CommandSuggestionSelection(submittedLine: nil)
        }

        let submittedLine = String(state.panelBuffer)
        state.panelBuffer.removeAll()
        state.panelCursorIndex = 0
        return CommandSuggestionSelection(submittedLine: submittedLine)
    }

    func selectedPanelCommandSuggestionLocked(state: inout State) -> TerminalCommandSuggestion? {
        let suggestions = activeCommandSuggestionsLocked(state: state)
        guard !suggestions.isEmpty else {
            return nil
        }
        state.panelCommandSuggestionIndex = min(
            max(0, state.panelCommandSuggestionIndex),
            suggestions.count - 1
        )
        return suggestions[state.panelCommandSuggestionIndex]
    }

    func hasActiveCommandSuggestionsLocked(state: State) -> Bool {
        !activeCommandSuggestionsLocked(state: state).isEmpty
    }

    func movePanelCommandSuggestionSelectionLocked(delta: Int, state: inout State) {
        let suggestions = activeCommandSuggestionsLocked(state: state)
        guard !suggestions.isEmpty else {
            state.panelCommandSuggestionIndex = 0
            return
        }
        let count = suggestions.count
        state.panelCommandSuggestionIndex = (state.panelCommandSuggestionIndex + delta + count) % count
    }

    func panelCommandSuggestionLinesLocked(state: inout State) -> [String] {
        let suggestions = activeCommandSuggestionsLocked(state: state)
        guard !suggestions.isEmpty else {
            state.panelCommandSuggestionIndex = 0
            return []
        }

        state.panelCommandSuggestionIndex = min(
            max(0, state.panelCommandSuggestionIndex),
            suggestions.count - 1
        )

        let visibleSuggestions = Self.visiblePanelCommandSuggestionWindow(
            suggestions: suggestions,
            selectedIndex: state.panelCommandSuggestionIndex,
            maximumLineCount: Self.maximumPanelCommandSuggestionLines
        )
        return visibleSuggestions.map { item in
            let marker = item.index == state.panelCommandSuggestionIndex ? "›" : " "
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

    func activeCommandSuggestionsLocked(state: State) -> [TerminalCommandSuggestion] {
        guard state.panelOverlayOverride == nil else {
            return []
        }

        return Self.matchingPanelCommandSuggestions(
            text: String(state.panelBuffer),
            cursorIndex: state.panelCursorIndex,
            suggestions: state.panelCommandSuggestions
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
