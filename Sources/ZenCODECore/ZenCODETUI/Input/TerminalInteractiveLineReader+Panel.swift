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

        let task = Task { [weak self] in
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
    /// Waiting is what makes the hand-over safe: `panelTask == nil` says only
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
        withPanelLock { () -> PanelStartAdmission in
            switch panelLifecycle {
            case .running, .starting:
                // Another reader already owns (or is acquiring) the terminal.
                return .alreadyActive
            case .stopping:
                return .transitionInFlight
            case .idle:
                break
            }

            panelLifecycle = .starting
            panelStatusBar = statusBar
            panelCommandSuggestions = commandSuggestions
            if preservingState {
                panelCommandSuggestionIndex = commandSuggestions.isEmpty
                    ? 0
                    : min(panelCommandSuggestionIndex, commandSuggestions.count - 1)
            } else {
                panelCommandSuggestionIndex = 0
                panelBuffer.removeAll()
                panelCursorIndex = 0
                panelOverlayOverride = nil
                historyIndex = nil
                draftBeforeHistory.removeAll()
            }
            return .admitted
        }
    }

    /// Publishes the running panel and releases anyone waiting on the start.
    func finishPanelStart(task: Task<Void, Never>) {
        resumePanelTransitionWaiters {
            panelTask = task
            panelLifecycle = .running
        }
    }

    /// Rolls a failed start back to `idle` so a later start (or a stop) is not
    /// blocked behind a transition that will never complete.
    func abandonPanelStart() {
        resumePanelTransitionWaiters {
            panelTask = nil
            panelLifecycle = .idle
            panelStatusBar = nil
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
            let revision = withPanelLock { () -> UInt64 in
                panelRenderRevision &+= 1
                return panelRenderRevision
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
        withPanelLock { () -> (task: Task<Void, Never>?, statusBar: TerminalStatusBar?)? in
            switch panelLifecycle {
            case .starting, .stopping:
                return nil
            case .idle, .running:
                break
            }

            let state = (task: panelTask, statusBar: panelStatusBar)
            panelLifecycle = .stopping
            panelTask = nil
            // Unblock the in-flight terminal read before awaiting the task, so
            // the stop does not wait out the remainder of the read window.
            panelReadToken?.cancel()
            panelReadToken = nil
            return state
        }
    }

    func finishPanelStop(clearPanel: Bool) {
        resumePanelTransitionWaiters {
            if clearPanel {
                panelStatusBar = nil
                panelBuffer.removeAll()
                panelCursorIndex = 0
                panelOverlayOverride = nil
                panelCommandSuggestions.removeAll()
                panelCommandSuggestionIndex = 0
                historyIndex = nil
                draftBeforeHistory.removeAll()
            }
            panelTask = nil
            panelLifecycle = .idle
        }
    }

    /// Suspends until the in-flight transition publishes a settled state.
    ///
    /// Registration happens under the same lock that settles the panel, so a
    /// transition completing between the check and the suspension cannot strand
    /// the waiter.
    private func awaitPanelTransition() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSettled = withPanelLock { () -> Bool in
                switch panelLifecycle {
                case .idle, .running:
                    return true
                case .starting, .stopping:
                    panelTransitionWaiters.append(continuation)
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
        _ settle: @Sendable () -> Void
    ) {
        let waiters = withPanelLock { () -> [CheckedContinuation<Void, Never>] in
            settle()
            let waiters = panelTransitionWaiters
            panelTransitionWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func setPanelProcessing(_ isProcessing: Bool) async {
        withPanelLock {
            panelIsProcessing = isProcessing
        }
        await renderPanel()
    }

    public func setPanelCommandSuggestions(_ suggestions: [TerminalCommandSuggestion]) async {
        withPanelLock {
            panelCommandSuggestions = suggestions
            panelCommandSuggestionIndex = 0
        }
        await renderPanel()
    }

    public func setQueuedPromptCount(_ count: Int) async {
        withPanelLock {
            panelQueuedPromptCount = max(0, count)
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
        withPanelLock {
            panelOverlayOverride = override
            if let isProcessing {
                panelIsProcessing = isProcessing
            }
            panelCommandSuggestionIndex = 0
        }
        await renderPanel()
    }

    public func setPanelText(_ text: String, cursorIndex: Int? = nil) async {
        withPanelLock {
            panelBuffer = Array(text)
            panelCursorIndex = min(max(0, cursorIndex ?? panelBuffer.count), panelBuffer.count)
            panelCommandSuggestionIndex = 0
            historyIndex = nil
            draftBeforeHistory.removeAll()
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
        withPanelLock {
            panelReadToken?.cancel()
            panelReadToken = token
        }
        defer {
            token.cancel()
            withPanelLock {
                if panelReadToken === token {
                    panelReadToken = nil
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
            withPanelLock {
                panelBuffer.insert(contentsOf: characters, at: panelCursorIndex)
                panelCursorIndex += characters.count
                historyIndex = nil
            }
            await renderPanel()
        case .enter:
            if let submission = withPanelLock({ () -> CommandSuggestionSelection? in
                acceptPanelCommandSuggestionLocked(
                    submitCommandWithoutArguments: true
                )
            }) {
                if let submittedLine = submission.submittedLine {
                    recordHistory(submittedLine)
                    onEvent(.submitted(submittedLine))
                }
                await renderPanel()
                return
            }

            let line = withPanelLock { () -> String in
                let line = String(panelBuffer)
                panelBuffer.removeAll()
                panelCursorIndex = 0
                historyIndex = nil
                draftBeforeHistory.removeAll()
                return line
            }

            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordHistory(line)
            }
            onEvent(.submitted(line))
            await renderPanel()
        case .tab:
            let accepted = withPanelLock { () -> Bool in
                acceptPanelCommandSuggestionLocked(
                    submitCommandWithoutArguments: false
                ) != nil
            }
            if accepted {
                await renderPanel()
            }
        case .newline:
            withPanelLock {
                panelBuffer.insert("\n", at: panelCursorIndex)
                panelCursorIndex += 1
                panelCommandSuggestionIndex = 0
                historyIndex = nil
            }
            await renderPanel()
        case .backspace:
            let didChange = withPanelLock { () -> Bool in
                guard panelCursorIndex > 0 else {
                    return false
                }
                panelBuffer.remove(at: panelCursorIndex - 1)
                panelCursorIndex -= 1
                return true
            }
            if didChange {
                await renderPanel()
            }
        case .delete:
            let didChange = withPanelLock { () -> Bool in
                guard panelCursorIndex < panelBuffer.count else {
                    return false
                }
                panelBuffer.remove(at: panelCursorIndex)
                return true
            }
            if didChange {
                await renderPanel()
            }
        case .left:
            withPanelLock {
                if panelCursorIndex > 0 {
                    panelCursorIndex -= 1
                }
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .right:
            withPanelLock {
                if panelCursorIndex < panelBuffer.count {
                    panelCursorIndex += 1
                }
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .up:
            withPanelLock {
                if hasActiveCommandSuggestionsLocked() {
                    movePanelCommandSuggestionSelectionLocked(delta: -1)
                } else if let previous = previousHistory(currentBuffer: panelBuffer) {
                    panelBuffer = previous
                    panelCursorIndex = panelBuffer.count
                }
            }
            await renderPanel()
        case .down:
            withPanelLock {
                if hasActiveCommandSuggestionsLocked() {
                    movePanelCommandSuggestionSelectionLocked(delta: 1)
                } else if let next = nextHistory() {
                    panelBuffer = next
                    panelCursorIndex = panelBuffer.count
                }
            }
            await renderPanel()
        case .home:
            withPanelLock {
                panelCursorIndex = 0
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .end:
            withPanelLock {
                panelCursorIndex = panelBuffer.count
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .clearBeforeCursor:
            withPanelLock {
                if panelCursorIndex > 0 {
                    panelBuffer.removeSubrange(0..<panelCursorIndex)
                    panelCursorIndex = 0
                }
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .clearAfterCursor:
            withPanelLock {
                if panelCursorIndex < panelBuffer.count {
                    panelBuffer.removeSubrange(panelCursorIndex..<panelBuffer.count)
                }
                panelCommandSuggestionIndex = 0
            }
            await renderPanel()
        case .toggleToolDetails:
            onEvent(.toggleToolDetailsRequested)
            await renderPanel()
        case .toggleAccessMode:
            onEvent(.toggleAccessModeRequested)
            await renderPanel()
        case .cancel:
            let isProcessing = withPanelLock { () -> Bool in
                let isProcessing = panelIsProcessing
                if !isProcessing {
                    panelBuffer.removeAll()
                    panelCursorIndex = 0
                    panelCommandSuggestionIndex = 0
                    historyIndex = nil
                    draftBeforeHistory.removeAll()
                }
                return isProcessing
            }
            if isProcessing {
                onEvent(.cancelRequested)
            }
            await renderPanel()
        case .endOfInput:
            let isEmpty = withPanelLock {
                panelBuffer.isEmpty
            }
            if isEmpty {
                onEvent(.endOfInput)
            }
        case .unknown:
            return
        }
    }

    func renderPanel() async {
        let snapshot = withPanelLock { () -> (
            statusBar: TerminalStatusBar?,
            text: String,
            cursorIndex: Int,
            modeText: String,
            helpText: String,
            compactHelpText: String?,
            suggestionLines: [String],
            revision: UInt64
        ) in
            panelRenderRevision &+= 1
            return (
                statusBar: panelStatusBar,
                text: String(panelBuffer),
                cursorIndex: panelCursorIndex,
                modeText: panelModeTextLocked(),
                helpText: panelHelpTextLocked(),
                compactHelpText: panelCompactHelpTextLocked(),
                suggestionLines: panelCommandSuggestionLinesLocked(),
                revision: panelRenderRevision
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
        return "Enter queue · Option+Enter newline · Ctrl+T tools · Ctrl+A access · Esc stop"
    }

    func panelCompactHelpTextLocked() -> String? {
        guard panelOverlayOverride == nil,
              !hasActiveCommandSuggestionsLocked() else {
            return nil
        }
        return "Ctrl+T · Ctrl+A access"
    }

    struct CommandSuggestionSelection: Sendable {
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
