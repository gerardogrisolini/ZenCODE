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
    func startSpinnerTimerLocked() {
        guard isStarted, spinnerTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            self?.advanceSpinner()
        }
        spinnerTimer = timer
        timer.resume()
    }
    
    func stopSpinnerTimerLocked() {
        spinnerTimer?.setEventHandler {}
        spinnerTimer?.cancel()
        spinnerTimer = nil
    }
    
    func advanceSpinner() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isStarted, isProcessing else {
            return
        }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
        renderLocked()
    }
    
    func startResizeSignalSourceLocked() {
        guard resizeSignalSource == nil else {
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
        resizeSignalSource = source
        source.resume()
    }
    
    func stopResizeSignalSourceLocked() {
        resizeSignalSource?.setEventHandler {}
        resizeSignalSource?.cancel()
        resizeSignalSource = nil
    }
    
    func scheduleTerminalResize() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        resizeGeneration += 1
        isResizePending = true
        let generation = resizeGeneration
        lock.unlock()
        
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(80)
        ) { [weak self] in
            self?.handleTerminalResize(generation: generation)
        }
    }
    
    func handleTerminalResize(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        guard isStarted, generation == resizeGeneration else {
            return
        }
        defer {
            isResizePending = false
        }
        guard refreshTerminalGeometryLocked() else {
            return
        }
        isResizePending = false
        renderLocked()
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
