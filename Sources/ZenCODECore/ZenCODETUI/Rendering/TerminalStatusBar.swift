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

    struct State {
        var isStarted = false
        var row = 0
        var columns = 0
        var isProcessing = false
        var spinnerIndex = 0
        var spinnerTask: Task<Void, Never>?
        var spinnerGeneration = 0
        var resizeSignalSource: DispatchSourceSignal?
        var resizeTask: Task<Void, Never>?
        var resizeGeneration = 0
        var isResizePending = false
        var inputPanelRevision: UInt64 = 0
        var inputPanelState: InputPanelState?
        var localExecAccessMode: AgentLocalExecAccessMode = .standard
        var latestModelID: String?
        var latestThinkingSelection: AgentThinkingSelection?
        var latestModelRuntime: String?
        var latestMetrics: DirectAgentGenerationMetrics?
        var latestContextWindow: DirectAgentContextWindowStatus?
        var latestSubscriptionUsage: DirectAgentSubscriptionUsageStatus?
        var latestGitStatusSummary: TerminalGitStatusSummary?
        var gitStatusRefreshGeneration: UInt64 = 0
    }

    nonisolated let isEnabled: Bool
    let output: FileHandle?
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

    @discardableResult
    public func start() -> Bool {
        withOutputBatch {
            guard isEnabled, !state.isStarted, output != nil else {
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
        guard state.latestMetrics != nil else {
            return
        }
        // Keep the last known context window, but do not carry C/P/G or timing
        // from the completed user turn into the next request.
        state.latestMetrics = nil
        guard state.isStarted else {
            return
        }
        renderStatusLocked(state: &state)
    }

    public func reset() {
        state.latestMetrics = nil
        state.latestContextWindow = nil
        state.latestModelID = nil
        state.latestThinkingSelection = nil
        state.latestModelRuntime = nil
        state.isProcessing = false
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
            startSpinnerTaskLocked(state: &state)
        } else {
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
        state.latestModelRuntime = nil
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
    public func update(modelRuntime: String?) -> Bool {
        let displayName = Self.runtimeDisplayName(modelRuntime)
        guard state.latestModelRuntime != displayName else {
            return state.isStarted
        }
        state.latestModelRuntime = displayName
        guard state.isStarted else {
            return false
        }
        renderStatusLocked(state: &state)
        return true
    }

    @discardableResult
    public func update(metrics: DirectAgentGenerationMetrics) -> Bool {
        state.latestMetrics = mergedMetrics(
            current: state.latestMetrics,
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

}
