import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded snapshot of the newest bytes drained from a resident child.
public struct FeatureManagedProcessOutput: Sendable {
    public let stdoutData: Data
    public let stderrData: Data
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool

    public init(
        stdoutData: Data = Data(),
        stderrData: Data = Data(),
        stdoutWasTruncated: Bool = false,
        stderrWasTruncated: Bool = false
    ) {
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
}

/// The final, drained result of a managed process. An exit code of -1 with
/// `wasStarted == false` denotes a wait before a successful launch; -1 with
/// `wasStarted == true` denotes an exit that could not be observed within the
/// shared termination primitive's bounded reap budget.
public struct FeatureManagedProcessExit: Sendable {
    public let exitCode: Int32
    public let output: FeatureManagedProcessOutput
    public let wasTerminated: Bool
    public let wasStarted: Bool

    public init(
        exitCode: Int32,
        output: FeatureManagedProcessOutput = FeatureManagedProcessOutput(),
        wasTerminated: Bool = false,
        wasStarted: Bool = true
    ) {
        self.exitCode = exitCode
        self.output = output
        self.wasTerminated = wasTerminated
        self.wasStarted = wasStarted
    }

    public var stdoutData: Data { output.stdoutData }
    public var stderrData: Data { output.stderrData }
    public var stdout: String { output.stdout }
    public var stderr: String { output.stderr }
    public var stdoutWasTruncated: Bool { output.stdoutWasTruncated }
    public var stderrWasTruncated: Bool { output.stderrWasTruncated }
}

public enum FeatureManagedProcessError: LocalizedError, Sendable {
    case alreadyStarted
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "A managed feature process can only be started once."
        case .unsupportedPlatform:
            return "Managed feature processes are unavailable on this platform."
        }
    }
}

/// Owns a single resident subprocess, without prescribing a feature protocol.
///
/// The executable and argv are passed directly to `Process`, never to a shell.
/// Stdin is the null device. Stdout and stderr are drained concurrently through
/// nonblocking descriptors, retaining only a bounded tail of each stream. Hitting
/// the retention limit does not stop a resident producer or stop its drain.
///
/// A successful launch is single-use. To restart a service, create a new owner.
/// Failed launches surface the original Foundation error and remain unstarted.
public actor FeatureManagedProcess {
    public static let defaultMaximumOutputBytesPerStream =
        FeatureProcessRunner.defaultMaximumOutputBytesPerStream

    private let executableURL: URL
    private let arguments: [String]
    private let workingDirectory: URL?
    private let environment: [String: String]?
    private let terminationGracePeriod: Duration
    private let outputBuffer: OutputBuffer

    private var process: Process?
    private var exitSignal = FeatureProcessExitSignal()
    private var stdoutReader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var exitResult: FeatureManagedProcessExit?
    private var terminationRequested = false

    public private(set) var hasStarted = false

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        maximumOutputBytesPerStream: Int = FeatureManagedProcess.defaultMaximumOutputBytesPerStream,
        terminationGracePeriod: TimeInterval = 2
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.environment = environment
        outputBuffer = OutputBuffer(limit: max(1, maximumOutputBytesPerStream))
        // Non-finite or negative configuration must not create an unbounded
        // shutdown wait, or trap while converting seconds to a Duration.
        self.terminationGracePeriod = terminationGracePeriod.isFinite
            ? .seconds(max(0, terminationGracePeriod))
            : FeatureProcessTerminationEscalator.defaultGrace
    }

    deinit {
        stdoutReader?.cancel()
        stderrReader?.cancel()
        if let process, !exitSignal.hasExited {
            FeatureProcessTreeSupervisor.terminateImmediately(process)
        }
        // Readers own and close their handles after cancellation; do not close
        // a descriptor here while a reader may still be using its number.
    }

    /// Based on the exit monitor, rather than Foundation's potentially stale
    /// `Process.isRunning` bookkeeping.
    public var isRunning: Bool {
        process != nil && !exitSignal.hasExited
    }

    public var processIdentifier: Int32? {
        isRunning ? process?.processIdentifier : nil
    }

    public var stderrTail: String { outputBuffer.snapshot().stderr }

    public func diagnostics() -> String { stderrTail }

    public func output() -> FeatureManagedProcessOutput { outputBuffer.snapshot() }

    public func start() async throws {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()
        guard !hasStarted else { throw FeatureManagedProcessError.alreadyStarted }
        FeatureProcessDescriptors.ignoreSIGPIPEOnce()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitSignal = FeatureProcessExitSignal()
        let monitor = FeatureProcessExitMonitor { exitCode in
            exitSignal.finish(exitCode: exitCode)
        }
        monitor.install(on: process)
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            FeatureProcessDescriptors.closeQuietly(stdoutPipe.fileHandleForReading)
            FeatureProcessDescriptors.closeQuietly(stdoutPipe.fileHandleForWriting)
            FeatureProcessDescriptors.closeQuietly(stderrPipe.fileHandleForReading)
            FeatureProcessDescriptors.closeQuietly(stderrPipe.fileHandleForWriting)
            throw error
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        FeatureProcessDescriptors.makeNonBlocking(stdoutHandle)
        FeatureProcessDescriptors.makeNonBlocking(stderrHandle)
        self.process = process
        self.exitSignal = exitSignal
        hasStarted = true

        // Tasks capture only their own handle, the output buffer and the exit
        // signal, never this actor. Releasing the owner can therefore run deinit
        // even while the child is idle. Each handle stays alive until its reader
        // has stopped, including on the synchronous abandonment path.
        let outputBuffer = outputBuffer
        stdoutReader = Task.detached(name: "Managed feature stdout reader") {
            await Self.drain(stdoutHandle, stream: .stdout, buffer: outputBuffer, exitSignal: exitSignal)
        }
        stderrReader = Task.detached(name: "Managed feature stderr reader") {
            await Self.drain(stderrHandle, stream: .stderr, buffer: outputBuffer, exitSignal: exitSignal)
        }
        monitor.startMonitoring(processID: process.processIdentifier)

        if Task.isCancelled {
            await stop()
            throw CancellationError()
        }
        #else
        throw FeatureManagedProcessError.unsupportedPlatform
        #endif
    }

    /// Observes the child's final exit and joins both readers. Cancelling a wait
    /// stops and reaps the owned child before returning its result; it does not
    /// poison the exit signal for other observers.
    public func waitUntilExit() async -> FeatureManagedProcessExit {
        guard hasStarted else {
            return FeatureManagedProcessExit(exitCode: -1, wasStarted: false)
        }
        if let exitResult { return exitResult }

        await exitSignal.wait()
        if Task.isCancelled {
            await stop()
        } else {
            await finishReaders()
        }
        return exitResult ?? makeExitResult()
    }

    /// Idempotent TERM -> grace -> KILL -> bounded reap shutdown. Concurrent
    /// callers join one shared escalation, which is not cancelled with any one
    /// caller and does not rely on Foundation's running-state property.
    public func stop() async {
        guard hasStarted, exitResult == nil else { return }
        if stopTask == nil, let process, !exitSignal.hasExited {
            terminationRequested = true
            let exitSignal = exitSignal
            let grace = terminationGracePeriod
            stopTask = Task.detached(name: "Managed feature process shutdown") {
                await FeatureProcessTerminationEscalator.escalate(process, exitSignal: exitSignal, grace: grace)
            }
        }
        if let stopTask { await stopTask.value }
        await finishReaders()
    }

    private func finishReaders() async {
        // A failed reap must still have a bounded teardown. Normally readers
        // finish by draining queued bytes to EOF/EAGAIN after the owned exit.
        if !exitSignal.hasExited {
            stdoutReader?.cancel()
            stderrReader?.cancel()
        }
        if let stdoutReader { await stdoutReader.value }
        if let stderrReader { await stderrReader.value }
        stdoutReader = nil
        stderrReader = nil
        process?.terminationHandler = nil
        process = nil
        stopTask = nil
        if exitResult == nil { exitResult = makeExitResult() }
    }

    private func makeExitResult() -> FeatureManagedProcessExit {
        FeatureManagedProcessExit(
            exitCode: exitSignal.exitCode ?? -1,
            output: outputBuffer.snapshot(),
            wasTerminated: terminationRequested,
            wasStarted: hasStarted
        )
    }

    private enum Stream: Sendable { case stdout, stderr }

    /// Bounded state independent from the actor, so readers do not retain their
    /// owner or queue output faster than an actor mailbox can consume it.
    private final class OutputBuffer: Sendable {
        private struct Tail: Sendable {
            var data = Data()
            var wasTruncated = false

            mutating func append(_ chunk: Data, limit: Int) {
                let previousBudget = max(0, limit - chunk.count)
                if data.count > previousBudget {
                    data = Data(data.suffix(previousBudget))
                    wasTruncated = true
                }
                if chunk.count > limit {
                    data = Data(chunk.suffix(limit))
                    wasTruncated = true
                } else {
                    data.append(chunk)
                }
            }
        }

        private struct State: Sendable {
            var stdout = Tail()
            var stderr = Tail()
        }

        private let state = Mutex(State())
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data, stream: Stream) {
            state.withLock { state in
                switch stream {
                case .stdout: state.stdout.append(chunk, limit: limit)
                case .stderr: state.stderr.append(chunk, limit: limit)
                }
            }
        }

        func snapshot() -> FeatureManagedProcessOutput {
            state.withLock { state in
                FeatureManagedProcessOutput(
                    stdoutData: state.stdout.data,
                    stderrData: state.stderr.data,
                    stdoutWasTruncated: state.stdout.wasTruncated,
                    stderrWasTruncated: state.stderr.wasTruncated
                )
            }
        }
    }

    private nonisolated static func drain(
        _ handle: FileHandle,
        stream: Stream,
        buffer: OutputBuffer,
        exitSignal: FeatureProcessExitSignal
    ) async {
        defer { FeatureProcessDescriptors.closeQuietly(handle) }
        #if os(macOS) || os(Linux)
        let descriptor = handle.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 65_536)
        var exitObservedAt: ContinuousClock.Instant?
        while !Task.isCancelled {
            // The child can write and exit after an empty read. Only an exit
            // observed before that read makes EAGAIN evidence of a drained pipe.
            let hasExitedBeforeRead = exitSignal.hasExited
            let bytesRead = scratch.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, base, rawBuffer.count)
            }
            if bytesRead > 0 {
                buffer.append(Data(scratch[0 ..< bytesRead]), stream: stream)
                if exitSignal.hasExited {
                    exitObservedAt = exitObservedAt ?? .now
                    // A descendant may keep the write end open and actively
                    // produce forever. Do not wait for an unrelated producer
                    // after the owned process has exited.
                    if let exitObservedAt, ContinuousClock.now - exitObservedAt >= .milliseconds(100) {
                        return
                    }
                }
                continue
            }
            if bytesRead == 0 { return }
            let readError = errno
            if readError == EINTR { continue }
            if readError == EAGAIN || readError == EWOULDBLOCK {
                if hasExitedBeforeRead { return }
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { return }
                continue
            }
            return
        }
        #endif
    }
}
