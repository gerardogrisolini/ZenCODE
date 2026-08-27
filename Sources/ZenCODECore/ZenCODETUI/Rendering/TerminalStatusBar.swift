//
//  TerminalStatusBar.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public struct TerminalGitStatusSummary: Equatable, Sendable {
    public static let zero = TerminalGitStatusSummary(
        changedFileCount: 0,
        additions: 0,
        deletions: 0
    )

    public let changedFileCount: Int
    public let additions: Int
    public let deletions: Int

    public init(changedFileCount: Int, additions: Int, deletions: Int) {
        self.changedFileCount = changedFileCount
        self.additions = additions
        self.deletions = deletions
    }

    public func adding(_ other: TerminalGitStatusSummary) -> TerminalGitStatusSummary {
        TerminalGitStatusSummary(
            changedFileCount: changedFileCount + other.changedFileCount,
            additions: additions + other.additions,
            deletions: deletions + other.deletions
        )
    }
}

/// Owns the terminal overlay state and serializes every redraw through actor isolation.
public actor TerminalStatusBar {
    struct InputPanelState: Equatable, Sendable {
        let text: String
        let cursorIndex: Int
        let modeText: String
        let helpText: String
        let compactHelpText: String?
        let suggestionLines: [String]
    }

    /// `DispatchSourceSignal` is annotated `Sendable` on Apple platforms but not
    /// in the Linux corelibs libdispatch. The resize signal source is created,
    /// resumed, cancelled, and released exclusively from this actor's isolation
    /// domain — the event handler hops back through `await` — so a thin
    /// `@unchecked Sendable` box restores cross-platform conformance without
    /// weakening the actor's invariants.
    struct ResizeSignalSourceBox: @unchecked Sendable {
        let source: any DispatchSourceSignal
    }

    struct State: Sendable {
        var isStarted = false
        var row = 0
        var columns = 0
        var isProcessing = false
        /// Instant when the current request started; drives the live elapsed-time
        /// fragment while processing. Updated display piggybacks on the spinner
        /// tick, so it adds no extra render traffic.
        var processingStartInstant: ContinuousClock.Instant?
        var spinnerIndex = 0
        var spinnerTask: Task<Void, Never>?
        var spinnerGeneration = 0
        var resizeSignalSource: ResizeSignalSourceBox?
        var resizeTask: Task<Void, Never>?
        var resizeGeneration = 0
        var isResizePending = false
        var inputPanelRevision: UInt64 = 0
        var inputPanelState: InputPanelState?
        var sharedChatReaderDock: TerminalSharedChatReaderDock?
        /// Identity of the observation that installed the dock. A completion
        /// from a retired stream may clear only its own overlay.
        var sharedChatReaderObservationID: UUID?
        var localExecAccessMode: AgentLocalExecAccessMode = .standard
        var latestModelID: String?
        var latestThinkingSelection: AgentThinkingSelection?
        var latestMetrics: DirectAgentGenerationMetrics?
        var shouldReplaceMetricsOnNextUpdate = false
        var latestContextWindow: DirectAgentContextWindowStatus?
        var latestSubscriptionUsage: DirectAgentSubscriptionUsageStatus?
        var latestGitStatusSummary: TerminalGitStatusSummary?
        var gitStatusRefreshGeneration: UInt64 = 0
        /// Cache of the last status-only render sequence written to the terminal.
        /// When the next `renderStatusLocked` produces an identical sequence, the
        /// write is skipped to avoid redundant redraw traffic (spinner ticks, which
        /// always change the frame, are unaffected; this catches identical metric /
        /// git / context-window updates).
        var lastStatusRender: String?
    }

    nonisolated let isEnabled: Bool
    let output: FileHandle?
    /// Injectable write sink used in place of `output?.writeString` when set.
    /// Production code leaves this nil; tests supply a closure to observe output.
    var outputSink: (@Sendable (String) -> Void)?
    /// A one-way notification into the terminal runtime FIFO. It is deliberately
    /// not a callback into the input actor: resize commits the visual collapse
    /// first, then the FIFO serializes ownership of the reader/input states.
    var sharedChatReaderCollapseHandler: (@Sendable (UUID?) async -> Void)?
    var state = State()
    var outputBatchDepth = 0
    var batchedOutput = ""

    static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let inputPanelChromeRows = 3
    static let minimumScrollableRows = 2
    static let standaloneStatusRows = 3
    static let attachedStatusRows = 2

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.output = Self.openControllingTerminal()
    }

    /// Internal initializer for tests: accepts a write sink closure instead of
    /// opening the controlling terminal. When `outputSink` is set, all writes go
    /// through the closure, allowing tests to assert on emitted sequences.
    init(isEnabled: Bool, outputSink: @escaping @Sendable (String) -> Void) {
        self.isEnabled = isEnabled
        self.output = nil
        self.outputSink = outputSink
    }

    @discardableResult
    public func start() -> Bool {
        withOutputBatch {
            guard isEnabled, !state.isStarted, (output != nil || outputSink != nil) else {
                return state.isStarted
            }
            guard configureTerminalLocked(state: &state) else {
                return false
            }
            state.isStarted = true
            writeLocked("\u{1B}[?25l")
            startResizeSignalSourceLocked(state: &state)
            if state.isProcessing {
                startSpinnerTaskLocked(state: &state)
            }
            renderLocked(state: &state)
            return true
        }
    }

    public func stop() {
        withOutputBatch {
            guard state.isStarted else {
                return
            }
            stopSpinnerTaskLocked(state: &state)
            stopResizeSignalSourceLocked(state: &state)
            clearLocked(state: &state)
            writeLocked("\u{1B}[r\u{1B}[?25h")
            state.lastStatusRender = nil
            state.isStarted = false
        }
    }

    public func updateInputPanel(
        text: String,
        cursorIndex: Int,
        modeText: String,
        helpText: String,
        compactHelpText: String? = nil,
        suggestionLines: [String] = [],
        revision: UInt64? = nil
    ) {
        withOutputBatch {
            guard acceptInputPanelRevision(revision, state: &state) else {
                return
            }
            let boundedCursorIndex = min(max(0, cursorIndex), text.count)
            let nextInputPanelState = InputPanelState(
                text: text,
                cursorIndex: boundedCursorIndex,
                modeText: modeText,
                helpText: helpText,
                compactHelpText: compactHelpText,
                suggestionLines: Array(suggestionLines.prefix(6))
            )
            guard state.inputPanelState != nextInputPanelState else {
                return
            }

            let hadInputPanel = state.inputPanelState != nil
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            state.inputPanelState = nextInputPanelState
            guard state.isStarted else {
                return
            }
            let newReservedRows = reservedBottomRowsLocked(state: &state)
            if !hadInputPanel || oldReservedRows != newReservedRows {
                if hadInputPanel, newReservedRows > oldReservedRows {
                    scrollOutputRegionUpLocked(
                        state: &state,
                        by: newReservedRows - oldReservedRows,
                        reservedRows: oldReservedRows
                    )
                }
                clearReservedRowsLocked(
                    state: &state,
                    count: max(oldReservedRows, newReservedRows)
                )
                writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            }
            renderLocked(state: &state)
        }
    }

    /// Shows or refreshes the shared-chat reader inside the existing bottom panel.
    /// No raw-input loop, terminal ownership, or alternate screen is involved.
    func setSharedChatReader(
        entries: [TerminalSharedChatReaderEntry],
        unreadCount: Int,
        isExpanded: Bool,
        selection: TerminalSharedChatReaderDock.Selection = .preserve,
        observationID: UUID? = nil,
        availableTranscriptGapRows: Int = 0
    ) {
        withOutputBatch {
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            if entries.isEmpty, !isExpanded {
                // A closed reader with no history has no visible state. An open
                // empty reader is retained so Ctrl+Y can still paint its compact
                // "0 messages" header and toggle it closed again.
                state.sharedChatReaderDock = nil
            } else {
                var dock = state.sharedChatReaderDock ?? TerminalSharedChatReaderDock()
                dock.replace(entries: entries, unreadCount: unreadCount, selection: selection)
                dock.isExpanded = isExpanded
                state.sharedChatReaderDock = dock
            }
            if let observationID {
                state.sharedChatReaderObservationID = observationID
            }
            guard state.isStarted else { return }
            let newReservedRows = reservedBottomRowsLocked(state: &state)
            if newReservedRows > oldReservedRows {
                scrollOutputRegionUpLocked(
                    state: &state,
                    by: max(
                        0,
                        newReservedRows - oldReservedRows - availableTranscriptGapRows
                    ),
                    reservedRows: oldReservedRows
                )
            }
            clearReservedRowsLocked(state: &state, count: max(oldReservedRows, newReservedRows))
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
        }
    }

    /// Removes the overlay when its observation is no longer active.
    func removeSharedChatReader() {
        removeSharedChatReader(ownedBy: nil)
    }

    /// Removes a dock only when it still belongs to the terminating observer.
    /// This makes stream completion safe to handle directly from its producer,
    /// while a replacement attachment is concurrently installing its compact
    /// dock on this actor.
    func removeSharedChatReader(ownedBy observationID: UUID?) {
        withOutputBatch {
            if let observationID,
               state.sharedChatReaderObservationID != observationID {
                return
            }
            guard state.sharedChatReaderDock != nil || state.sharedChatReaderObservationID != nil else { return }
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            state.sharedChatReaderDock = nil
            state.sharedChatReaderObservationID = nil
            guard state.isStarted else { return }
            clearReservedRowsLocked(state: &state, count: oldReservedRows)
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
        }
    }

    /// Authoritatively returns the active observation's reader to its compact
    /// dock. Unlike removal this retains the entries, unread count and compact
    /// header; unlike the resize producer it is safe to run after a suspended
    /// refresh has attempted a stale re-expansion.
    ///
    /// This intentionally does not call `sharedChatReaderCollapseHandler`.
    /// That handler is producer-to-FIFO delivery only, and notifying from the
    /// FIFO reconciliation would create a callback cycle.
    func collapseSharedChatReader(ownedBy observationID: UUID) {
        withOutputBatch {
            guard state.sharedChatReaderObservationID == observationID,
                  var dock = state.sharedChatReaderDock,
                  dock.isExpanded else {
                return
            }
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            dock.isExpanded = false
            state.sharedChatReaderDock = dock
            guard state.isStarted else { return }
            let newReservedRows = reservedBottomRowsLocked(state: &state)
            clearReservedRowsLocked(state: &state, count: max(oldReservedRows, newReservedRows))
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
        }
    }

    /// Installs the one-way delivery used when a productive resize makes the
    /// expanded reader impossible to display. The handler should enqueue work
    /// only; calling this actor back from it would create a resize callback loop.
    func setSharedChatReaderCollapseHandler(
        _ handler: (@Sendable (UUID?) async -> Void)?
    ) {
        sharedChatReaderCollapseHandler = handler
    }

    /// Expands the docked reader as one indivisible status-bar transaction.
    ///
    /// Viewport validation, state commit and repaint happen in a single actor
    /// operation with no suspension point between them, so a concurrent
    /// SIGWINCH resize is observed either entirely before or entirely after the
    /// commit and can no longer land between a separate "can expand" check and
    /// the write that depended on it.
    ///
    /// Returns `true` when opening committed a visible reader state. With
    /// messages, at least one payload row must be paintable before unread state
    /// may be consumed. With no messages, the compact `0 messages` header (or
    /// its minimum-height mode-row fallback) is itself the visible open state.
    @discardableResult
    func expandSharedChatReader(
        entries: [TerminalSharedChatReaderEntry],
        unreadCount: Int,
        selection: TerminalSharedChatReaderDock.Selection = .preserve,
        observationID: UUID? = nil,
        availableTranscriptGapRows: Int = 0
    ) -> Bool {
        withOutputBatch {
            let previousDock = state.sharedChatReaderDock
            let previousObservationID = state.sharedChatReaderObservationID
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            var dock = previousDock ?? TerminalSharedChatReaderDock()
            dock.replace(entries: entries, unreadCount: unreadCount, selection: selection)
            dock.isExpanded = true
            state.sharedChatReaderDock = dock
            if let observationID {
                state.sharedChatReaderObservationID = observationID
            }
            // Measure the candidate layout rather than a previous one: this is
            // the geometry the commit below would paint. A pending resize is a
            // known-stale measurement whose render is suppressed. A populated
            // reader therefore needs payload space; an empty reader only needs
            // the input panel where its compact open state is rendered.
            let payloadRows = min(
                sharedChatReaderViewportRowsLocked(state: &state),
                dock.rows(width: statusBoxContentWidthLocked(state: &state)).count
            )
            let hasVisibleOpenState = entries.isEmpty
                ? state.inputPanelState != nil
                : payloadRows >= 1
            guard state.isStarted, !state.isResizePending, hasVisibleOpenState else {
                state.sharedChatReaderDock = previousDock
                state.sharedChatReaderObservationID = previousObservationID
                return false
            }
            let newReservedRows = reservedBottomRowsLocked(state: &state)
            if newReservedRows > oldReservedRows {
                scrollOutputRegionUpLocked(
                    state: &state,
                    by: max(
                        0,
                        newReservedRows - oldReservedRows - availableTranscriptGapRows
                    ),
                    reservedRows: oldReservedRows
                )
            }
            clearReservedRowsLocked(
                state: &state,
                count: max(oldReservedRows, newReservedRows)
            )
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
            return true
        }
    }

    func navigateSharedChatReader(_ action: TerminalSharedChatReaderAction) {
        withOutputBatch {
            guard var dock = state.sharedChatReaderDock else { return }
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            let width = statusBoxContentWidthLocked(state: &state)
            dock.navigate(action, viewportRows: sharedChatReaderViewportRowsLocked(state: &state), width: width)
            state.sharedChatReaderDock = dock
            guard state.isStarted else { return }
            let newReservedRows = reservedBottomRowsLocked(state: &state)
            if newReservedRows > oldReservedRows {
                scrollOutputRegionUpLocked(
                    state: &state,
                    by: newReservedRows - oldReservedRows,
                    reservedRows: oldReservedRows
                )
            }
            clearReservedRowsLocked(state: &state, count: max(oldReservedRows, newReservedRows))
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
        }
    }

    public func clearInputPanel(revision: UInt64? = nil) {
        withOutputBatch {
            guard acceptInputPanelRevision(revision, state: &state) else {
                return
            }
            guard state.inputPanelState != nil else {
                return
            }
            let oldReservedRows = reservedBottomRowsLocked(state: &state)
            state.inputPanelState = nil
            guard state.isStarted else {
                return
            }
            clearReservedRowsLocked(state: &state, count: oldReservedRows)
            writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            renderLocked(state: &state)
        }
    }

    func acceptInputPanelRevision(
        _ revision: UInt64?,
        state: inout State
    ) -> Bool {
        guard let revision else {
            state.inputPanelRevision &+= 1
            return true
        }
        guard revision >= state.inputPanelRevision else {
            return false
        }
        state.inputPanelRevision = revision
        return true
    }

    func beginRequest() {
        state.shouldReplaceMetricsOnNextUpdate = true
    }

    public func reset() {
        state.latestMetrics = nil
        state.shouldReplaceMetricsOnNextUpdate = false
        state.latestContextWindow = nil
        state.latestModelID = nil
        state.latestThinkingSelection = nil
        state.isProcessing = false
        state.processingStartInstant = nil
        state.spinnerIndex = 0
        stopSpinnerTaskLocked(state: &state)
        guard state.isStarted else {
            return
        }
        renderStatusLocked(state: &state)
    }

    public func setProcessing(_ isProcessing: Bool) {
        guard state.isProcessing != isProcessing else {
            return
        }
        state.isProcessing = isProcessing
        state.spinnerIndex = 0
        if isProcessing {
            state.processingStartInstant = ContinuousClock.now
            startSpinnerTaskLocked(state: &state)
        } else {
            state.processingStartInstant = nil
            stopSpinnerTaskLocked(state: &state)
        }
        guard state.isStarted else {
            return
        }
        renderStatusLocked(state: &state)
    }

    public func update(localExecAccessMode: AgentLocalExecAccessMode) {
        guard state.localExecAccessMode != localExecAccessMode else {
            return
        }
        state.localExecAccessMode = localExecAccessMode
        guard state.isStarted else {
            return
        }
        renderStatusLocked(state: &state)
    }

    @discardableResult
    public func update(modelID: String) -> Bool {
        guard state.latestModelID != modelID else {
            return state.isStarted
        }
        state.latestModelID = modelID
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(thinkingSelection: AgentThinkingSelection?) -> Bool {
        guard state.latestThinkingSelection != thinkingSelection else {
            return state.isStarted
        }
        state.latestThinkingSelection = thinkingSelection
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(metrics: DirectAgentGenerationMetrics) -> Bool {
        let currentMetrics = state.shouldReplaceMetricsOnNextUpdate ? nil : state.latestMetrics
        state.shouldReplaceMetricsOnNextUpdate = false
        state.latestMetrics = mergedMetrics(
            current: currentMetrics,
            update: metrics
        )
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(contextWindow: DirectAgentContextWindowStatus) -> Bool {
        state.latestContextWindow = contextWindow
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(subscriptionUsage: DirectAgentSubscriptionUsageStatus) -> Bool {
        guard subscriptionUsage.hasValues else {
            return false
        }
        state.latestSubscriptionUsage = subscriptionUsage
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(gitStatusSummary: TerminalGitStatusSummary?) -> Bool {
        guard state.latestGitStatusSummary != gitStatusSummary else {
            return state.isStarted
        }
        state.latestGitStatusSummary = gitStatusSummary
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    func beginGitStatusRefresh() -> UInt64 {
        state.gitStatusRefreshGeneration &+= 1
        return state.gitStatusRefreshGeneration
    }

    @discardableResult
    func update(
        gitStatusSummary: TerminalGitStatusSummary?,
        refreshGeneration: UInt64
    ) -> Bool {
        guard refreshGeneration == state.gitStatusRefreshGeneration else {
            return false
        }
        return update(gitStatusSummary: gitStatusSummary)
    }

    public func currentContextWindowStatus() -> DirectAgentContextWindowStatus? {
        if let latestContextWindow = state.latestContextWindow {
            return latestContextWindow
        }
        guard let latestModelID = state.latestModelID else {
            return nil
        }
        return DirectAgentContextWindowStatus(
            usedTokens: state.latestMetrics?.totalTokenCount,
            maxTokens: nil,
            modelID: latestModelID,
            isApproximate: true
        )
    }

    public func reservedRowsForOverlay() -> Int {
        guard state.isStarted, state.row > 0, state.columns > 0 else {
            return 0
        }
        return reservedBottomRowsLocked(state: &state)
    }

    /// Returns the number of physical rows in the active scrolling region.
    ///
    /// A transcript block may be replaced in place only when it fits in this
    /// region. Once it has scrolled beyond the top margin, a cursor-up/erase
    /// rewrite cannot distinguish its remaining rows from the transcript and
    /// could continue into this overlay.
    func scrollableOutputRowCapacity() -> Int? {
        guard state.isStarted, state.row > 0, state.columns > 0 else {
            return nil
        }
        return max(0, state.row - reservedBottomRowsLocked(state: &state))
    }

    // MARK: - Test support

    /// Configures terminal geometry and optional status fields without rendering,
    /// so tests can control initial state before exercising the render cache.
    func configureForTesting(
        row: Int = 24,
        columns: Int = 100,
        modelID: String? = nil,
        isProcessing: Bool = false,
        isResizePending: Bool = false
    ) {
        state.isStarted = true
        state.row = row
        state.columns = columns
        state.latestModelID = modelID
        state.isProcessing = isProcessing
        state.isResizePending = isResizePending
    }

    /// Renders the status-only overlay using the actor's current state. Exposed
    /// for testing the render cache (identical renders must be suppressed).
    func renderStatusOverlay() {
        renderStatusLocked(state: &state)
    }

    /// Renders the full overlay (input panel + status) using the actor's current
    /// state. Exposed for testing cache invalidation on full renders.
    func renderOverlay() {
        renderLocked(state: &state)
    }

}
