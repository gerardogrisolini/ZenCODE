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
#if canImport(os)
import os
#endif

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

/// Terminal rendering state is protected by `lock`; Dispatch timers and signal handlers call back across concurrency domains.
public final class TerminalStatusBar: @unchecked Sendable {
    struct InputPanelState {
        let text: String
        let cursorIndex: Int
        let modeText: String
        let helpText: String
        let suggestionLines: [String]
    }
    
    let isEnabled: Bool
    let output: FileHandle?
    let lock = OSAllocatedUnfairLock()
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
    var latestModelID: String?
    var latestThinkingSelection: AgentThinkingSelection?
    var latestModelRuntime: String?
    var latestMetrics: DirectAgentGenerationMetrics?
    var latestContextWindow: DirectAgentContextWindowStatus?
    var latestSubscriptionUsage: DirectAgentSubscriptionUsageStatus?
    var latestGitStatusSummary: TerminalGitStatusSummary?
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
        lock.lock()
        defer { lock.unlock() }
        
        guard isEnabled, !isStarted, output != nil else {
            return isStarted
        }
        guard configureTerminalLocked() else {
            return false
        }
        isStarted = true
        writeLocked("\u{1B}[?25l")
        startResizeSignalSourceLocked()
        if isProcessing {
            startSpinnerTimerLocked()
        }
        renderLocked()
        return true
    }
    
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isStarted else {
            return
        }
        stopSpinnerTimerLocked()
        stopResizeSignalSourceLocked()
        clearLocked()
        writeLocked("\u{1B}[r\u{1B}[?25h")
        isStarted = false
    }
    
    public func updateInputPanel(
        text: String,
        cursorIndex: Int,
        modeText: String,
        helpText: String,
        suggestionLines: [String] = []
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        let boundedCursorIndex = min(max(0, cursorIndex), text.count)
        let hadInputPanel = inputPanelState != nil
        let oldReservedRows = isStarted ? reservedBottomRowsLocked() : 0
        inputPanelState = InputPanelState(
            text: text,
            cursorIndex: boundedCursorIndex,
            modeText: modeText,
            helpText: helpText,
            suggestionLines: Array(suggestionLines.prefix(6))
        )
        guard isStarted else {
            return
        }
        let newReservedRows = reservedBottomRowsLocked()
        if !hadInputPanel || oldReservedRows != newReservedRows {
            if hadInputPanel, newReservedRows > oldReservedRows {
                scrollOutputRegionUpLocked(
                    by: newReservedRows - oldReservedRows,
                    reservedRows: oldReservedRows
                )
            }
            clearReservedRowsLocked(count: max(oldReservedRows, newReservedRows))
            writeScrollRegionLocked(moveCursorToPrompt: true)
        }
        renderLocked()
    }
    
    public func clearInputPanel() {
        lock.lock()
        defer { lock.unlock() }
        
        guard inputPanelState != nil else {
            return
        }
        let oldReservedRows = reservedBottomRowsLocked()
        inputPanelState = nil
        guard isStarted else {
            return
        }
        clearReservedRowsLocked(count: oldReservedRows)
        writeScrollRegionLocked(moveCursorToPrompt: true)
        renderLocked()
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        latestMetrics = nil
        latestContextWindow = nil
        latestModelID = nil
        latestThinkingSelection = nil
        latestModelRuntime = nil
        isProcessing = false
        spinnerIndex = 0
        stopSpinnerTimerLocked()
        guard isStarted else {
            return
        }
        renderLocked()
    }
    
    public func setProcessing(_ isProcessing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        
        guard self.isProcessing != isProcessing else {
            return
        }
        self.isProcessing = isProcessing
        spinnerIndex = 0
        if isProcessing {
            startSpinnerTimerLocked()
        } else {
            stopSpinnerTimerLocked()
        }
        guard isStarted else {
            return
        }
        renderLocked()
    }
    
    @discardableResult
    public func update(modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if latestModelID != modelID {
            latestModelRuntime = nil
        }
        latestModelID = modelID
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(thinkingSelection: AgentThinkingSelection?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        latestThinkingSelection = thinkingSelection
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(modelRuntime: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        latestModelRuntime = Self.runtimeDisplayName(modelRuntime)
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(metrics: DirectAgentGenerationMetrics) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        latestMetrics = mergedMetrics(
            current: latestMetrics,
            update: metrics
        )
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(contextWindow: DirectAgentContextWindowStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        latestContextWindow = contextWindow
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(subscriptionUsage: DirectAgentSubscriptionUsageStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard subscriptionUsage.hasValues else {
            return false
        }
        latestSubscriptionUsage = subscriptionUsage
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    @discardableResult
    public func update(gitStatusSummary: TerminalGitStatusSummary?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        latestGitStatusSummary = gitStatusSummary
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }
    
    public func currentContextWindowStatus() -> DirectAgentContextWindowStatus? {
        lock.lock()
        defer { lock.unlock() }
        
        if let latestContextWindow {
            return latestContextWindow
        }
        guard let latestModelID else {
            return nil
        }
        return DirectAgentContextWindowStatus(
            usedTokens: latestMetrics?.totalTokenCount,
            maxTokens: nil,
            modelID: latestModelID,
            isApproximate: true
        )
    }
    
    public func reservedRowsForOverlay() -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        guard isStarted else {
            return 0
        }
        return reservedBottomRowsLocked()
    }
    
}
