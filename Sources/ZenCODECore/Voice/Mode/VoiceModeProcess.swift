//
//  VoiceModeProcess.swift
//  ZenCODE
//
//  One external program of Linux voice mode: standard error read on a
//  dedicated thread as ordered lines, then exactly one exit event, and
//  termination with a grace period.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One running external program. Standard output is discarded; standard
/// error is read on a dedicated thread and delivered as ordered lines,
/// followed by exactly one exit event once the program ended and its output
/// was drained.
final class VoiceModeProcess: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case line(String)
        case exited(status: Int32, signaled: Bool)
    }

    static let maximumLineBytes = 8 * 1_024

    let events: AsyncStream<Event>
    private let process: Process

    /// Joins the end of standard error with the process exit, so the exit
    /// event always follows every line.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<Event>.Continuation
        private var readerFinished = false
        private var exit: Event?

        init(continuation: AsyncStream<Event>.Continuation) {
            self.continuation = continuation
        }

        func line(_ text: String) {
            continuation.yield(.line(text))
        }

        func finishReading() {
            let exit = lock.withLock { () -> Event? in
                readerFinished = true
                return self.exit
            }
            finishIfComplete(exit)
        }

        func processExited(_ event: Event) {
            let readerFinished = lock.withLock { () -> Bool in
                exit = event
                return self.readerFinished
            }
            if readerFinished {
                finishIfComplete(event)
            }
        }

        private func finishIfComplete(_ exit: Event?) {
            guard let exit else {
                return
            }
            continuation.yield(exit)
            continuation.finish()
        }
    }

    private final class ReadEnd: @unchecked Sendable {
        let handle: FileHandle

        init(handle: FileHandle) {
            self.handle = handle
        }
    }

    init(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let (events, continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        let completion = Completion(continuation: continuation)
        process.terminationHandler = { finished in
            completion.processExited(.exited(
                status: finished.terminationStatus,
                signaled: finished.terminationReason == .uncaughtSignal
            ))
        }
        try process.run()

        let descriptor = errorPipe.fileHandleForReading.fileDescriptor
        // The reader thread owns the read end until EOF, so the descriptor
        // cannot be closed (and its number reused by the next program) while
        // it is still being read.
        let readEnd = ReadEnd(handle: errorPipe.fileHandleForReading)
        let reader = Thread {
            // `read(2)` returns whatever is available; FileHandle's
            // `read(upToCount:)` would wait for a full buffer or EOF and hold
            // back every utterance of a long-running recognizer.
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var pending = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    break
                }
                pending.append(contentsOf: buffer[0..<count])
                while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = pending[pending.startIndex..<index]
                    pending = Data(pending[pending.index(after: index)...])
                    if !lineData.isEmpty {
                        completion.line(String(decoding: lineData, as: UTF8.self))
                    }
                }
                if pending.count > Self.maximumLineBytes {
                    completion.line(String(decoding: pending.prefix(Self.maximumLineBytes), as: UTF8.self))
                    pending.removeAll()
                }
            }
            if !pending.isEmpty {
                completion.line(String(decoding: pending, as: UTF8.self))
            }
            try? readEnd.handle.close()
            completion.finishReading()
        }
        reader.stackSize = 256 * 1_024
        reader.start()

        self.process = process
        self.events = events
    }

    /// Grace after SIGTERM before SIGKILL.
    static let terminationGrace = Duration.milliseconds(300)
    /// How long ``terminateAndWait()`` still waits for the exit after
    /// SIGKILL; with the grace, about a second in all.
    static let killedExitWait = Duration.milliseconds(700)
    private static let exitPollInterval = Duration.milliseconds(10)

    /// SIGTERM, then SIGKILL when the program is still running after a short
    /// grace: a child can inherit an ignored SIGTERM from the terminal's
    /// signal handling. The exit event still follows.
    func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        Task(name: "ZenCODE.sherpa-voice-kill") { [self] in
            try? await Task.sleep(for: Self.terminationGrace)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Like ``terminate()``, but returns once the program ended, or after
    /// about a second: ZenCODE may exit right after, and a program still
    /// waiting for its SIGKILL would outlive it with the microphone or the
    /// speaker open. The exit event still follows.
    func terminateAndWait() async {
        guard process.isRunning else {
            return
        }
        process.terminate()
        if await waitForExit(within: Self.terminationGrace) {
            return
        }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(within: Self.killedExitWait)
    }

    /// Whether the program ended within `limit`. A cancelled wait ends at
    /// once, so a cancelled stop sends SIGKILL without the grace.
    private func waitForExit(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: Self.exitPollInterval)
            } catch {
                return !process.isRunning
            }
        }
        return true
    }
}
