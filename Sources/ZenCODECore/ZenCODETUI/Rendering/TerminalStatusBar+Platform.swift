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
    func startSpinnerTimerLocked(state: inout State) {
        guard state.isStarted, state.spinnerTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            self?.advanceSpinner()
        }
        state.spinnerTimer = timer
        timer.resume()
    }
    
    func stopSpinnerTimerLocked(state: inout State) {
        state.spinnerTimer?.setEventHandler {}
        state.spinnerTimer?.cancel()
        state.spinnerTimer = nil
    }
    
    func advanceSpinner() {
        state.withLock { state in
            guard state.isStarted, state.isProcessing else {
                return
            }
            state.spinnerIndex = (state.spinnerIndex + 1) % Self.spinnerFrames.count
            renderLocked(state: &state)
        }
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
            self?.scheduleTerminalResize()
        }
        state.resizeSignalSource = source
        source.resume()
    }
    
    func stopResizeSignalSourceLocked(state: inout State) {
        state.resizeSignalSource?.setEventHandler {}
        state.resizeSignalSource?.cancel()
        state.resizeSignalSource = nil
    }
    
    func scheduleTerminalResize() {
        let generation = state.withLock { state -> Int? in
            guard state.isStarted else {
                return nil
            }
            state.resizeGeneration += 1
            state.isResizePending = true
            return state.resizeGeneration
        }
        guard let generation else {
            return
        }
        
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(80)
        ) { [weak self] in
            self?.handleTerminalResize(generation: generation)
        }
    }
    
    func handleTerminalResize(generation: Int) {
        state.withLock { state in
            guard state.isStarted, generation == state.resizeGeneration else {
                return
            }
            defer {
                state.isResizePending = false
            }
            guard refreshTerminalGeometryLocked(state: &state) else {
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
        if ioctl(fileDescriptor, TIOCGWINSZ, &size) == 0,
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
    
    func writeLocked(_ text: String) {
        output?.writeString(text)
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
