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
        state.spinnerTask = Task { [weak self] in
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
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGWINCH,
            queue: .global(qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            Task {
                await self?.scheduleTerminalResize()
            }
        }
        state.resizeSignalSource = source
        source.resume()
    }
    
    func stopResizeSignalSourceLocked(state: inout State) {
        state.resizeGeneration &+= 1
        state.isResizePending = false
        state.resizeTask?.cancel()
        state.resizeTask = nil
        state.resizeSignalSource?.setEventHandler {}
        state.resizeSignalSource?.cancel()
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
        state.resizeTask = Task { [weak self] in
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

    func handleTerminalResize(generation: Int) {
        withOutputBatch {
            guard state.isStarted, generation == state.resizeGeneration else {
                return
            }
            state.resizeTask = nil
            guard refreshTerminalGeometryLocked(state: &state) else {
                state.isResizePending = false
                return
            }
            state.isResizePending = false
            renderLocked(state: &state)
        }
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
        if let outputSink {
            outputSink(text)
        } else {
            output?.writeString(text)
        }
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
