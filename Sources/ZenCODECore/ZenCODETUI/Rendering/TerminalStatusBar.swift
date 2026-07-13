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
import Synchronization

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

/// Terminal rendering state is protected by `state`; Dispatch timers and signal handlers call back across concurrency domains.
public final class TerminalStatusBar: Sendable {
    struct InputPanelState {
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
        var spinnerTimer: DispatchSourceTimer?
        var resizeSignalSource: DispatchSourceSignal?
        var resizeGeneration = 0
        var isResizePending = false
        var inputPanelState: InputPanelState?
        var localExecAccessMode: AgentLocalExecAccessMode = .standard
        var latestModelID: String?
        var latestThinkingSelection: AgentThinkingSelection?
        var latestModelRuntime: String?
        var latestMetrics: DirectAgentGenerationMetrics?
        var latestContextWindow: DirectAgentContextWindowStatus?
        var latestSubscriptionUsage: DirectAgentSubscriptionUsageStatus?
        var latestGitStatusSummary: TerminalGitStatusSummary?
    }

    let isEnabled: Bool
    let output: FileHandle?
    let state = Mutex(State())
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
        state.withLock { state in
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
                startSpinnerTimerLocked(state: &state)
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    public func stop() {
        state.withLock { state in
            guard state.isStarted else {
                return
            }
            stopSpinnerTimerLocked(state: &state)
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
        suggestionLines: [String] = []
    ) {
        state.withLock { state in
            let boundedCursorIndex = min(max(0, cursorIndex), text.count)
            let hadInputPanel = state.inputPanelState != nil
            let oldReservedRows = state.isStarted ? reservedBottomRowsLocked(state: &state) : 0
            state.inputPanelState = InputPanelState(
                text: text,
                cursorIndex: boundedCursorIndex,
                modeText: modeText,
                helpText: helpText,
                compactHelpText: compactHelpText,
                suggestionLines: Array(suggestionLines.prefix(6))
            )
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
                clearReservedRowsLocked(state: &state, count: max(oldReservedRows, newReservedRows))
                writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
            }
            renderLocked(state: &state)
        }
    }
    
    public func clearInputPanel() {
        state.withLock { state in
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
    
    func beginRequest() {
        state.withLock { state in
            // Keep the last known context window, but do not carry C/P/G or
            // timing from the completed user turn into the next request.
            state.latestMetrics = nil
            guard state.isStarted else {
                return
            }
            renderLocked(state: &state)
        }
    }

    public func reset() {
        state.withLock { state in
            state.latestMetrics = nil
            state.latestContextWindow = nil
            state.latestModelID = nil
            state.latestThinkingSelection = nil
            state.latestModelRuntime = nil
            state.isProcessing = false
            state.spinnerIndex = 0
            stopSpinnerTimerLocked(state: &state)
            guard state.isStarted else {
                return
            }
            renderLocked(state: &state)
        }
    }
    
    public func setProcessing(_ isProcessing: Bool) {
        state.withLock { state in
            guard state.isProcessing != isProcessing else {
                return
            }
            state.isProcessing = isProcessing
            state.spinnerIndex = 0
            if isProcessing {
                startSpinnerTimerLocked(state: &state)
            } else {
                stopSpinnerTimerLocked(state: &state)
            }
            guard state.isStarted else {
                return
            }
            renderLocked(state: &state)
        }
    }

    public func update(localExecAccessMode: AgentLocalExecAccessMode) {
        state.withLock { state in
            state.localExecAccessMode = localExecAccessMode
            guard state.isStarted else {
                return
            }
            renderLocked(state: &state)
        }
    }
    
    @discardableResult
    public func update(modelID: String) -> Bool {
        state.withLock { state in
            if state.latestModelID != modelID {
                state.latestModelRuntime = nil
            }
            state.latestModelID = modelID
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(thinkingSelection: AgentThinkingSelection?) -> Bool {
        state.withLock { state in
            state.latestThinkingSelection = thinkingSelection
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(modelRuntime: String?) -> Bool {
        state.withLock { state in
            state.latestModelRuntime = Self.runtimeDisplayName(modelRuntime)
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(metrics: DirectAgentGenerationMetrics) -> Bool {
        state.withLock { state in
            state.latestMetrics = mergedMetrics(
                current: state.latestMetrics,
                update: metrics
            )
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(contextWindow: DirectAgentContextWindowStatus) -> Bool {
        state.withLock { state in
            state.latestContextWindow = contextWindow
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(subscriptionUsage: DirectAgentSubscriptionUsageStatus) -> Bool {
        state.withLock { state in
            guard subscriptionUsage.hasValues else {
                return false
            }
            state.latestSubscriptionUsage = subscriptionUsage
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    @discardableResult
    public func update(gitStatusSummary: TerminalGitStatusSummary?) -> Bool {
        state.withLock { state in
            state.latestGitStatusSummary = gitStatusSummary
            guard state.isStarted else {
                return false
            }
            renderLocked(state: &state)
            return true
        }
    }
    
    public func currentContextWindowStatus() -> DirectAgentContextWindowStatus? {
        state.withLock { state in
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
    }
    
    public func reservedRowsForOverlay() -> Int {
        state.withLock { state in
            guard state.isStarted else {
                return 0
            }
            return reservedBottomRowsLocked(state: &state)
        }
    }
    
}
