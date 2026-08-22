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
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
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
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
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
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
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
                state.editor = TerminalPromptEditor()
                state.panelOverlayOverride = nil
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
            state.editor.areSuggestionsDismissed = false
        }
        await renderPanel()
    }

    /// Installs the live `@mention` source used while the operator edits a
    /// mention token. Passing `nil` removes it.
    public func setPanelMentionSuggestionsProvider(
        _ provider: (@Sendable () async -> [TerminalCommandSuggestion])?
    ) {
        withPanelLock { state in
            state.panelMentionSuggestionsProvider = provider
        }
    }

    /// Replaces the `@mention` entries of the catalogue with a fresh roster
    /// snapshot while the cursor is completing a mention.
    ///
    /// Slash-command entries are untouched, so this never races the
    /// agent-scoped command catalogue. The refresh is single-flight and only
    /// runs for a mention token, so ordinary typing performs no extra work.
    func refreshPanelMentionSuggestionsIfNeeded() async {
        let provider = withPanelLock { state -> (@Sendable () async -> [TerminalCommandSuggestion])? in
            guard let provider = state.panelMentionSuggestionsProvider,
                  !state.isRefreshingMentionSuggestions,
                  TerminalPromptCompletion.completion(
                      buffer: state.panelBuffer,
                      cursorIndex: state.panelCursorIndex
                  )?.kind == .mention else {
                return nil
            }
            state.isRefreshingMentionSuggestions = true
            return provider
        }
        guard let provider else { return }
        let mentions = await provider()
        let didChange = withPanelLock { state -> Bool in
            state.isRefreshingMentionSuggestions = false
            let commands = state.panelCommandSuggestions.filter {
                !$0.command.hasPrefix("@")
            }
            let updated = commands + mentions
            guard updated != state.panelCommandSuggestions else {
                return false
            }
            state.panelCommandSuggestions = updated
            state.panelCommandSuggestionIndex = 0
            return true
        }
        guard didChange else { return }
        await renderPanel()
    }

    public func setQueuedPromptCount(_ count: Int) async {
        withPanelLock { state in
            state.panelQueuedPromptCount = max(0, count)
        }
        await renderPanel()
    }

    /// Publishes how many attachments are staged for the next prompt so the
    /// panel can say so without the operator running `/attach list`.
    public func setPendingAttachmentCount(_ count: Int) async {
        let didChange = withPanelLock { state -> Bool in
            let bounded = max(0, count)
            guard state.panelPendingAttachmentCount != bounded else {
                return false
            }
            state.panelPendingAttachmentCount = bounded
            return true
        }
        guard didChange else {
            return
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
            // Programmatic text replaces the draft outright, so every piece of
            // navigation state derived from the old draft has to go with it.
            state.editor = TerminalPromptEditor()
            state.panelBuffer = Array(text)
            state.panelCursorIndex = min(max(0, cursorIndex ?? state.panelBuffer.count), state.panelBuffer.count)
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
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
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
                await onEvent(.endOfInput)
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
                // The test synchronization point is deliberately immediately
                // before the raw read: publishing the token alone happens
                // before this dispatch-queue worker is scheduled.
                token.markBlockingReadEntered()
                return reader.readKeyResult(
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

    /// Applies one key through the shared editor reducer and dispatches the
    /// resulting effect.
    ///
    /// The reducer runs entirely under the panel lock because it is pure and
    /// cannot suspend; every `await` (rendering, event delivery) happens after
    /// the lock has been released.
    func handlePanelKey(
        _ key: Key,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
    ) async {
        let readerAction = withPanelLock { state -> TerminalSharedChatReaderAction? in
            guard state.panelSharedChatReaderIsOpen else { return nil }
            switch key {
            case .up: return .scrollUp
            case .down: return .scrollDown
            case .left: return .previousMessage
            case .right: return .nextMessage
            case .home, .bufferStart: return .firstMessage
            case .end, .bufferEnd: return .lastMessage
            default: return nil
            }
        }
        if let readerAction {
            await onEvent(.sharedChatReaderNavigation(readerAction))
            return
        }
        let effect = withPanelLock { state -> TerminalPromptEditorEffect in
            let effect = state.editor.apply(key, context: editorContextLocked(state: state))
            if case let .submitted(line) = effect {
                recordHistoryLocked(line, state: &state)
            }
            return effect
        }

        switch effect {
        case .ignored:
            return
        case .changed:
            // A mention token asks the chat for the live roster before drawing,
            // so the list is current even when a roster push event was lost.
            await refreshPanelMentionSuggestionsIfNeeded()
            await renderPanel()
        case let .submitted(line):
            await onEvent(.submitted(line))
            await renderPanel()
        case .cancelRequested:
            await onEvent(.cancelRequested)
            await renderPanel()
        case .endOfInput:
            await onEvent(.endOfInput)
        case .toggleToolDetails:
            await onEvent(.toggleToolDetailsRequested)
            await renderPanel()
        case .toggleAccessMode:
            await onEvent(.toggleAccessModeRequested)
            await renderPanel()
        case .toggleSharedChatReader:
            await onEvent(.toggleSharedChatReaderRequested)
            await renderPanel()
        }
    }

    func setSharedChatReaderOpen(_ isOpen: Bool) {
        withPanelLock { state in state.panelSharedChatReaderIsOpen = isOpen }
    }

    func editorContextLocked(state: State) -> TerminalPromptEditorContext {
        TerminalPromptEditorContext(
            history: state.history,
            suggestions: state.panelCommandSuggestions,
            isOverlayActive: state.panelOverlayOverride != nil,
            isProcessing: state.panelIsProcessing,
            supportsCompletions: true,
            clearsDraftOnCancel: true
        )
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
                suggestionLines: panelCommandSuggestionLinesLocked(state: state),
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

    /// Compact, single-line status of the draft.
    ///
    /// The panel is one row tall, so state the operator cannot otherwise see —
    /// which line of a multi-line draft the cursor is on, staged attachments,
    /// queued prompts — is summarised here rather than spent on extra rows.
    func panelModeTextLocked(state: State) -> String {
        if let modeText = state.panelOverlayOverride?.modeText {
            return modeText
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

        if state.panelIsProcessing {
            if hasActiveCommandSuggestionsLocked(state: state) {
                return "↑/↓ select · Tab complete · Enter choose · Esc stop"
            }
            return "Enter queue · Ctrl+T tools · Ctrl+G access · Ctrl+Y chat · Esc stop"
        }
        if hasActiveCommandSuggestionsLocked(state: state) {
            return "↑/↓ select · Tab complete · Enter choose · Esc dismiss"
        }
        return "Enter send · Ctrl+T tools · Ctrl+G access · Ctrl+Y chat · Esc clear"
    }

    func panelCompactHelpTextLocked(state: State) -> String? {
        guard state.panelOverlayOverride == nil,
              !hasActiveCommandSuggestionsLocked(state: state) else {
            return nil
        }
        if state.panelIsProcessing {
            return "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat"
        }
        return "Enter send · Esc clear · Ctrl+G access · Ctrl+Y chat"
    }

    func hasActiveCommandSuggestionsLocked(state: State) -> Bool {
        !activeCommandSuggestionsLocked(state: state).isEmpty
    }

    func movePanelCommandSuggestionSelectionLocked(delta: Int, state: inout State) {
        state.editor.moveSuggestionSelection(
            delta: delta,
            context: editorContextLocked(state: state)
        )
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

        let selectedIndex = min(
            max(0, state.panelCommandSuggestionIndex),
            suggestions.count - 1
        )
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
        TerminalPromptCompletion.matches(
            buffer: Array(text),
            cursorIndex: cursorIndex,
            commands: suggestions
        )
    }

    func activeCommandSuggestionsLocked(state: State) -> [TerminalCommandSuggestion] {
        state.editor.visibleSuggestions(context: editorContextLocked(state: state))
    }

    /// Text matched against the completion catalogue.
    ///
    /// It stops at the cursor rather than at the end of the token: with
    /// `/fea|ture` the operator is narrowing `/fea`, and matching the whole
    /// token would keep offering only what is already typed.
    static func commandPrefixForSuggestions(
        text: String,
        cursorIndex: Int
    ) -> String? {
        let prefix = TerminalPromptCompletion.completion(
            buffer: Array(text),
            cursorIndex: cursorIndex
        )?.prefix
        return (prefix?.isEmpty ?? true) ? nil : prefix
    }

}
