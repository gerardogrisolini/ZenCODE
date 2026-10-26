//
//  DS4EngineProcessRunner.swift
//  ZenCODE
//
//  Process seam of `DS4EngineBuilder`: the builder never launches processes
//  directly, so unit tests substitute a fake and never run a real build.
//

import Dispatch
import Foundation
import Synchronization

/// Runs one executable and streams its combined stdout/stderr, line by line.
protocol DS4EngineProcessRunning: Sendable {
    /// Returns the exit status once the process has finished and all of its
    /// output has been delivered. A process killed by a signal reports `128 + signal`.
    func run(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

/// `Process`-based runner. stdout and stderr share one pipe, which keeps the
/// lines of the two streams in the order the child wrote them.
struct DS4EngineProcessRunner: DS4EngineProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let launch = DS4EngineLaunchedProcess(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try launch.runAndStream(output: output))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            launch.terminate()
        }
    }
}

/// One `Process` whose launch and termination are serialized, so cancelling
/// before or while launching never touches a process that was not started.
/// `Process` is not `Sendable`; every access goes through `state` or happens on
/// the single thread that streams the output.
private final class DS4EngineLaunchedProcess: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var launched = false
    }

    private let process: Process
    private let pipe: Pipe
    private let state = Mutex(State())

    init(executable: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process
        self.pipe = pipe
    }

    func terminate() {
        state.withLock { state in
            state.cancelled = true
            if state.launched, process.isRunning {
                process.terminate()
            }
        }
    }

    func runAndStream(output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        try state.withLock { state in
            if state.cancelled {
                throw CancellationError()
            }
            try process.run()
            state.launched = true
        }
        // The parent must drop its copy of the write end, or the read below never sees EOF.
        try? pipe.fileHandleForWriting.close()

        var splitter = DS4EngineLineSplitter()
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty {
                break
            }
            for line in splitter.append(chunk) {
                output(line)
            }
        }
        for line in splitter.finish() {
            output(line)
        }
        try? reader.close()

        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            return 128 + process.terminationStatus
        }
        return process.terminationStatus
    }
}

/// Reassembles lines from arbitrary chunks of process output. Splits on `\n`,
/// drops a trailing `\r` and decodes UTF-8 leniently; an unterminated last line
/// is returned by `finish()`.
struct DS4EngineLineSplitter {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Self.decode(buffer[buffer.startIndex..<newline]))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [Self.decode(buffer[...])]
    }

    private static func decode(_ bytes: Data.SubSequence) -> String {
        var bytes = bytes
        if bytes.last == 0x0D {
            bytes = bytes.dropLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
