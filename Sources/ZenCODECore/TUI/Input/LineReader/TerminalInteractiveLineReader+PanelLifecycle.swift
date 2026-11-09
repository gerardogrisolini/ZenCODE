//
//  TerminalInteractiveLineReader+PanelLifecycle.swift
//  ZenCODE
//

import Foundation

extension TerminalInteractiveLineReader {
    /// Ownership of the terminal by the input panel.
    ///
    /// Only one code path may hold the TTY at a time, and the transient states
    /// matter as much as the settled ones: a stop is not done when it clears
    /// the panel task, it is done when it has awaited the loop task *and* restored
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
        /// The panel loop owns the terminal; ``PanelLifecycle/task`` is its task.
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

    /// Who owns the terminal through the input panel, as a pure value.
    ///
    /// ``State`` owns one instance under the reader's mutex, next to the draft,
    /// so a transition and the panel state it goes with change in one critical
    /// section. The transitions never lock, await or resume: each returns what
    /// the reader must do once the lock is released (the parked callers to
    /// resume) or, for the stop claim, the read token the reader cancels in that
    /// same critical section. Raw mode, the loop task, the status bar, the draft
    /// and the dictation stay with the reader.
    struct PanelLifecycle<Waiter> {
        private(set) var phase: PanelLifecycleState = .idle
        /// The running loop's task, published by ``finishStart(task:)``.
        private(set) var task: Task<Void, Never>?
        /// Callers parked until the in-flight start or stop reaches a settled state.
        private(set) var transitionWaiters: [Waiter] = []
        /// Cancellation token of the panel loop's in-flight blocking read. Stopping
        /// the panel cancels it so the loop unwinds at once instead of waiting out
        /// the current read timeout while the caller awaits the task.
        private(set) var readToken: TerminalBlockingReadToken?

        /// Claims the panel for a new start. Only a settled, idle panel can be
        /// claimed; the claim moves it to `starting`.
        mutating func admitStart() -> PanelStartAdmission {
            switch phase {
            case .running, .starting:
                // Another reader already owns (or is acquiring) the terminal.
                return .alreadyActive
            case .stopping:
                return .transitionInFlight
            case .idle:
                phase = .starting
                return .admitted
            }
        }

        /// Publishes the running panel and returns the callers waiting on the start.
        mutating func finishStart(task: Task<Void, Never>) -> [Waiter] {
            self.task = task
            phase = .running
            return takeTransitionWaiters()
        }

        /// Rolls a failed start back to `idle`, so a later start (or a stop) is
        /// not blocked behind a transition that will never complete, and returns
        /// the callers waiting on it.
        mutating func abandonStart() -> [Waiter] {
            task = nil
            phase = .idle
            return takeTransitionWaiters()
        }

        /// Marks the panel `stopping` and hands the stop the loop task it must
        /// join and the read token it must cancel. Returns `nil` while another
        /// transition still owns the panel.
        mutating func claimForStop() -> (task: Task<Void, Never>?, readToken: TerminalBlockingReadToken?)? {
            switch phase {
            case .starting, .stopping:
                return nil
            case .idle, .running:
                break
            }

            let claim = (task: task, readToken: readToken)
            phase = .stopping
            task = nil
            readToken = nil
            return claim
        }

        /// Settles a stop to `idle` and returns the callers waiting on it.
        mutating func finishStop() -> [Waiter] {
            task = nil
            phase = .idle
            return takeTransitionWaiters()
        }

        /// Parks `waiter` until the in-flight transition settles. Returns `true`,
        /// keeping nothing, when no transition is in flight: the caller resumes
        /// `waiter` at once.
        mutating func registerTransitionWaiter(_ waiter: Waiter) -> Bool {
            switch phase {
            case .idle, .running:
                return true
            case .starting, .stopping:
                transitionWaiters.append(waiter)
                return false
            }
        }

        /// Installs the token of a loop that starts reading and returns the one
        /// it replaces, which the caller cancels.
        mutating func replaceReadToken(with token: TerminalBlockingReadToken) -> TerminalBlockingReadToken? {
            let previous = readToken
            readToken = token
            return previous
        }

        /// Forgets `token` if it is still the installed one.
        mutating func clearReadToken(_ token: TerminalBlockingReadToken) {
            if readToken === token {
                readToken = nil
            }
        }

        private mutating func takeTransitionWaiters() -> [Waiter] {
            let waiters = transitionWaiters
            transitionWaiters.removeAll()
            return waiters
        }
    }
}

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
    /// Waiting is what makes the hand-over safe: a `nil` panel task says only
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
        let (admission, dictationEnded) = withPanelLock { state -> (PanelStartAdmission, (@Sendable () -> Void)?) in
            let admission = state.panelLifecycle.admitStart()
            guard admission == .admitted else {
                return (admission, nil)
            }

            state.panelStatusBar = statusBar
            state.panelCommandSuggestions = commandSuggestions
            if preservingState {
                state.editor.resetPressAndHold()
                state.panelCommandSuggestionIndex = commandSuggestions.isEmpty
                    ? 0
                    : min(state.panelCommandSuggestionIndex, commandSuggestions.count - 1)
                return (.admitted, nil)
            }
            state.editor = TerminalPromptEditor()
            state.panelOverlayOverride = nil
            return (.admitted, endVoiceDictationLocked(state: &state))
        }
        dictationEnded?()
        return admission
    }

    /// Publishes the running panel and releases anyone waiting on the start.
    func finishPanelStart(task: Task<Void, Never>) {
        let waiters = withPanelLock { state in
            state.panelLifecycle.finishStart(task: task)
        }
        waiters.forEach { $0.resume() }
    }

    /// Rolls a failed start back to `idle` so a later start (or a stop) is not
    /// blocked behind a transition that will never complete.
    func abandonPanelStart() {
        let waiters = withPanelLock { state -> [PanelWaiter] in
            let waiters = state.panelLifecycle.abandonStart()
            state.panelStatusBar = nil
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    public func stopPanelInput(clearPanel: Bool = true) async {
        let stopState = await claimPanelForStop()

        stopState.task?.cancel()
        await stopState.task?.value
        let revision = invalidatePanelRendersForStop()
        if clearPanel {
            await stopState.statusBar?.clearInputPanel(revision: revision)
        }
        // The panel loop and its renderer are separate tasks. A preserving stop
        // cannot use a clear revision to fence the status bar, so wait until the
        // already-dequeued frame has finished before handing the terminal to a
        // consent prompt. Pending frames were discarded above for both modes.
        await awaitPanelRenderDrain()
        // Only now is the terminal provably free: the loop has left its blocking
        // read and the renderer can no longer write, so raw mode can be handed
        // back. The panel stays marked `stopping` until `finishPanelStop`, so no
        // successor can acquire the TTY before this restore has run.
        rawInput.restoreRawMode()
        finishPanelStop(clearPanel: clearPanel)
    }

    /// Detaches the stopped session from its status bar, discards its queued
    /// projection, and releases explicit refreshes whose revisions can no longer
    /// be applied. The immutable frame already owned by the renderer is joined by
    /// ``awaitPanelRenderDrain()`` before stop returns.
    private func invalidatePanelRendersForStop() -> UInt64 {
        let result = withPanelLock { state -> (revision: UInt64, waiters: [PanelWaiter]) in
            state.panelStatusBar = nil
            return state.panelRender.invalidateForStop()
        }
        result.waiters.forEach { $0.resume() }
        return result.revision
    }

    /// Waits out any in-flight transition, then marks the panel `stopping` and
    /// takes the state this teardown owns.
    ///
    /// A stop must not race a start either: during `starting` the successor has
    /// not published its task yet, so a stop would await `nil`, restore raw mode
    /// under the new reader, and leave it reading a cooked terminal.
    func claimPanelForStop() async -> (task: Task<Void, Never>?, statusBar: TerminalStatusBar?) {
        while true {
            if let claim = takePanelTaskForStop() {
                return claim
            }
            await awaitPanelTransition()
        }
    }

    /// Synchronous half of the stop claim. Returns `nil` while another
    /// transition still owns the panel.
    func takePanelTaskForStop() -> (task: Task<Void, Never>?, statusBar: TerminalStatusBar?)? {
        withPanelLock { state -> (task: Task<Void, Never>?, statusBar: TerminalStatusBar?)? in
            guard let claim = state.panelLifecycle.claimForStop() else {
                return nil
            }

            state.editor.resetPressAndHold()
            // Unblock the in-flight terminal read before awaiting the task, so
            // the stop does not wait out the remainder of the read window.
            claim.readToken?.cancel()
            return (task: claim.task, statusBar: state.panelStatusBar)
        }
    }

    func finishPanelStop(clearPanel: Bool) {
        let (dictationEnded, waiters) = withPanelLock { state -> (
            (@Sendable () -> Void)?,
            [PanelWaiter]
        ) in
            state.panelStatusBar = nil
            var dictationEnded: (@Sendable () -> Void)?
            if clearPanel {
                state.panelBuffer.removeAll()
                state.panelCursorIndex = 0
                state.panelOverlayOverride = nil
                state.panelCommandSuggestions.removeAll()
                state.panelCommandSuggestionIndex = 0
                state.historyIndex = nil
                state.draftBeforeHistory.removeAll()
                dictationEnded = endVoiceDictationLocked(state: &state)
            }
            return (dictationEnded, state.panelLifecycle.finishStop())
        }
        waiters.forEach { $0.resume() }
        dictationEnded?()
    }

    /// Suspends until the in-flight transition publishes a settled state.
    ///
    /// Registration happens under the same lock that settles the panel, so a
    /// transition completing between the check and the suspension cannot strand
    /// the waiter.
    private func awaitPanelTransition() async {
        await withCheckedContinuation { (continuation: PanelWaiter) in
            let isSettled = withPanelLock { state in
                state.panelLifecycle.registerTransitionWaiter(continuation)
            }
            if isSettled {
                continuation.resume()
            }
        }
    }
}
