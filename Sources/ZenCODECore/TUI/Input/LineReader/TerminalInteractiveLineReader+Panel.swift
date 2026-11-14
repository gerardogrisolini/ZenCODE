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
    public func setPanelProcessing(_ isProcessing: Bool) async {
        withPanelLock { state in
            state.panelIsProcessing = isProcessing
        }
        await renderPanel()
    }

    /// Voice mode reports when it starts and stops reading an answer aloud.
    func setPanelSpeaking(_ isSpeaking: Bool) async {
        let changed = withPanelLock { state -> Bool in
            guard state.panelIsSpeaking != isSpeaking else {
                return false
            }
            state.panelIsSpeaking = isSpeaking
            return true
        }
        if changed {
            await renderPanel()
        }
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
        requestPanelRender()
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

    /// Replaces the panel mode override with `override`, and with
    /// `isProcessing` the processing flag, then redraws the panel. Production
    /// sets the only overrides, those of the panels above the prompt (the
    /// `/subagent` detail and the `/artifacts` panel), together with their key
    /// routing through ``setSubAgentDetailMode(_:panelModeOverride:)``; this
    /// entry point is left to tests of the override alone.
    func setPanelOverlay(_ override: TerminalPanelModeOverride?, isProcessing: Bool? = nil) async {
        withPanelLock { state in
            applyPanelOverlayLocked(override, state: &state)
            if let isProcessing {
                state.panelIsProcessing = isProcessing
            }
        }
        await renderPanel()
    }

    /// Replaces the panel mode override with `override` and resets the
    /// per-override state (a press-and-hold menu is dismissed while an
    /// override shows, and the command suggestion selection starts over).
    /// The caller holds the panel lock.
    private func applyPanelOverlayLocked(_ override: TerminalPanelModeOverride?, state: inout State) {
        state.panelOverlayOverride = override
        if override != nil {
            state.editor.resetPressAndHold()
        }
        state.panelCommandSuggestionIndex = 0
    }

    public func setPanelText(_ text: String, cursorIndex: Int? = nil) async {
        let dictationEnded = withPanelLock { state -> (@Sendable () -> Void)? in
            // Programmatic text replaces the draft outright, so every piece of
            // navigation state derived from the old draft has to go with it,
            // a dictation shown in it included.
            state.editor = TerminalPromptEditor()
            state.panelBuffer = Array(text)
            state.panelCursorIndex = min(max(0, cursorIndex ?? state.panelBuffer.count), state.panelBuffer.count)
            return endVoiceDictationLocked(state: &state)
        }
        dictationEnded?()
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
        statusBar: TerminalStatusBar,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
    ) async {
        await runPanelInputLoop(
            statusBar: statusBar,
            onEvent: onEvent,
            readNextTimedResult: { token in
                await TerminalBlockingRead.run(token: token) { token in
                    Self.readTimedPanelKeyResult(reader: self, token: token)
                }
            }
        )
    }

    /// Reduces timed panel reads from one serial source. The production entry
    /// above supplies the cancellation-aware blocking transport; keeping this
    /// half separate lets lifecycle tests deterministically hold rendering while
    /// the same live loop consumes a controlled stream of timestamps.
    func runPanelInputLoop(
        statusBar _: TerminalStatusBar,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void,
        readNextTimedResult: @escaping @Sendable (TerminalBlockingReadToken) async -> TimedPanelKeyReadResult?
    ) async {
        let token = TerminalBlockingReadToken()
        withPanelLock { state in
            state.panelLifecycle.replaceReadToken(with: token)?.cancel()
        }
        defer {
            token.cancel()
            withPanelLock { state in
                state.panelLifecycle.clearReadToken(token)
            }
        }

        while !Task.isCancelled, !token.isCancelled() {
            let timedResult = await readNextTimedResult(token)
            guard let timedResult else {
                // Cancelled: the panel is stopping and must not emit further
                // events for keys read during teardown.
                return
            }
            let key: Key
            switch timedResult.result {
            case let .key(value):
                key = value
            case .pickerEscape:
                key = .cancel
            case .timedOut:
                if invalidatePanelPressAndHoldForConsentIfNeeded() {
                    requestPanelRender()
                }
                continue
            case .endOfInput:
                _ = withPanelLock { state in
                    state.editor.resetPressAndHold()
                }
                await onEvent(.endOfInput)
                return
            }
            await handlePanelKey(
                key,
                timestampMilliseconds: timedResult.timestampMilliseconds,
                consumedPickerRepeat: timedResult.result.consumedPickerRepeat,
                onEvent: onEvent
            )
        }
    }

    /// Associates the result with monotonic time on the blocking worker. Doing
    /// this before the async hop keeps executor and rendering delays out of the
    /// repeat intervals observed by the reducer.
    static func readTimedPanelKeyResult(
        reader: TerminalInteractiveLineReader,
        token: TerminalBlockingReadToken
    ) -> TimedPanelKeyReadResult? {
        guard let result = readPanelKeyResult(reader: reader, token: token) else {
            return nil
        }
        return TimedPanelKeyReadResult(
            result: result,
            timestampMilliseconds: DispatchTime.now().uptimeNanoseconds / 1_000_000
        )
    }

    /// Blocking half of the panel read. Polls in short slices so the loop
    /// observes cancellation promptly, and stands down while a consent prompt
    /// owns the terminal so it cannot consume the operator's authorization key.
    static func readPanelKeyResult(
        reader: TerminalInteractiveLineReader,
        token: TerminalBlockingReadToken
    ) -> KeyReadResult? {
        while !token.isCancelled() {
            guard let result = reader.consentInputOwnership.withBackgroundRead({
                // The test synchronization point is deliberately immediately
                // before the raw read: publishing the token alone happens
                // before this dispatch-queue worker is scheduled.
                token.markBlockingReadEntered()
                let pickerEscapeBaseByte = reader.withPanelLock { state -> UInt8? in
                    guard state.panelSupportsPressAndHold,
                          state.panelOverlayOverride == nil,
                          !state.panelSharedChatReaderIsOpen,
                          state.panelSubAgentDetailMode == .closed,
                          let base = state.editor.pressAndHoldMenu?.base else {
                        return nil
                    }
                    let bytes = Array(String(base).utf8)
                    guard bytes.count == 1 else { return nil }
                    return bytes[0]
                }
                return reader.readKeyResult(
                    pollTimeoutMilliseconds: TerminalInteractiveLineReader.cancellationPollTimeout,
                    pickerEscapeBaseByte: pickerEscapeBaseByte
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

    /// Routes one key to the layer that owns it and dispatches the result.
    ///
    /// The routing is decided by ``panelKeyRoute(for:subAgentDetailMode:isSharedChatReaderOpen:)``
    /// before any effect runs. A key left to the draft goes through the shared
    /// editor reducer, which runs entirely under the panel lock because it is
    /// pure and cannot suspend. Event delivery happens after the lock is
    /// released, and redraws are only enqueued there so slow terminal output
    /// never delays the next panel read.
    func handlePanelKey(
        _ key: Key,
        timestampMilliseconds: UInt64? = nil,
        consumedPickerRepeat: Character? = nil,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) async -> Void
    ) async {
        // The detail mode and the shared-chat reader are read in two critical
        // sections, the reader's only once the detail leaves the key to it.
        let subAgentDetailMode = withPanelLock { $0.panelSubAgentDetailMode }
        let route = Self.panelKeyRoute(
            for: key,
            subAgentDetailMode: subAgentDetailMode,
            isSharedChatReaderOpen: { withPanelLock { $0.panelSharedChatReaderIsOpen } }
        )
        switch route {
        case let .subAgentDetail(action):
            await onEvent(.subAgentDetail(action))
            return
        case .swallowedBySubAgentList:
            return
        case let .sharedChatReader(action):
            await onEvent(.sharedChatReaderNavigation(action))
            return
        case .editor:
            break
        }
        let (effect, dictationEnded) = withPanelLock { state -> (TerminalPromptEditorEffect, (@Sendable () -> Void)?) in
            let bufferBefore = state.editor.buffer
            let effect = state.editor.apply(
                key,
                context: editorContextLocked(state: state),
                timestampMilliseconds: timestampMilliseconds,
                consumedPickerRepeat: consumedPickerRepeat
            )
            var isSubmitted = false
            if case let .submitted(line) = effect {
                isSubmitted = true
                recordHistoryLocked(line, state: &state)
            }
            // A key that changes the draft turns a dictation shown in it into
            // ordinary text; pure cursor moves leave it running.
            guard isSubmitted || state.editor.buffer != bufferBefore else {
                return (effect, nil)
            }
            return (effect, endVoiceDictationLocked(state: &state))
        }
        dictationEnded?()

        switch effect {
        case .ignored:
            return
        case .changed:
            // A mention token asks the chat for the live roster before drawing,
            // so the list is current even when a roster push event was lost.
            await refreshPanelMentionSuggestionsIfNeeded()
            requestPanelRender()
        case let .submitted(line):
            await onEvent(.submitted(line))
            requestPanelRender()
        case .cancelRequested:
            await onEvent(.cancelRequested)
            requestPanelRender()
        case .endOfInput:
            await onEvent(.endOfInput)
        case .toggleAccessMode:
            await onEvent(.toggleAccessModeRequested)
            requestPanelRender()
        case .toggleSharedChatReader:
            await onEvent(.toggleSharedChatReaderRequested)
            requestPanelRender()
        }
    }

    func setSharedChatReaderOpen(_ isOpen: Bool) {
        withPanelLock { state in
            state.panelSharedChatReaderIsOpen = isOpen
            if isOpen {
                state.editor.resetPressAndHold()
            }
        }
    }

    /// What the `/subagent` detail does with the panel keys. The `/artifacts`
    /// panel routes its keys through the same modes: its file list is a
    /// ``list``, a file's diff a ``detail``.
    enum SubAgentDetailMode: Sendable, Equatable {
        /// No detail is open: every key belongs to the draft.
        case closed
        /// The detail lists the sub-agents in progress. It is modal: it owns
        /// every key but end-of-input and swallows those it does not bind.
        case list
        /// The detail shows an agent. Like the shared-chat reader it takes
        /// only its navigation keys and `Esc`; every other key edits and
        /// sends the draft, completions included.
        case detail
    }

    /// Sets what the `/subagent` detail does with the panel keys and the
    /// panel mode override that goes with it in one critical section, so no
    /// reader of the panel state (the key routing, a render snapshot) sees the
    /// mode of one and the panel mode of the other;
    /// ``SubAgentDetailMode/closed`` gives every key back to the draft.
    /// Synchronous like ``setSharedChatReaderOpen(_:)`` so the routing
    /// changes before the next key is reduced, and it does not render: the
    /// caller redraws the panel with ``refreshPanel()``. The mode survives
    /// panel stops and resumes; only the chat loop that opened the detail
    /// changes it.
    func setSubAgentDetailMode(
        _ mode: SubAgentDetailMode,
        panelModeOverride override: TerminalPanelModeOverride?
    ) {
        withPanelLock { state in
            state.panelSubAgentDetailMode = mode
            if mode != .closed {
                state.editor.resetPressAndHold()
            }
            applyPanelOverlayLocked(override, state: &state)
        }
    }

    /// Semantic action of a key for the `/subagent` detail in `mode`, or
    /// `nil` for a key the detail does not bind: the agent list swallows it,
    /// an agent's detail leaves it to the draft. In both modes the arrows,
    /// the page keys and `Home`/`End` scroll (the controller turns the
    /// arrows into the list focus) and `Esc` closes. Only the list binds
    /// `Enter` (open the focused agent) and `q`/`Q`
    /// (``TerminalSubAgentDetailAction/closeList``, which closes only the
    /// list): in an agent's detail they belong to the draft.
    static func subAgentDetailAction(
        for key: Key,
        mode: SubAgentDetailMode
    ) -> TerminalSubAgentDetailAction? {
        switch (mode, key) {
        case (.closed, _): nil
        case (_, .up): .scrollUp
        case (_, .down): .scrollDown
        case (_, .pageUp): .pageUp
        case (_, .pageDown): .pageDown
        case (_, .home), (_, .bufferStart): .top
        case (_, .end), (_, .bufferEnd): .bottom
        case (_, .cancel): .close
        case (.list, .enter), (.list, .newline): .confirm
        case (.list, .character("q")), (.list, .character("Q")): .closeList
        default: nil
        }
    }

    /// The layer of the panel that owns one key, decided before any effect.
    enum PanelKeyRoute: Sendable, Equatable {
        /// The `/subagent` detail binds the key.
        case subAgentDetail(TerminalSubAgentDetailAction)
        /// The modal agent list swallows a key it does not bind.
        case swallowedBySubAgentList
        /// The shared-chat reader binds the key.
        case sharedChatReader(TerminalSharedChatReaderAction)
        /// The key belongs to the draft editor.
        case editor
    }

    /// Precedence of the panel's key consumers.
    ///
    /// The `/subagent` detail comes first; end-of-input keeps its usual
    /// meaning in every mode. The agent list is modal: it owns every other
    /// key and swallows those it does not bind, so they can never edit the
    /// draft behind it. An agent's detail takes only its navigation keys,
    /// like the shared-chat reader after it, and leaves every other key to
    /// the draft, which the operator keeps typing and sending. In both
    /// `Esc` closes the detail instead of stopping the generation.
    ///
    /// `isSharedChatReaderOpen` is asked only when the detail leaves the key
    /// to the next layer, so the caller reads the reader's state exactly
    /// when the routing needs it, after the detail mode.
    static func panelKeyRoute(
        for key: Key,
        subAgentDetailMode: SubAgentDetailMode,
        isSharedChatReaderOpen: () -> Bool
    ) -> PanelKeyRoute {
        if subAgentDetailMode != .closed, key != .endOfInput {
            if let action = subAgentDetailAction(for: key, mode: subAgentDetailMode) {
                return .subAgentDetail(action)
            }
            if subAgentDetailMode == .list {
                return .swallowedBySubAgentList
            }
        }
        guard isSharedChatReaderOpen(),
              let action = sharedChatReaderAction(for: key) else {
            return .editor
        }
        return .sharedChatReader(action)
    }

    /// Navigation action of a key for the open shared-chat reader, or `nil`
    /// for a key it leaves to the draft.
    static func sharedChatReaderAction(for key: Key) -> TerminalSharedChatReaderAction? {
        switch key {
        case .up: .scrollUp
        case .down: .scrollDown
        case .left: .previousMessage
        case .right: .nextMessage
        case .home, .bufferStart: .firstMessage
        case .end, .bufferEnd: .lastMessage
        default: nil
        }
    }

    /// A consent prompt owns the TTY while panel reads report timeouts. Only
    /// that ownership condition invalidates the transient heuristic; ordinary
    /// polling timeouts never count as hold activity and leave it untouched.
    @discardableResult
    func invalidatePanelPressAndHoldForConsentIfNeeded() -> Bool {
        guard consentInputOwnership.isConsentActive else {
            return false
        }
        return withPanelLock { state in
            state.editor.resetPressAndHold()
        }
    }

    func editorContextLocked(state: State) -> TerminalPromptEditorContext {
        TerminalPromptEditorContext(
            history: state.history,
            suggestions: state.panelCommandSuggestions,
            // An agent's `/subagent` detail leaves the draft to the operator,
            // like the shared-chat reader: its panel mode is no overlay of the
            // prompt, so the completion menu stays. The modal agent list's
            // mode does count as one.
            isOverlayActive: state.panelOverlayOverride != nil
                && state.panelSubAgentDetailMode != .detail,
            isProcessing: state.panelIsProcessing,
            isSpeaking: state.panelIsSpeaking,
            supportsCompletions: true,
            clearsDraftOnCancel: true,
            supportsPressAndHold: state.panelSupportsPressAndHold
                && !state.panelSharedChatReaderIsOpen
                && state.panelSubAgentDetailMode == .closed
        )
    }
}
