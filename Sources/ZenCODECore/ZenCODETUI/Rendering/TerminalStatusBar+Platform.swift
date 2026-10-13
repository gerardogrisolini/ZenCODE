//
//  TerminalStatusBar+Platform.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
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

extension TerminalStatusBar {
    func startSpinnerTaskLocked(state: inout State) {
        guard state.isStarted, state.spinnerTask == nil else {
            return
        }
        state.spinnerGeneration &+= 1
        let generation = state.spinnerGeneration
        state.spinnerTask = Task(name: "ZenCODE.TUI.status-spinner") { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                await self.advanceSpinner(generation: generation)
            }
        }
    }

    func stopSpinnerTaskLocked(state: inout State) {
        state.spinnerGeneration &+= 1
        state.spinnerTask?.cancel()
        state.spinnerTask = nil
    }

    func advanceSpinner(generation: Int) {
        guard state.isStarted,
              state.isProcessing,
              generation == state.spinnerGeneration else {
            return
        }
        state.spinnerIndex = (state.spinnerIndex + 1) % Self.spinnerFrames.count
        renderStatusLocked(state: &state)
    }
    
    func startResizeSignalSourceLocked(state: inout State) {
        guard state.resizeSignalSource == nil else {
            return
        }
        let subscription = TerminalResizeCoordinator.shared.subscribe { [weak self] in
            Task(name: "ZenCODE.TUI.terminal-resize-signal") {
                await self?.scheduleTerminalResize()
            }
        }
        state.resizeSignalSource = ResizeSignalSourceBox(subscription: subscription)
    }
    
    func stopResizeSignalSourceLocked(state: inout State) {
        state.resizeGeneration &+= 1
        state.isResizePending = false
        state.resizeTask?.cancel()
        state.resizeTask = nil
        state.resizeSignalSource?.subscription.cancel()
        state.resizeSignalSource = nil
    }
    
    func scheduleTerminalResize() {
        guard state.isStarted else {
            return
        }
        state.resizeGeneration += 1
        state.isResizePending = true
        let generation = state.resizeGeneration
        state.resizeTask?.cancel()
        state.resizeTask = Task(name: "ZenCODE.TUI.terminal-resize") { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else {
                return
            }
            await self.handleTerminalResize(generation: generation)
        }
    }

    func handleTerminalResize(generation: Int) async {
        let fileDescriptor = output?.fileDescriptor ?? 1
        guard let geometry = Self.currentTerminalGeometry(fileDescriptor: fileDescriptor) else {
            await handleTerminalResize(generation: generation, geometry: nil)
            return
        }
        await handleTerminalResize(generation: generation, geometry: geometry)
    }

    /// Explicit geometry seam for independent resize tests. Modal surfaces are
    /// rebuilt by the same compositor commit as the footer.
    func handleTerminalResize(
        generation: Int,
        geometry: (rows: Int, columns: Int)?
    ) async {
        var collapsedObservationID: UUID?
        var collapseHandler: (@Sendable (UUID?) async -> Void)?
        withOutputBatch {
            guard state.isStarted, generation == state.resizeGeneration else {
                return
            }
            state.resizeTask = nil
            guard let geometry,
                  refreshTerminalGeometryLocked(state: &state, geometry: geometry)
            else {
                state.isResizePending = false
                TerminalResizeCoordinator.shared.publishLayout(reservedBottomRows: nil)
                return
            }
            state.isResizePending = false
            // The compact header alone is not a reader viewport. Collapse the
            // dock before repainting whenever the new geometry has no payload
            // row, then let the runtime FIFO close its matching input/buffer
            // reader states. Keeping the dock preserves its unread badge.
            if var dock = state.sharedChatReaderDock, dock.isExpanded {
                let payloadRows = sharedChatReaderViewportRowsLocked(state: &state)
                if payloadRows < 1 {
                    dock.isExpanded = false
                    state.sharedChatReaderDock = dock
                    collapsedObservationID = state.sharedChatReaderObservationID
                    collapseHandler = sharedChatReaderCollapseHandler
                }
            }
            TerminalResizeCoordinator.shared.publishLayout(
                reservedBottomRows: reservedBottomRowsLocked(state: &state)
            )
            renderLocked(state: &state)
        }
        if let collapsedObservationID {
            await collapseHandler?(collapsedObservationID)
        }
    }

    /// Test seam for resize lifecycle tests; production obtains geometry from
    /// the controlling terminal before reaching the shared implementation.
    func handleTerminalResizeForTesting(
        generation: Int = 0,
        rows: Int,
        columns: Int
    ) async {
        await handleTerminalResize(
            generation: generation,
            geometry: (rows: rows, columns: columns)
        )
    }
    
    static func currentTerminalGeometry(
        fileDescriptor: Int32
    ) -> (rows: Int, columns: Int)? {
        var size = winsize()
        if ioctl(fileDescriptor, UInt(TIOCGWINSZ), &size) == 0,
           size.ws_row > 0,
           size.ws_col > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        
        let environment = ProcessInfo.processInfo.environment
        guard let rows = positiveInt(environment["LINES"]),
              let columns = positiveInt(environment["COLUMNS"]) else {
            return defaultGeometryIfReasonable()
        }
        return (rows, columns)
    }
    
    static func openControllingTerminal() -> FileHandle? {
        if AgentOutput.standardErrorIsTerminal {
            return AgentOutput.standardError
        }
        
        let terminalFileDescriptor = open("/dev/tty", O_WRONLY | O_NOCTTY)
        if terminalFileDescriptor >= 0 {
            return FileHandle(fileDescriptor: terminalFileDescriptor, closeOnDealloc: true)
        }
        
        return nil
    }
    
    /// Writes text to the terminal output. Uses the injected `outputSink` when
    /// set (testing), otherwise writes to the controlling-terminal FileHandle.
    func performOutput(_ text: String) {
        TerminalOutputSynchronization.write(text, output: output, sink: outputSink)
    }

    func writeLocked(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        if outputBatchDepth > 0 {
            batchedOutput += text
        } else {
            performOutput(text)
        }
    }

    func withOutputBatch<T>(_ body: () -> T) -> T {
        // A resize publishes the new reservation inside body. Keep that commit
        // and the physical flush under the same lock as menu cleanup/repaint:
        // an overlay must never paint from the new layout before this batch.
        TerminalOutputSynchronization.withTransaction {
            outputBatchDepth += 1
            defer {
                outputBatchDepth -= 1
                if outputBatchDepth == 0, !batchedOutput.isEmpty {
                    let text = batchedOutput
                    batchedOutput.removeAll(keepingCapacity: true)
                    performOutput(text)
                }
            }
            return body()
        }
    }
    
    static func positiveInt(_ rawValue: String?) -> Int? {
        guard let value = rawValue
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              value > 0 else {
            return nil
        }
        return value
    }
    
    static func defaultGeometryIfReasonable() -> (rows: Int, columns: Int)? {
        // Some pseudo-terminals support ANSI scrolling but do not report size
        // through ioctl. Keep a conservative default so the status line still
        // becomes persistent instead of degrading into regular log lines.
        (rows: 24, columns: 100)
    }
}
