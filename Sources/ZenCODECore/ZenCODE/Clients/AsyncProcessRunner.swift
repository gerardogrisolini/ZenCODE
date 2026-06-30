//
//  AsyncProcessRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct AsyncProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool
    public let stdoutWasTruncated: Bool

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }
}

public enum AsyncProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil
    ) async throws -> AsyncProcessResult {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdinData.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        let exitObserver = AsyncProcessExitObserver()
        process.terminationHandler = { _ in
            Task {
                await exitObserver.finish()
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        if let stdinData,
           let stdinPipe {
            let writer = stdinPipe.fileHandleForWriting
            try? writer.write(contentsOf: stdinData)
            try? writer.close()
        }

        let stdoutReader = Task.detached { () -> (Data, Bool) in
            readStdout(
                from: stdoutPipe,
                process: process,
                lineLimit: stdoutLineLimit
            )
        }
        let stderrReader = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timedOut = await withTaskCancellationHandler {
            await waitForProcessExit(
                process,
                exitObserver: exitObserver,
                timeout: timeout
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        process.terminationHandler = nil
        let stdoutResult = await stdoutReader.value
        let stderrData = await stderrReader.value

        try Task.checkCancellation()

        return AsyncProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutResult.0,
            stderrData: stderrData,
            timedOut: timedOut,
            stdoutWasTruncated: stdoutResult.1
        )
        #else
        _ = executableURL
        _ = arguments
        _ = workingDirectory
        _ = environment
        _ = stdinData
        _ = timeout
        _ = stdoutLineLimit
        throw AsyncProcessRunnerError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func readStdout(
        from pipe: Pipe,
        process: Process,
        lineLimit: Int?
    ) -> (Data, Bool) {
        guard let lineLimit, lineLimit > 0 else {
            return (pipe.fileHandleForReading.readDataToEndOfFile(), false)
        }

        var stdoutData = Data()
        var observedLineCount = 0
        var wasTruncated = false

        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                break
            }

            stdoutData.append(chunk)
            observedLineCount += chunk.reduce(into: 0) { partialResult, byte in
                if byte == UInt8(ascii: "\n") {
                    partialResult += 1
                }
            }

            if observedLineCount >= lineLimit {
                wasTruncated = true
                if process.isRunning {
                    process.terminate()
                }
                break
            }
        }

        return (stdoutData, wasTruncated)
    }

    private static func waitForProcessExit(
        _ process: Process,
        exitObserver: AsyncProcessExitObserver,
        timeout: TimeInterval?
    ) async -> Bool {
        guard let timeout, timeout > 0 else {
            await exitObserver.wait()
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitObserver.wait()
                return false
            }

            group.addTask {
                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard await !exitObserver.hasFinished else {
                    return false
                }

                process.terminate()
                if await waitForExitAfterTermination(exitObserver: exitObserver) {
                    return true
                }

                kill(process.processIdentifier, SIGKILL)
                await exitObserver.wait()
                return true
            }

            let timedOut = await group.next() ?? false
            group.cancelAll()
            return timedOut
        }
    }

    private static func waitForExitAfterTermination(
        exitObserver: AsyncProcessExitObserver
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitObserver.wait()
                return true
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }

            let exited = await group.next() ?? false
            group.cancelAll()
            return exited
        }
    }
    #endif
}

#if os(macOS) || os(Linux)
private actor AsyncProcessExitObserver {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hasFinished = false

    func wait() async {
        guard !hasFinished else {
            return
        }

        await withCheckedContinuation { continuation in
            if hasFinished {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func finish() {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
#endif

public enum AsyncProcessRunnerError: LocalizedError, Sendable {
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local process execution is unavailable on this platform."
        }
    }
}
